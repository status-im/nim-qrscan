#!/usr/bin/env bash
# Static libZXing (readers + C API) for one platform → build/zxing-<platform>[-<abi>]/
#   scripts/build-zxing.sh macos | linux | ios | ios-sim | android <abi> | windows
# Mobile settings mirror desktop-app/mobile/scripts/commonCmakeConfig.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
PLATFORM=${1:?platform}
ABI=${2:-}
TAG=$PLATFORM${ABI:+-$ABI}
BUILD=build/zxing-$TAG

COMMON=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF
        -DZXING_READERS=ON -DZXING_WRITERS=OFF -DZXING_C_API=ON
        -DZXING_EXAMPLES=OFF -DZXING_BLACKBOX_TESTS=OFF -DZXING_UNIT_TESTS=OFF -Wno-dev)
NDK=${ANDROID_NDK_ROOT:-$HOME/Library/Android/sdk/ndk/27.2.12479018}

case "$PLATFORM" in
  macos|linux) TARGET=() ;;
  ios)     TARGET=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos
                   -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0) ;;
  ios-sim) TARGET=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator
                   -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0) ;;
  android) TARGET=(-DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
                   -DANDROID_ABI="${ABI:?android needs an ABI (arm64-v8a, x86_64, ...)}"
                   -DANDROID_PLATFORM=android-28 -DANDROID_STL=c++_static) ;;
  windows) # clang targeting MSVC, as desktop-app's Makefile builds the app
           TARGET=(-G Ninja -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
                   -DCMAKE_C_COMPILER_TARGET=x86_64-pc-windows-msvc
                   -DCMAKE_CXX_COMPILER_TARGET=x86_64-pc-windows-msvc
                   -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL) ;;
  *) echo "unknown platform: $PLATFORM" >&2; exit 2 ;;
esac

if [[ ! -f "$BUILD/core/libZXing.a" && ! -f "$BUILD/core/ZXing.lib" ]]; then
  cmake -S vendor/zxing-cpp -B "$BUILD" "${COMMON[@]}" ${TARGET[@]+"${TARGET[@]}"} >/dev/null
  cmake --build "$BUILD" -j >/dev/null
fi
ls "$BUILD"/core/*ZXing* | head -1
