#!/bin/bash
# Guards against the test suite re-clumping. Runs on --all and standalone.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
say() { echo "lint-tests: $1" >&2; fail=1; }

# 1. No wall-clock waits in the unit tier. NO exemption marker — a test that truly needs to
#    settle real fds/sockets belongs in ContractTests. Wait.swift's coarse backstop is the
#    single allowlisted file.
if grep -rnE 'Task\.sleep|Thread\.sleep|usleep\(' Tests/UnitTests Tests/TestSupport \
     --include='*.swift' | grep -v 'Tests/TestSupport/Wait.swift'; then
  say "wall-clock sleep in the unit tier — TestClock.advance, a Gate, pollUntil, or move the suite to ContractTests"
fi
# 2. No ambient WRITE-TARGET path statics in unit tests. Deliberately narrow (confirm/deny fix):
#    - Config.home is a pure derivation input (asserted by config-derivation tests) — excluded.
#    - `Config.dataDir(` with a paren is the PURE resolver dataDir(isLinux:home:env:) — excluded;
#      the bare static `Config.dataDir` is the ambient write target — matched.
#    - socketPath/hooksPath are asserted as derived STRINGS by resolver/adapter unit tests
#      (ConnectionSocketResolverTests:15, AdapterTests:40) and their write paths are launch-time
#      (contract tier) — excluded. The hazard this rule guards is shared filesystem STATE.
if grep -rnE 'NSHomeDirectory\(\)|Config\.defaultScratchRoot|Config\.dataDir[^(A-Za-z]|Config\.(tasksPath|logPath)\b' \
     Tests/UnitTests --include='*.swift'; then
  say "ambient path in a unit test — use the TestEnv per-test base"
fi
# 3. No real forks in the unit tier — neither direct Proc calls nor a RealProc handed to a seam.
if grep -rnE '\bProc\.(run|checked|runShell)\(|\bRealProc\(' Tests/UnitTests --include='*.swift'; then
  say "real process runner in a unit test — inject FakeProc"
fi
# 4. makeReal is contract-tier-only.
if grep -rn 'makeReal' Tests/UnitTests --include='*.swift'; then
  say "TestEnv.makeReal in the unit tier — real git; move the test to ContractTests"
fi
exit $fail
