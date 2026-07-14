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
# --- tier selection (parse FIRST so tier flags never reach swift build) -------------------
# default = unit only; --contract/--e2e add tiers; --all = the whole matrix (merge gate).
TIER_ARGS=(); PASS=()
want_contract=0; want_e2e=0; want_all=0
for a in "$@"; do
  case "$a" in
    --contract) want_contract=1 ;;
    --e2e)      want_e2e=1 ;;
    --all)      want_all=1 ;;
    *)          PASS+=("$a") ;;
  esac
done
if [[ $want_all == 0 ]]; then
  [[ $want_contract == 0 ]] && TIER_ARGS+=(--skip '^ContractTests\.')
  [[ $want_e2e == 0 ]]      && TIER_ARGS+=(--skip '^E2ETests\.')
else
  scripts/lint-tests.sh    # the merge-gate run enforces the re-clumping guards
fi
# --- build-arg filtering: the existing selector loop, but over PASS not "$@" --------------
BUILD_ARGS=()
skip_next=0
for a in ${PASS[@]+"${PASS[@]}"}; do
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
exec swift test --skip-build "${SWIFT_TESTING_FLAGS[@]}" ${TIER_ARGS[@]+"${TIER_ARGS[@]}"} ${PASS[@]+"${PASS[@]}"}
