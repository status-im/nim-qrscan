# Sourced by the build scripts: locates the Android SDK and NDK.
#   ANDROID_SDK: $ANDROID_HOME / $ANDROID_SDK_ROOT, else Android Studio's default
#                location (~/Library/Android/sdk on macOS, ~/Android/Sdk on Linux)
#   NDK:         $ANDROID_NDK_ROOT / $ANDROID_NDK_HOME, else the newest NDK
#                installed under $ANDROID_SDK/ndk
#   NDK_HOST:    the NDK's prebuilt host tag for this machine
ANDROID_SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
if [[ -z "$ANDROID_SDK" ]]; then
  for d in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    [[ -d "$d" ]] && { ANDROID_SDK=$d; break; }
  done
fi
NDK=${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-}}
if [[ -z "$NDK" && -n "$ANDROID_SDK" && -d "$ANDROID_SDK/ndk" ]]; then
  latest=$(ls "$ANDROID_SDK/ndk" | sort -V | tail -1)
  [[ -n "$latest" ]] && NDK=$ANDROID_SDK/ndk/$latest
fi
case "$(uname -s)" in
  Darwin) NDK_HOST=darwin-x86_64 ;; # also on Apple Silicon (universal binaries)
  Linux)  NDK_HOST=linux-x86_64 ;;
  *)      NDK_HOST=windows-x86_64 ;;
esac

require_ndk() {
  if [[ -z "$NDK" || ! -d "$NDK" ]]; then
    echo "Android NDK not found: set ANDROID_NDK_ROOT (or ANDROID_HOME with an ndk/ dir)" >&2
    exit 2
  fi
}
