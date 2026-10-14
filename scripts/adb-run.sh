#!/usr/bin/env bash
# Pushes a binary to the connected Android device/emulator and runs it.
set -euo pipefail
source "$(dirname "$0")/android-env.sh"
ADB=${ADB:-$ANDROID_SDK/platform-tools/adb}
"$ADB" push "$1" /data/local/tmp/qrscan-test >/dev/null
"$ADB" shell chmod 755 /data/local/tmp/qrscan-test
"$ADB" shell /data/local/tmp/qrscan-test
