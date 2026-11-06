version     = "0.1.0"
author      = "Status Research & Development GmbH"
description = "QR/barcode decoding for Nim (zxing-cpp), with a C ABI and a QML scanner"
license     = "MIT"

requires "nim >= 2.0.0", "results"
# zxing-cpp is a git submodule (vendor/zxing-cpp), built during the Nim compile
# (qrscan/zxing.nim); seaqt / nimqml-seaqt (QML layer only) are consumed by
# path, pinned in the Makefile.
installDirs = @["vendor", "qml"]

before install:
  # zxing-cpp's Python and Rust wrappers link its sources as directory
  # symlinks, which nimble's install copy can't handle on Linux; qrscan
  # builds neither wrapper.
  rmDir("vendor/zxing-cpp/wrappers/python")
  rmDir("vendor/zxing-cpp/wrappers/rust")

task test, "Run tests":
  exec "make test"
