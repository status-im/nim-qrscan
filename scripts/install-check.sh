#!/usr/bin/env bash
# Installs the package into a temporary nimble directory and builds a consumer
# against it, without -d:qrscanZxingLib, so zxing-cpp builds from the install.
set -euo pipefail
cd "$(dirname "$0")/.."
NIMBLE=${NIMBLE:-nimble}
NIM=${NIM:-nim}
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

before=$(git status --porcelain --ignore-submodules=none; git -C vendor/zxing-cpp status --porcelain)
"$NIMBLE" --nimbleDir:"$DIR/nimble" --useSystemNim install -y
after=$(git status --porcelain --ignore-submodules=none; git -C vendor/zxing-cpp status --porcelain)
[[ "$before" == "$after" ]] || { echo "nimble install changed the checkout:"; echo "$after"; exit 1; }
"$NIM" c -r --hints:off --skipParentCfg --clearNimblePath --nimblePath:"$DIR/nimble/pkgs2" \
  --nimcache:"$DIR/nimcache" -o:"$DIR/consumer" tests/install/consumer.nim
