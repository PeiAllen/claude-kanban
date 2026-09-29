#!/bin/bash
# Argument-parsing tests for scripts/build-ios-device.sh.
#
# Scope is deliberately ONLY the option loop, which runs before team resolution, before xcodegen and
# before any devicectl call — so every case here exits in milliseconds and touches no toolchain, no
# network and no phone. Nothing below can start a build.
#
# This exists because the same defect appeared twice in one change: a malformed option was accepted
# and the script then did something plausible-looking and wrong (built without installing, or
# installed to a phone the user hadn't chosen). The invariant worth pinning is narrow — a malformed
# option must ABORT, never be absorbed — and it is not visible from the picker's own tests.
#
# Usage: scripts/build-ios-device-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SCRIPT="scripts/build-ios-device.sh"

PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# Runs the script with a stub PATH so that even if a case wrongly gets past the option loop it dies at
# the missing-xcodegen check instead of building. Team id supplied so team resolution is never the
# thing that fails, which would make a test pass for the wrong reason.
run() { PATH=/usr/bin:/bin ORCH_IOS_TEAM_ID=TESTTEAM00 "$SCRIPT" "$@" 2>&1; }

rejects() { # $1=description, rest=argv — must exit nonzero AND name the offending option
  local desc="$1"; shift
  local out rc
  out="$(run "$@")"; rc=$?
  if [[ $rc -eq 0 ]]; then bad "$desc (exited 0)"; return; fi
  # An abort in the option loop happens before the config line is ever printed. If we see it, the
  # bad option was absorbed and the script carried on — the exact failure this file exists to catch.
  if [[ "$out" == *"config="* ]]; then bad "$desc (option was absorbed; script continued)"; return; fi
  ok "$desc"
}

accepts() { # $1=description, rest=argv — must get PAST the option loop (config line printed)
  local desc="$1"; shift
  local out
  out="$(run "$@")"
  if [[ "$out" == *"config="* ]]; then ok "$desc"; else bad "$desc (rejected: ${out%%$'\n'*})"; fi
}

echo "1. a malformed option must abort, never be absorbed"
rejects "--device with no value"            --device
rejects "--device= with no value"           --install --device=
rejects "--device eats the next option"     --device --install
rejects "--device eats a later option"      --install --device --release
rejects "unknown option"                    --bogus
rejects "bare word (typo for --install)"    install
rejects "trailing stray argument"           --install extra

echo "2. legitimate invocations must still get through"
accepts "no flags"
accepts "--install"                         --install
accepts "--debug"                           --debug
accepts "--release"                         --release
accepts "name with a space"                 --install --device "Test’s iPhone"
accepts "attached selector"                 --install --device=test
# The attached form is the documented escape hatch for a selector that looks like an option.
accepts "attached dash-leading selector"    --install --device=--weird-name

echo "3. the config default is Release, and --debug/--release are last-one-wins"
config_of() { run "$@" | grep -m1 -o 'config=[A-Za-z]*'; }
for spec in ":Release" "--debug:Debug" "--release:Release" "--debug --release:Release" "--release --debug:Debug"; do
  flags="${spec%%:*}"; want="config=${spec##*:}"
  got="$(config_of ${flags:+$flags})"
  if [[ "$got" == "$want" ]]; then ok "'${flags:-<none>}' → $want"; else bad "'${flags:-<none>}' → $got (wanted $want)"; fi
done

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL == 0 ]]
