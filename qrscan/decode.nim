## decode(): 8-bit grayscale image in, decoded codes out (zxing-cpp C API).

{.push raises: [], gcsafe.}

import results
import ./[types, zxing]

export results, types

func invalid(msg: string): DecodeError =
  DecodeError(kind: dekInvalidInput, msg: msg)

proc engineError(fallback: string): DecodeError =
  let m = ZXing_LastErrorMsg()
  var msg = fallback
  if m != nil:
    if m[0] != '\0':
      msg = $m
    ZXing_free(m)
  DecodeError(kind: dekEngine, msg: msg)

proc formatValue(f: BarcodeFormat): int32 =
  ZXing_BarcodeFormatFromString(cstring($f))

proc toFormat(value: int32): Opt[BarcodeFormat] =
  for f in BarcodeFormat:
    if formatValue(f) == value:
      return Opt.some(f)
  Opt.none(BarcodeFormat)

func validate(img: LumaView): Result[void, DecodeError] =
  if img.data == nil:
    return err(invalid("no image data"))
  if img.width <= 0 or img.height <= 0:
    return err(invalid("width and height must be positive"))
  if img.rowStride < img.width:
    return err(invalid("rowStride is smaller than width"))
  # zxing takes cint sizes. Checking the bounds first also keeps the product
  # below from overflowing (both factors <= 2^31).
  if img.len > int(high(cint)) or img.rowStride > int(high(cint)) or
      img.height > int(high(cint)):
    return err(invalid("image too large"))
  if img.len < img.rowStride * (img.height - 1) + img.width:
    return err(invalid("buffer is shorter than rowStride * height"))
  ok()

proc decode*(img: LumaView, opts = DecodeOptions.init()): Result[seq[DecodedCode], DecodeError] =
  ## Decodes every barcode of `opts.formats` in `img`. No code found is
  ## `ok(@[])`, not an error.
  ? validate(img)

  let iv = ZXing_ImageView_new_checked(cast[ptr uint8](img.data), img.len.cint,
    img.width.cint, img.height.cint, zxingImageFormatLum, img.rowStride.cint, 1)
  if iv == nil:
    return err(engineError("could not create the image view"))

  # Region of interest, in pixels; corners are mapped back to the full image.
  var
    offX = 0
    offY = 0
  if opts.roi.isSome:
    let r = opts.roi.get.normalized
    if not r.isEmpty:
      offX = min(img.width - 1, int(r.x * img.width.float32))
      offY = min(img.height - 1, int(r.y * img.height.float32))
      let
        cw = max(1, min(img.width - offX, int(r.w * img.width.float32)))
        ch = max(1, min(img.height - offY, int(r.h * img.height.float32)))
      ZXing_ImageView_crop(iv, offX.cint, offY.cint, cw.cint, ch.cint)

  let o = ZXing_ReaderOptions_new()
  ZXing_ReaderOptions_setTryHarder(o, opts.tryHarder)
  ZXing_ReaderOptions_setTryRotate(o, opts.tryRotate)
  ZXing_ReaderOptions_setTryInvert(o, opts.tryInvert)
  ZXing_ReaderOptions_setTryDownscale(o, opts.tryDownscale)
  var formats: seq[int32]
  for f in (if opts.formats.card == 0: {bfQrCode} else: opts.formats):
    formats.add formatValue(f)
  ZXing_ReaderOptions_setFormats(o, addr formats[0], formats.len.cint)
  if opts.maxResults > 0:
    ZXing_ReaderOptions_setMaxNumberOfSymbols(o, min(opts.maxResults, 255).cint)

  let barcodes = ZXing_ReadBarcodes(iv, o)
  ZXing_ReaderOptions_delete(o)
  ZXing_ImageView_delete(iv)
  if barcodes == nil:
    return err(engineError("decoding failed"))

  var codes: seq[DecodedCode]
  for i in 0 ..< ZXing_Barcodes_size(barcodes).int:
    let b = ZXing_Barcodes_at(barcodes, i.cint)
    if b == nil or not ZXing_Barcode_isValid(b):
      continue
    let format = toFormat(ZXing_Barcode_format(b))
    if format.isNone:
      continue
    var code = DecodedCode(format: format.get)
    let t = ZXing_Barcode_text(b)
    if t != nil:
      code.text = $t
      ZXing_free(t)
    var n: cint
    let bytes = ZXing_Barcode_bytes(b, addr n)
    if bytes != nil:
      code.bytes = newSeq[byte](n.int)
      if n > 0:
        copyMem(addr code.bytes[0], bytes, n.int)
      ZXing_free(bytes)
    let p = ZXing_Barcode_position(b)
    var k = 0
    for pt in [p.topLeft, p.topRight, p.bottomRight, p.bottomLeft]:
      code.corners[k] = ((pt.x.int + offX).float32 / img.width.float32,
                         (pt.y.int + offY).float32 / img.height.float32)
      inc k
    codes.add code
  ZXing_Barcodes_delete(barcodes)
  ok(codes)
