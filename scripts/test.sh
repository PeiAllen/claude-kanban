#!/bin/bash
# Run the Orchestra test suite (swift-testing) under a Command Line Tools toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
# NB: run under the AMBIENT (Xcode) toolchain — some suites `import XCTest`, which CLT does not
# provide on its search path. typecheck-app.sh pins CLT for the app typecheck; the two scripts
# rebuild the .build OrchestraCore module under their own SDK, each self-consistent.
source scripts/swift-testing-flags.sh

# COMPILING is the contended resource; RUNNING the tests is not (much of the suite is
# tmux/socket/sleep-bound). So we hold the machine-wide build mutex for the compile only, then
# release it and run the suite unlocked — serializing test *execution* would cost throughput
# with no evidence behind it. See notes/designs/build-contention.md.
scripts/lib/with-lock.sh build -- swift build --build-tests "${SWIFT_TESTING_FLAGS[@]}"
exec swift test --skip-build "${SWIFT_TESTING_FLAGS[@]}" "$@"
