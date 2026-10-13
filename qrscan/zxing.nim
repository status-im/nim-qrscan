## Raw bindings to zxing-cpp's C API (core/src/ZXingC.h), reader subset only.
##
## Nim declares the prototypes itself (no `header:` pragma). Enums are passed as
## int32. Barcode format values are resolved at runtime through
## ZXing_BarcodeFormatFromString, so these bindings don't depend on how
## zxing's ZX_BCF_ID macro encodes them.
##
## Link: `-d:qrscanZxingLib=<path to libZXing.a>` overrides the default
## (this repo's `make zxing` output), so hosts can build zxing themselves.

{.push raises: [], gcsafe.}

import std/os

const
  repoDir = currentSourcePath().parentDir().parentDir()
  qrscanZxingLib {.strdefine.} = repoDir / "build/zxing/core/libZXing.a"

when not fileExists(qrscanZxingLib):
  {.error: "libZXing.a not found at " & qrscanZxingLib &
    " (run `make zxing` or pass -d:qrscanZxingLib=<path>)".}

{.passL: "\"" & qrscanZxingLib & "\"".}
when defined(macosx) or defined(ios) or defined(android):
  {.passL: "-lc++".}
elif defined(windows):
  discard # the MSVC C++ runtime comes with the clang/MSVC toolchain
else:
  {.passL: "-lstdc++".}

type
  ZXingImageView* = object
  ZXingReaderOptions* = object
  ZXingBarcodes* = object
  ZXingBarcode* = object
  ZXingPointI* {.bycopy.} = object
    x*, y*: cint
  ZXingPosition* {.bycopy.} = object
    topLeft*, topRight*, bottomRight*, bottomLeft*: ZXingPointI

const zxingImageFormatLum* = 0x01000000'i32

{.push importc, cdecl.}
proc ZXing_ImageView_new*(data: ptr uint8, width, height: cint, format: int32,
                          rowStride, pixStride: cint): ptr ZXingImageView
proc ZXing_ImageView_new_checked*(data: ptr uint8, size, width, height: cint, format: int32,
                                  rowStride, pixStride: cint): ptr ZXingImageView
proc ZXing_ImageView_crop*(iv: ptr ZXingImageView, left, top, width, height: cint)
proc ZXing_ImageView_delete*(iv: ptr ZXingImageView)

proc ZXing_ReaderOptions_new*(): ptr ZXingReaderOptions
proc ZXing_ReaderOptions_delete*(o: ptr ZXingReaderOptions)
proc ZXing_ReaderOptions_setTryHarder*(o: ptr ZXingReaderOptions, v: bool)
proc ZXing_ReaderOptions_setTryRotate*(o: ptr ZXingReaderOptions, v: bool)
proc ZXing_ReaderOptions_setTryInvert*(o: ptr ZXingReaderOptions, v: bool)
proc ZXing_ReaderOptions_setTryDownscale*(o: ptr ZXingReaderOptions, v: bool)
proc ZXing_ReaderOptions_setFormats*(o: ptr ZXingReaderOptions, formats: ptr int32, count: cint)
proc ZXing_ReaderOptions_setMaxNumberOfSymbols*(o: ptr ZXingReaderOptions, n: cint)

proc ZXing_ReadBarcodes*(iv: ptr ZXingImageView, o: ptr ZXingReaderOptions): ptr ZXingBarcodes
proc ZXing_Barcodes_size*(b: ptr ZXingBarcodes): cint
proc ZXing_Barcodes_at*(b: ptr ZXingBarcodes, i: cint): ptr ZXingBarcode
proc ZXing_Barcodes_delete*(b: ptr ZXingBarcodes)

proc ZXing_Barcode_isValid*(b: ptr ZXingBarcode): bool
proc ZXing_Barcode_format*(b: ptr ZXingBarcode): int32
proc ZXing_Barcode_text*(b: ptr ZXingBarcode): cstring ## free with ZXing_free
proc ZXing_Barcode_bytes*(b: ptr ZXingBarcode, len: ptr cint): ptr uint8 ## free with ZXing_free
proc ZXing_Barcode_position*(b: ptr ZXingBarcode): ZXingPosition

proc ZXing_BarcodeFormatFromString*(s: cstring): int32
proc ZXing_BarcodeFormatToString*(f: int32): cstring ## free with ZXing_free
proc ZXing_LastErrorMsg*(): cstring ## free with ZXing_free
proc ZXing_free*(p: pointer)
{.pop.}
