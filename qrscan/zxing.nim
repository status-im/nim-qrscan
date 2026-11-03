## Raw bindings to zxing-cpp's C API (core/src/ZXingC.h), reader subset only.
##
## Nim declares the prototypes itself (no `header:` pragma). Enums are passed as
## int32. Barcode format values are resolved at runtime through
## ZXing_BarcodeFormatFromString, so these bindings don't depend on how
## zxing's ZX_BCF_ID macro encodes them.
##
## Link: zxing-cpp (vendor/zxing-cpp) is built with CMake during the Nim
## compile, for the os/cpu Nim targets, into nimcache (cached; keyed by target
## and flags). Cross builds pass what CMake needs beyond that (toolchain file,
## sysroot, deployment target) as `-d:qrscanCmakeFlags=...`.
## `-d:qrscanZxingLib=<path to libZXing.a>` links a prebuilt library instead.

{.push raises: [], gcsafe.}

import std/[compilesettings, hashes, os, strutils]

const
  qrscanZxingLib {.strdefine.} = ""
  qrscanCmakeFlags {.strdefine.} = ""

  zxingSrc = currentSourcePath().parentDir().parentDir() / "vendor/zxing-cpp"
  zxingTarget =
    when defined(ios):
      "-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=" &
        (if hostCPU == "amd64": "x86_64" else: hostCPU)
    elif defined(macosx):
      "-DCMAKE_OSX_ARCHITECTURES=" & (if hostCPU == "amd64": "x86_64" else: hostCPU)
    elif defined(android):
      "-DANDROID_ABI=" & (case hostCPU
        of "arm64": "arm64-v8a"
        of "amd64": "x86_64"
        of "arm": "armeabi-v7a"
        else: "x86")
    else: ""
  zxingCmakeFlags =
    "-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON " &
    "-DBUILD_SHARED_LIBS=OFF -DZXING_READERS=ON -DZXING_WRITERS=OFF " &
    "-DZXING_C_API=ON -DZXING_EXAMPLES=OFF -DZXING_BLACKBOX_TESTS=OFF " &
    "-DZXING_UNIT_TESTS=OFF -Wno-dev " & zxingTarget & " " & qrscanCmakeFlags

proc findZxing(dir: string): string {.compileTime.} =
  for lib in ["core/libZXing.a", "core/ZXing.lib", "core/Release/ZXing.lib"]:
    if fileExists(dir / lib):
      return dir / lib

proc buildZxing(): string {.compileTime.} =
  let dir = querySetting(nimcacheDir) / "zxing-" & hostOS & "-" & hostCPU & "-" &
    toHex(hash(zxingCmakeFlags)).toLowerAscii()
  result = findZxing(dir)
  if result.len == 0:
    for cmd in ["cmake -S " & quoteShell(zxingSrc) & " -B " & quoteShell(dir) & " " & zxingCmakeFlags,
                "cmake --build " & quoteShell(dir) & " --config Release -j"]:
      let (output, code) = gorgeEx(cmd)
      doAssert code == 0, "zxing-cpp build failed: " & cmd & "\n" & output
    result = findZxing(dir)

const zxingLib = (when qrscanZxingLib.len > 0: qrscanZxingLib else: buildZxing())

when not fileExists(zxingLib):
  {.error: "libZXing.a not found at " & zxingLib.}

{.passL: "\"" & zxingLib & "\"".}
# Runtime libraries go after the archive (GNU ld resolves in order; zxing
# needs libm, e.g. lround).
when defined(macosx) or defined(ios):
  {.passL: "-lc++".} # libm is part of libSystem
elif defined(android):
  {.passL: "-lc++ -lm".}
elif defined(windows):
  discard # the MSVC C++ runtime comes with the clang/MSVC toolchain
else:
  {.passL: "-lstdc++ -lm".}

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
proc ZXing_ReaderOptions_setReturnErrors*(o: ptr ZXingReaderOptions, v: bool)

proc ZXing_ReadBarcodes*(iv: ptr ZXingImageView, o: ptr ZXingReaderOptions): ptr ZXingBarcodes
proc ZXing_Barcodes_size*(b: ptr ZXingBarcodes): cint
proc ZXing_Barcodes_at*(b: ptr ZXingBarcodes, i: cint): ptr ZXingBarcode
proc ZXing_Barcodes_delete*(b: ptr ZXingBarcodes)

proc ZXing_Barcode_errorType*(b: ptr ZXingBarcode): int32 ## 0 = ZXing_ErrorType_None
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
