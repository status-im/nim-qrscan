#!/usr/bin/env bash
# Clones the dependencies of the Qt-free suites (core, worker) into .deps/ at
# the revisions pinned in the Makefile — for hosts without `make` (the Windows
# CI job). `make deps` fetches these plus the Qt-side ones.
set -euo pipefail
cd "$(dirname "$0")/.."

pin() { sed -n "s/^$1 *:= *//p" Makefile; }

clone() { # clone <dir> <url> <rev>
  [[ -d ".deps/$1" ]] || git clone --quiet "$2" ".deps/$1"
  git -C ".deps/$1" cat-file -e "$3^{commit}" 2>/dev/null || git -C ".deps/$1" fetch --quiet origin
  git -C ".deps/$1" checkout --quiet "$3"
}

mkdir -p .deps
clone nim-results       https://github.com/arnetheduck/nim-results.git  "$(pin RESULTS_REV)"
clone QR-Code-generator https://github.com/status-im/QR-Code-generator.git "$(pin QRGEN_REV)"
