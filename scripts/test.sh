#!/bin/bash
# Run the Orchestra test suite (swift-testing) under a Command Line Tools toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-testing-flags.sh
exec swift test "${SWIFT_TESTING_FLAGS[@]}" "$@"
