#!/usr/bin/env bash
# Builds zxing + the C ABI for a target platform, links the C test and runs it
# where this machine can (see docs/platforms.md).
#   scripts/cross-check.sh macos | linux | ios | ios-sim | android <abi> | windows
set -euo pipefail
cd "$(dirname "$0")/.."
PLATFORM=${1:?platform}
ABI=${2:-}
TAG=$PLATFORM${ABI:+-$ABI}
OUT=build/$TAG
mkdir -p "$OUT"

scripts/build-zxing.sh "$PLATFORM" $ABI
ZXING_LIB=$PWD/build/zxing-$TAG/core/libZXing.a
NIM=${NIM:-nim}
QRGEN=.deps/QR-Code-generator/c

source scripts/toolchain.sh "$PLATFORM" $ABI   # sets CC, CXX, NIM_TARGET_FLAGS, LINK_FLAGS, RUN

"$NIM" c --app:staticlib --noMain -d:release -d:useMalloc --hints:off ${NIM_TARGET_FLAGS[@]+"${NIM_TARGET_FLAGS[@]}"} \
  -d:qrscanZxingLib="$ZXING_LIB" --nimcache:"$OUT/nimcache-capi" \
  --out:"$PWD/$OUT/libqrscan.a" qrscan/capi.nim

"$CC" -std=c11 -O1 -c -Iinclude -I$QRGEN tests/c/tcapi.c -o "$OUT/tcapi.o"
"$CC" -std=c11 -O1 -c -I$QRGEN $QRGEN/qrcodegen.c -o "$OUT/qrcodegen.o"
"$CXX" "$OUT/tcapi.o" "$OUT/qrcodegen.o" "$OUT/libqrscan.a" "$ZXING_LIB" ${LINK_FLAGS[@]+"${LINK_FLAGS[@]}"} \
  -o "$OUT/tcapi"
file "$OUT/tcapi"

if [[ -n "${RUN:-}" ]]; then
  $RUN "$OUT/tcapi"
else
  echo "cross-check $TAG: built and linked (not run on this machine)"
fi
