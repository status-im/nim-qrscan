## Plain value types of the decoding API. No Qt, no camera: an image is just
## an 8-bit grayscale buffer, wherever it came from.

{.push raises: [], gcsafe.}

import results
export results

type
  LumaView* = object
    ## Non-owning 8-bit grayscale view. Pixel (x, y) is at
    ## `data[y * rowStride + x]`; `len` is the number of readable bytes.
    data*: ptr UncheckedArray[byte]
    len*: int
    width*, height*, rowStride*: int

  BarcodeFormat* = enum
    ## String values are zxing's format identifiers.
    bfQrCode = "QRCode"
    bfMicroQrCode = "MicroQRCode"
    bfRmqrCode = "RMQRCode"
    bfDataMatrix = "DataMatrix"
    bfAztec = "Aztec"
    bfPdf417 = "PDF417"

  NormRect* = object
    ## Rectangle in normalized image coordinates (0..1 on both axes).
    x*, y*, w*, h*: float32

  DecodeOptions* = object
    formats*: set[BarcodeFormat] ## empty = {bfQrCode}
    tryHarder*, tryRotate*, tryInvert*, tryDownscale*: bool
    roi*: Opt[NormRect]          ## none/empty = whole image
    maxResults*: int             ## 0 = zxing's default

  Point2* = tuple[x, y: float32] ## normalized to the full (pre-ROI) image

  DecodedCode* = object
    text*: string     ## decoded text (UTF-8)
    bytes*: seq[byte] ## raw payload bytes
    format*: BarcodeFormat
    corners*: array[4, Point2] ## topLeft, topRight, bottomRight, bottomLeft

  DecodeErrorKind* = enum
    dekInvalidInput
    dekEngine

  DecodeError* = object
    kind*: DecodeErrorKind
    msg*: string

func init*(T: type DecodeOptions): DecodeOptions =
  ## QR codes only; try harder, rotated, inverted and downscaled.
  DecodeOptions(formats: {bfQrCode}, tryHarder: true, tryRotate: true,
                tryInvert: true, tryDownscale: true)

func lumaView*(data: openArray[byte], width, height, rowStride: int): LumaView =
  ## View over `data`; the caller keeps `data` alive while the view is used.
  LumaView(
    data: if data.len > 0: cast[ptr UncheckedArray[byte]](unsafeAddr data[0]) else: nil,
    len: data.len, width: width, height: height, rowStride: rowStride)

func clamp01(v: float32): float32 =
  if v < 0: 0'f32 elif v > 1: 1'f32 else: v

func normalized*(r: NormRect): NormRect =
  ## Clamped into [0,1]x[0,1]; an empty result means "whole image".
  let
    x = clamp01(r.x)
    y = clamp01(r.y)
  NormRect(x: x, y: y, w: clamp01(r.x + r.w) - x, h: clamp01(r.y + r.h) - y)

func isEmpty*(r: NormRect): bool =
  not (r.w > 0 and r.h > 0) # also true for NaN
