#!/usr/bin/env bash
# Static libZXing (readers + C API) for one platform → build/zxing-<platform>[-<abi>]/
#   scripts/build-zxing.sh macos [arm64|x86_64] | linux | ios | ios-sim | android <abi> | windows
# macos without an arch builds for the host; with one, for that arch (e.g. an
# x86_64 Qt kit on Apple Silicon), into its own build dir.
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
source scripts/android-env.sh # cwd is the repo root (cd above)

case "$PLATFORM" in
  macos)   TARGET=(${ABI:+-DCMAKE_OSX_ARCHITECTURES=$ABI}) ;;
  linux)   TARGET=() ;;
  ios)     TARGET=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos
                   -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0) ;;
  ios-sim) TARGET=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator
                   -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0) ;;
  android) require_ndk
           TARGET=(-DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
                   -DANDROID_ABI="${ABI:?android needs an ABI (arm64-v8a, x86_64, ...)}"
                   -DANDROID_PLATFORM=android-28 -DANDROID_STL=c++_static) ;;
  windows) # MSVC (Visual Studio generator, /MD), as desktop-app builds its
           # CMake dependencies on Windows (-A x64); Nim then links it with clang
           # targeting x86_64-pc-windows-msvc.
           TARGET=(-A x64 -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL) ;;
  *) echo "unknown platform: $PLATFORM" >&2; exit 2 ;;
esac

find_lib() { find "$BUILD/core" -maxdepth 2 \( -name libZXing.a -o -name ZXing.lib \) 2>/dev/null | head -1; }
if [[ -z "$(find_lib)" ]]; then
  cmake -S vendor/zxing-cpp -B "$BUILD" "${COMMON[@]}" ${TARGET[@]+"${TARGET[@]}"} >/dev/null
  cmake --build "$BUILD" --config Release -j >/dev/null
fi
find_lib
