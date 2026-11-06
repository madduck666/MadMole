#!/bin/bash
# Builds and runs app/Tests/LogicTests with plain swiftc (Command Line Tools
# are enough; no Xcode or XCTest needed).
#
# Usage: app/Tests/run_logic_tests.sh
# Exit:  0 all passed, 1 a case failed, other: build failure.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT_DIR/app/Sources/MadMole/Engine"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf -- "$OUT_DIR"' EXIT # SAFE: private mktemp build folder

swiftc -O -o "$OUT_DIR/logic_tests" \
    "$ROOT_DIR/app/Tests/LogicTests/main.swift" \
    "$SRC/SafeMove.swift" \
    "$SRC/EngineHelper.swift" \
    "$SRC/Leftovers.swift" \
    "$SRC/CommandRunner.swift" \
    "$SRC/Engine.swift" \
    "$SRC/TextUtils.swift"

"$OUT_DIR/logic_tests" "$ROOT_DIR"
