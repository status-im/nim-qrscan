version     = "0.1.0"
author      = "Status Research & Development GmbH"
description = "QR/barcode decoding for Nim (zxing-cpp), with a C ABI and a QML scanner"
license     = "MIT"

requires "nim >= 2.0.0", "results"
# zxing-cpp is a git submodule (vendor/zxing-cpp), built during the Nim compile
# (qrscan/zxing.nim); seaqt / nimqml-seaqt (QML layer only) are consumed by
# path, pinned in the Makefile.
# Only what the zxing-cpp CMake build reads goes into the package.
installDirs = @["qml", "vendor/zxing-cpp/core", "vendor/zxing-cpp/docs",
               "vendor/zxing-cpp/wrappers/c"]
installFiles = @["vendor/zxing-cpp/CMakeLists.txt", "vendor/zxing-cpp/zxing.cmake",
                 "vendor/zxing-cpp/LICENSE"]

task test, "Run tests":
  exec "make test"
