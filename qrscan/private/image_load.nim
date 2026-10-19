## Loads a local image file as 8-bit grayscale for decoding. GUI thread.
##
## Formats are detected from the content. Failures are classified for the
## user: "unsupported" when no decoder recognises the content (e.g. HEIC where
## Qt has no plugin, a text file), "unopenable" when the file is missing, empty,
## not local, or a recognised format fails to read (damaged, truncated).
## Only local files are read; nothing touches the network.

{.push raises: [], gcsafe.}

import std/[os, strutils, uri]
import results
from seaqt/qimage import QImage, isNull, width, height, bytesPerLine, constBits,
  convertToFormat, scaled, hasAlphaChannel
from seaqt/qimagereader import QImageReader, create, setDecideFormatFromContent,
  setAutoTransform, format, size, setScaledSize, read, errorString,
  supportedImageFormats, error
from seaqt/qsize import QSize, create, isValid, width, height

export results

type
  ImageLoadFailure* = enum
    ilUnsupported = "unsupported"
    ilUnopenable = "unopenable"

  LoadError* = object
    kind*: ImageLoadFailure
    message*: string

  LoadedImage* = object
    data*: seq[byte] ## tightly packed: rowStride == width
    width*, height*: int

const
  qtUnsupportedFormatError = 3 # QImageReader::UnsupportedFormatError
  qtArgb32 = 5       # QImage::Format_ARGB32 (0xAARRGGBB, not premultiplied)
  qtGrayscale8 = 24  # QImage::Format_Grayscale8

when defined(android):
  import seaqt/QtCore/qtcore_pkg
  {.compile("image_load_android.cpp", "-std=c++17 " & QtCoreCFlags).}
  proc androidDecodeGray(path: cstring, maxDim: cint, width, height: var cint,
                         data: var ptr uint8): cint {.importc: "qrscan_android_decode_gray".}
  proc androidFree(data: ptr uint8) {.importc: "qrscan_android_free".}

func failure(kind: ImageLoadFailure, message: string): Result[LoadedImage, LoadError] =
  err(LoadError(kind: kind, message: message))

proc localPath*(fileUrlOrPath: string): Opt[string] =
  ## The local path of a `file:` URL or a plain path; none for other URLs.
  if fileUrlOrPath.startsWith("file:"):
    try:
      var p = decodeUrl(parseUri(fileUrlOrPath).path, decodePlus = false)
      when defined(windows):
        if p.len >= 3 and p[0] == '/' and p[2] == ':':
          p = p[1 .. ^1] # file:///C:/... -> C:/...
      return Opt.some(p)
    except CatchableError:
      return Opt.none(string)
  if "://" in fileUrlOrPath:
    return Opt.none(string)
  Opt.some(fileUrlOrPath)

proc heicSupported*(): bool =
  ## Whether this platform decodes HEIC/HEIF images.
  when defined(android):
    true # BitmapFactory, API 28+
  else:
    {.cast(raises: []).}:
      for f in QImageReader.supportedImageFormats():
        if cast[string](f) == "heic":
          return true
    false

proc grayOverWhite(img: QImage): LoadedImage =
  ## Luma of the image composited onto white: a transparent background reads
  ## as paper, not as black (Grayscale8 conversion drops the alpha).
  let a = img.convertToFormat(qtArgb32.cint)
  let w = a.width().int
  let h = a.height().int
  let bpl = a.bytesPerLine().int
  result = LoadedImage(width: w, height: h, data: newSeq[byte](w * h))
  let src = cast[ptr UncheckedArray[byte]](a.constBits())
  for y in 0 ..< h:
    let row = cast[ptr UncheckedArray[uint32]](addr src[y * bpl])
    for x in 0 ..< w:
      let px = row[x]
      let alpha = int(px shr 24)
      let luma = (299 * int((px shr 16) and 0xFF) + 587 * int((px shr 8) and 0xFF) +
                  114 * int(px and 0xFF)) div 1000
      result.data[y * w + x] = byte((luma * alpha + 255 * (255 - alpha)) div 255)

proc grayFrom(img: QImage): LoadedImage =
  if img.hasAlphaChannel():
    return grayOverWhite(img)
  let g = img.convertToFormat(qtGrayscale8.cint)
  let w = g.width().int
  let h = g.height().int
  let bpl = g.bytesPerLine().int
  result = LoadedImage(width: w, height: h, data: newSeq[byte](w * h))
  let src = cast[ptr UncheckedArray[byte]](g.constBits())
  for y in 0 ..< h:
    if w > 0:
      copyMem(addr result.data[y * w], addr src[y * bpl], w)

proc loadImageFile*(fileUrlOrPath: string, maxDim: int): Result[LoadedImage, LoadError] =
  ## Loads and converts to grayscale, the longest side scaled to <= maxDim.
  let p = localPath(fileUrlOrPath)
  if p.isNone:
    return failure(ilUnopenable, "not a local file")
  let path = p.get
  try:
    if not fileExists(path):
      return failure(ilUnopenable, "file not found")
    if getFileSize(path) == 0:
      return failure(ilUnopenable, "empty file")
  except CatchableError as e:
    return failure(ilUnopenable, e.msg)

  {.cast(raises: []).}:
    let reader = QImageReader.create(path)
    reader.setDecideFormatFromContent(true)
    reader.setAutoTransform(true)
    if reader.format().len == 0:
      # Qt has no format either when the file can't be read (permissions, I/O):
      # only "no decoder recognises the content" is an unsupported format.
      if reader.error() != qtUnsupportedFormatError:
        return failure(ilUnopenable, reader.errorString())
      when defined(android):
        var w, h: cint
        var data: ptr uint8
        if androidDecodeGray(path.cstring, maxDim.cint, w, h, data) != 0 and data != nil:
          var img = LoadedImage(width: w.int, height: h.int, data: newSeq[byte](w.int * h.int))
          if img.data.len > 0:
            copyMem(addr img.data[0], data, img.data.len)
          androidFree(data)
          return ok(img)
      return failure(ilUnsupported, "unsupported image format")
    let s = reader.size()
    if s.isValid() and max(s.width().int, s.height().int) > maxDim:
      let longest = max(s.width().int, s.height().int)
      reader.setScaledSize(QSize.create(
        cint(s.width().int * maxDim div longest), cint(s.height().int * maxDim div longest)))
    var img = reader.read()
    if img.isNull():
      return failure(ilUnopenable, reader.errorString())
    if max(img.width().int, img.height().int) > maxDim:
      # the reader couldn't scale (size unknown up front)
      let longest = max(img.width().int, img.height().int)
      img = img.scaled(cint(img.width().int * maxDim div longest),
                       cint(img.height().int * maxDim div longest))
    ok(grayFrom(img))
