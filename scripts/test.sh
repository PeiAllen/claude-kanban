#!/bin/bash
# Run the Orchestra test suite (swift-testing) under a Command Line Tools toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
# NB: run under the AMBIENT (Xcode) toolchain — some suites `import XCTest`, which CLT does not
# provide on its search path. typecheck-app.sh pins CLT for the app typecheck; the two scripts
# rebuild the .build OrchestraCore module under their own SDK, each self-consistent.
source scripts/swift-testing-flags.sh
exec swift test "${SWIFT_TESTING_FLAGS[@]}" "$@"
