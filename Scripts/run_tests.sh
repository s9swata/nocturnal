#!/usr/bin/env bash
# Run NocturnalCore unit tests (Swift Testing via SPM dependency).
# Works under Command Line Tools only — does not require full Xcode / XCTest.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

echo "==> swift test (NocturnalCoreTests / Swift Testing)"
swift test "$@"
echo "==> tests complete"
