# Sourced by cross-check.sh: sets CC, CXX, NIM_TARGET_FLAGS, LINK_FLAGS, RUN
# (empty RUN = this machine can't run the binary) for <platform> [abi].
PLATFORM=$1
ABI=${2:-}
NDK=${ANDROID_NDK_ROOT:-$HOME/Library/Android/sdk/ndk/27.2.12479018}
NIM_TARGET_FLAGS=()
LINK_FLAGS=()
RUN=""
WRAP=$OUT/bin
mkdir -p "$WRAP"

wrap() { # wrap <name> <command...>: a single-executable compiler for Nim
  local name=$1; shift
  printf '#!/bin/sh\nexec %s "$@"\n' "$*" > "$WRAP/$name"
  chmod +x "$WRAP/$name"
}

case "$PLATFORM" in
  macos)
    CC=clang; CXX=clang++; LINK_FLAGS=(-lpthread); RUN=command ;;
  linux)
    CC=cc; CXX=c++; LINK_FLAGS=(-lpthread -lm); RUN=command ;;
  ios|ios-sim)
    if [[ $PLATFORM == ios ]]; then SDK=iphoneos; TRIPLE=arm64-apple-ios17.0
    else SDK=iphonesimulator; TRIPLE=arm64-apple-ios17.0-simulator; fi
    wrap cc  xcrun --sdk $SDK clang   -target $TRIPLE
    wrap cxx xcrun --sdk $SDK clang++ -target $TRIPLE
    CC=$WRAP/cc; CXX=$WRAP/cxx
    NIM_TARGET_FLAGS=(--os:ios --cpu:arm64 --cc:clang --clang.exe="$CC" --clang.linkerexe="$CC")
    if [[ $PLATFORM == ios-sim ]] && xcrun simctl list devices booted | grep -q Booted; then
      RUN="xcrun simctl spawn booted"
    fi ;;
  android)
    case "$ABI" in
      arm64-v8a) TRIPLE=aarch64-linux-android28; CPU=arm64 ;;
      x86_64)    TRIPLE=x86_64-linux-android28;  CPU=amd64 ;;
      *) echo "unsupported Android ABI: $ABI" >&2; exit 2 ;;
    esac
    BIN=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin
    CC=$BIN/$TRIPLE-clang; CXX=$BIN/$TRIPLE-clang++
    ln -sf "$BIN/llvm-ar" "$WRAP/ar"; export PATH="$WRAP:$PATH" # ELF archives
    NIM_TARGET_FLAGS=(--os:android --cpu:$CPU -d:androidNDK --cc:clang
                      --clang.exe="$CC" --clang.linkerexe="$CC")
    LINK_FLAGS=(-static-libstdc++)
    ADB=$HOME/Library/Android/sdk/platform-tools/adb
    if "$ADB" devices 2>/dev/null | grep -qE "device$" &&
       [[ "$("$ADB" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')" == "$ABI" ]]; then
      RUN="scripts/adb-run.sh"
    fi ;;
  windows)
    echo "windows: build on Windows (clang --target=x86_64-pc-windows-msvc); see docs/platforms.md" >&2
    exit 2 ;;
  *) echo "unknown platform: $PLATFORM" >&2; exit 2 ;;
esac
