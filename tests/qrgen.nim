## Test fixtures: QR codes rendered to 8-bit luma (Nayuki's C generator) and
## simple image transforms. Black = 0, white = 255.

import std/os

const qrgenDir = currentSourcePath().parentDir().parentDir() / ".deps/QR-Code-generator/c"
{.compile: qrgenDir / "qrcodegen.c".}

const qrBufferLenMax = 3918 # qrcodegen_BUFFER_LEN_MAX (version 40)

type
  Ecc* = enum eccLow, eccMedium, eccQuartile, eccHigh
  GrayImage* = object
    data*: seq[byte]
    width*, height*, rowStride*: int

proc qrcodegen_encodeText(text: cstring, tempBuffer, qrcode: ptr uint8, ecl: cint,
    minVersion, maxVersion: cint, mask: cint, boostEcl: bool): bool {.importc, cdecl.}
proc qrcodegen_encodeBinary(dataAndTemp: ptr uint8, dataLen: csize_t, qrcode: ptr uint8,
    ecl: cint, minVersion, maxVersion: cint, mask: cint, boostEcl: bool): bool {.importc, cdecl.}
proc qrcodegen_getSize(qrcode: ptr uint8): cint {.importc, cdecl.}
proc qrcodegen_getModule(qrcode: ptr uint8, x, y: cint): bool {.importc, cdecl.}

proc render(qr: var array[qrBufferLenMax, uint8], scale, quiet: int): GrayImage =
  let size = qrcodegen_getSize(addr qr[0]).int
  let side = (size + 2 * quiet) * scale
  result = GrayImage(width: side, height: side, rowStride: side,
                     data: newSeq[byte](side * side))
  for i in 0 ..< result.data.len:
    result.data[i] = 255
  for my in 0 ..< size:
    for mx in 0 ..< size:
      if qrcodegen_getModule(addr qr[0], mx.cint, my.cint):
        for dy in 0 ..< scale:
          for dx in 0 ..< scale:
            result.data[((my + quiet) * scale + dy) * side + (mx + quiet) * scale + dx] = 0

proc qrImage*(text: string, scale = 4, quiet = 4, ecc = eccMedium): GrayImage =
  var qr, tmp: array[qrBufferLenMax, uint8]
  doAssert qrcodegen_encodeText(text.cstring, addr tmp[0], addr qr[0], ecc.ord.cint,
                                1, 40, -1, true), "QR encode failed"
  render(qr, scale, quiet)

proc qrImageBytes*(payload: openArray[byte], scale = 4, quiet = 4): GrayImage =
  var qr, buf: array[qrBufferLenMax, uint8]
  for i, b in payload:
    buf[i] = b
  doAssert qrcodegen_encodeBinary(addr buf[0], payload.len.csize_t, addr qr[0],
                                  eccMedium.ord.cint, 1, 40, -1, true), "QR encode failed"
  render(qr, scale, quiet)

proc at(g: GrayImage, x, y: int): byte = g.data[y * g.rowStride + x]

proc rotate90*(g: GrayImage): GrayImage =
  result = GrayImage(width: g.height, height: g.width, rowStride: g.height,
                     data: newSeq[byte](g.width * g.height))
  for y in 0 ..< g.height:
    for x in 0 ..< g.width:
      result.data[x * result.rowStride + (g.height - 1 - y)] = g.at(x, y)

proc invert*(g: GrayImage): GrayImage =
  result = g
  for i in 0 ..< result.data.len:
    result.data[i] = 255'u8 - result.data[i]

proc withContrast*(g: GrayImage, dark, light: byte): GrayImage =
  result = g
  for i in 0 ..< result.data.len:
    result.data[i] = if result.data[i] < 128: dark else: light

proc withNoise*(g: GrayImage, amplitude: int, seed: uint32): GrayImage =
  result = g
  var s = seed
  for i in 0 ..< result.data.len:
    s = s xor (s shl 13); s = s xor (s shr 17); s = s xor (s shl 5) # xorshift32
    let delta = int(s mod uint32(2 * amplitude + 1)) - amplitude
    result.data[i] = byte(clamp(int(result.data[i]) + delta, 0, 255))

proc withPadding*(g: GrayImage, extraStride: int): GrayImage =
  result = GrayImage(width: g.width, height: g.height, rowStride: g.width + extraStride,
                     data: newSeq[byte]((g.width + extraStride) * g.height))
  for y in 0 ..< g.height:
    for x in 0 ..< g.width:
      result.data[y * result.rowStride + x] = g.at(x, y)
    for x in g.width ..< result.rowStride:
      result.data[y * result.rowStride + x] = 77 # garbage padding must be ignored

proc sideBySide*(a, b: GrayImage, gap = 16): GrayImage =
  let w = a.width + gap + b.width
  let h = max(a.height, b.height)
  result = GrayImage(width: w, height: h, rowStride: w, data: newSeq[byte](w * h))
  for i in 0 ..< result.data.len:
    result.data[i] = 255
  for y in 0 ..< a.height:
    for x in 0 ..< a.width:
      result.data[y * w + x] = a.at(x, y)
  for y in 0 ..< b.height:
    for x in 0 ..< b.width:
      result.data[y * w + a.width + gap + x] = b.at(x, y)
