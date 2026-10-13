#!/usr/bin/env bash
# Windows (Git Bash): builds zxing with MSVC and runs the Qt-free Nim suites,
# compiled the way desktop-app compiles Nim on Windows — clang targeting
# x86_64-pc-windows-msvc, linked with lld against the MSVC runtime (/MD).
set -euo pipefail
cd "$(dirname "$0")/.."

# clang finds MSVC and the Windows SDK itself; inherited LIB/INCLUDE/LIBPATH/
# VCINSTALLDIR would override that with stale paths (see desktop-app Makefile).
unset LIB INCLUDE LIBPATH VCINSTALLDIR

native() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

ZXING_LIB=$(native "$PWD/$(scripts/build-zxing.sh windows | tail -1)")
CLANG=$(native "$(command -v clang)")
FLAGS=(--hints:off -d:qrscanTesting -d:qrscanZxingLib="$ZXING_LIB"
       --cc:clang --clang.exe:"$CLANG" --clang.linkerexe:"$CLANG"
       --passC:"--target=x86_64-pc-windows-msvc -fms-runtime-lib=dll"
       --passL:"--target=x86_64-pc-windows-msvc -fuse-ld=lld -fms-runtime-lib=dll")

for t in tests/tdecode.nim tests/tspike.nim tests/tworker.nim; do
  echo "== $t"
  nim c -r "${FLAGS[@]}" "$t"
done
