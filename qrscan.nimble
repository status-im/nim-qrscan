version     = "0.1.0"
author      = "Status Research & Development GmbH"
description = "QR/barcode decoding for Nim (zxing-cpp), with a C ABI and a QML scanner"
license     = "MIT"

requires "nim >= 2.0.0", "results"
# zxing-cpp is a git submodule (vendor/zxing-cpp); seaqt / nimqml-seaqt (QML
# layer only) are consumed by path, pinned in the Makefile.

task test, "Run tests":
  exec "make test"
