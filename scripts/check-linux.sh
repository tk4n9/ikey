#!/bin/sh
# Linux check: runs the Shared package tests and syntax-parses every Apple app
# source file (Apps/**/*.swift). Apple SDK code cannot be typechecked on Linux;
# scripts/check-macos.sh (or the macos CI job) does that.
#
# Usage: scripts/check-linux.sh [SRC_DIR]
#   SRC_DIR  source tree to check (default: this repository)
#   IKEY_SCRATCH (else SCRATCH)
#            SwiftPM build directory (default: SRC_DIR/.build-linux). Give each
#            run its own subdirectory, never a shared root such as a session-wide
#            swiftbuild directory. IKEY_SCRATCH wins when both are set.
#
# Docker, with the source mounted read-only and a build directory unique to
# each caller (concurrent agents must not share one --scratch-path):
#   docker run --rm -v "$PWD":/src:ro -v "$HOME/.cache/ikey":/scratch \
#       -e IKEY_SCRATCH=/scratch/<unique-name> swift:6.2-noble sh /src/scripts/check-linux.sh /src
set -eu
# An exported CDPATH would make `cd` print the directory and corrupt $(cd ...).
unset CDPATH

src=${1:-"$(dirname "$0")/.."}
if [ ! -f "$src/Shared/Package.swift" ]; then
    echo "check-linux: $src is not an iKey source tree (Shared/Package.swift missing)." >&2
    exit 2
fi
src=$(cd -- "$src" && pwd -P)
scratch=${IKEY_SCRATCH:-${SCRATCH:-"$src/.build-linux"}}

if ! command -v swift >/dev/null 2>&1; then
    echo 'check-linux: swift not found; run inside the swift:6.2-noble image.' >&2
    exit 2
fi

echo "== swift test ($src/Shared, scratch $scratch)"
swift test --package-path "$src/Shared" --scratch-path "$scratch"

count=$(find "$src/Apps" -type f -name '*.swift' | wc -l)
if [ "$count" -eq 0 ]; then
    echo "check-linux: no Swift files found under $src/Apps." >&2
    exit 1
fi
echo "== swiftc -frontend -parse ($count Apple app files)"
# With "+" find exits non-zero when any swiftc invocation fails.
find "$src/Apps" -type f -name '*.swift' -exec swiftc -frontend -parse {} +
echo 'check-linux: OK'
