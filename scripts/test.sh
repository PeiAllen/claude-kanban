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
#
# Args: test-only SELECTORS (--filter etc.) must not reach `swift build` (it rejects them);
# everything else (-c release, --scratch-path, -Xswiftc …) changes WHAT is built and must reach
# both, or the build and the --skip-build run would disagree about where the bundle is.
BUILD_ARGS=()
skip_next=0
for a in "$@"; do
  if [[ $skip_next == 1 ]]; then skip_next=0; continue; fi
  case "$a" in
    --filter|--skip|--num-workers|--xunit-output) skip_next=1 ;;   # selector + its value
    --filter=*|--skip=*|--num-workers=*|--xunit-output=*) ;;
    --parallel|--no-parallel|--list-tests|--show-codecov-path) ;;
    *) BUILD_ARGS+=("$a") ;;
  esac
done

scripts/lib/with-lock.sh build -- \
  swift build --build-tests "${SWIFT_TESTING_FLAGS[@]}" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
exec swift test --skip-build "${SWIFT_TESTING_FLAGS[@]}" "$@"
