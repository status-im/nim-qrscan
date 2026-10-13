# Spike results (architecture spike 3: zxing-cpp C API from Nim)

## macOS arm64, Nim 2.2.10, Apple clang, 2026-10-13

| Item | Result |
|---|---|
| zxing-cpp | v3.1.1 (`287c85d`), git submodule `vendor/zxing-cpp` |
| CMake options | `-DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DZXING_READERS=ON -DZXING_WRITERS=OFF -DZXING_C_API=ON -DZXING_EXAMPLES=OFF -DZXING_BLACKBOX_TESTS=OFF -DZXING_UNIT_TESTS=OFF` |
| Build time | ~13 s wall (37 s CPU) |
| Output | `build/zxing/core/libZXing.a`, 1.6 MB (C API symbols included) |
| Link flags | the archive + `-lc++` (Apple/Android), `-lstdc++` (Linux) |
| Decode via C API | `ZXing_ImageView_new(…, ZXing_ImageFormat_Lum, rowStride, 1)` + `ZXing_ReadBarcodes` decodes a generated QR code |

Verdict: **go**.

## Findings

1. `ZXing_BarcodeFormatToString` returns the human-readable name
   (`"QR Code"`), while `ZXing_BarcodeFormatFromString` takes the identifier
   (`"QRCode"`). Format mapping in `qrscan/decode.nim` therefore uses a numeric
   table built from `FromString(<identifier>)`, never ToString.
2. Format values are `ZX_BCF_ID(SYM, VAR) = SYM | VAR << 8` (16-bit), passed as
   int32.
3. `git submodule add` records the default branch tip; checking out the tag
   afterwards must be staged (`git add vendor/zxing-cpp`) or `git submodule
   update` resets it. The pin is now `v3.1.1`.
