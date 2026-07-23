#!/bin/bash
# Tests for scripts/lib/ios-pick-device.py — target-iPhone selection for the device install lane.
#
# Every case is captured/derived `devicectl list devices --json-output` text on stdin: nothing here
# forks devicectl or needs a phone, which is the point — the bug this pins (a network-paired iPhone
# being filtered out) is invisible on a cable-attached device, so it can only be caught by fixture.
#
# The properties each case pins:
#   1. network-paired iPhone   — the regression: `available (paired)`, no `connected` anywhere
#   2. cable-attached iPhone   — the same phone must be picked regardless of transport
#   3. no devices / no iPhone  — fails with a diagnosis, never an empty identifier
#   4. several iPhones         — refuses to guess, and names the candidates
#   5. --device override       — honored by identifier, udid, and name substring; ambiguity refused
#   6. stdout is machine-only  — the identifier alone, so `DEVICE=$(...)` cannot capture prose
#
# Usage: scripts/lib/ios-pick-device-test.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
PICK="scripts/lib/ios-pick-device.py"

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (missing '$3' in: $2)"; fi; }

# --- fixtures ---------------------------------------------------------------------------------
# REAL capture from `xcrun devicectl list devices --json-output` (2026-07-23), trimmed to the fields
# the picker reads. This phone renders in the table as `available (paired)` — the state string that
# broke the old `/connected/` filter.
device_json() {  # $1=transportType $2=pairingState
  cat <<EOF
{"identifier":"E915E0BC-E055-5521-9F0D-18AF93DFDDA9",
 "deviceProperties":{"name":"Allen’s iPhone","developerModeStatus":"enabled"},
 "connectionProperties":{"transportType":"$1","pairingState":"$2","tunnelState":"disconnected"},
 "hardwareProperties":{"platform":"iOS","reality":"physical","deviceType":"iPhone",
   "marketingName":"iPhone 16 Pro Max","productType":"iPhone17,2","udid":"00008140-000958683A88801C"}}
EOF
}
# A second, distinct iPhone — same shape, different identity — for the ambiguity cases.
second_iphone='{"identifier":"11111111-2222-3333-4444-555555555555",
 "deviceProperties":{"name":"Spare iPhone","developerModeStatus":"enabled"},
 "connectionProperties":{"transportType":"wired","pairingState":"paired"},
 "hardwareProperties":{"platform":"iOS","reality":"physical","deviceType":"iPhone",
   "marketingName":"iPhone 13","productType":"iPhone14,5","udid":"00008110-001122334455AABB"}}'
# An iPad: physical and platform iOS, so only deviceType keeps it out of an iPhone-family install.
ipad='{"identifier":"99999999-8888-7777-6666-555555555555",
 "deviceProperties":{"name":"Allen’s iPad"},
 "connectionProperties":{"transportType":"localNetwork","pairingState":"paired"},
 "hardwareProperties":{"platform":"iOS","reality":"physical","deviceType":"iPad",
   "marketingName":"iPad Pro","productType":"iPad16,6","udid":"00008132-000A1B2C3D4E5F60"}}'

payload() { printf '{"info":{"outcome":"success"},"result":{"devices":[%s]}}' "$(IFS=,; echo "$*")"; }

IPHONE_ID="E915E0BC-E055-5521-9F0D-18AF93DFDDA9"

echo "1. network-paired iPhone (the regression) — table state is 'available (paired)', not 'connected'"
out="$(payload "$(device_json localNetwork paired)" | $PICK 2>/dev/null)"
check "picks the network-paired iPhone" "$out" "$IPHONE_ID"

echo "2. cable-attached iPhone — transport must not change the outcome"
out="$(payload "$(device_json wired paired)" | $PICK 2>/dev/null)"
check "picks the cable-attached iPhone" "$out" "$IPHONE_ID"
# An unpaired phone is still selected: devicectl's own install error diagnoses it far better than
# we could by guessing at a status word — the exact mistake that caused this bug.
out="$(payload "$(device_json localNetwork unpaired)" | $PICK 2>/dev/null)"
check "selection ignores pairingState" "$out" "$IPHONE_ID"

echo "3. nothing to install to — must fail loudly, never emit an empty identifier"
out="$(payload | $PICK 2>/dev/null)"; rc=$?
check "no devices at all: exit nonzero" "$rc" "1"
check "no devices at all: no identifier on stdout" "$out" ""
err="$(payload | $PICK 2>&1 >/dev/null)"
contains "no devices: mentions the unlock gotcha" "$err" "UNLOCKED"
err="$(payload "$ipad" | $PICK 2>&1 >/dev/null)"
contains "iPad only: rejected as not an iPhone" "$err" "no physical iPhone"
contains "iPad only: still lists what it did see" "$err" "Allen’s iPad"

echo "4. several iPhones — refuses to guess, and says what it saw"
out="$(payload "$(device_json localNetwork paired)" "$second_iphone" | $PICK 2>/dev/null)"; rc=$?
check "ambiguous: exit nonzero" "$rc" "1"
check "ambiguous: no identifier on stdout" "$out" ""
err="$(payload "$(device_json localNetwork paired)" "$second_iphone" | $PICK 2>&1 >/dev/null)"
contains "ambiguous: names candidate 1" "$err" "$IPHONE_ID"
contains "ambiguous: names candidate 2" "$err" "Spare iPhone"
contains "ambiguous: shows how to disambiguate" "$err" "--device"

echo "5. --device override"
both="$(payload "$(device_json localNetwork paired)" "$second_iphone")"
check "by identifier"     "$(echo "$both" | $PICK --device "$IPHONE_ID" 2>/dev/null)" "$IPHONE_ID"
check "by udid"           "$(echo "$both" | $PICK --device 00008140-000958683A88801C 2>/dev/null)" "$IPHONE_ID"
check "by name substring" "$(echo "$both" | $PICK --device spare 2>/dev/null)" "11111111-2222-3333-4444-555555555555"
check "case-insensitive"  "$(echo "$both" | $PICK --device SPARE 2>/dev/null)" "11111111-2222-3333-4444-555555555555"
# The override is matched against every device, not just iPhones: naming a device is explicit intent.
check "honors a non-iPhone by name" \
  "$(payload "$ipad" | $PICK --device iPad 2>/dev/null)" "99999999-8888-7777-6666-555555555555"
out="$(echo "$both" | $PICK --device iphone 2>/dev/null)"; rc=$?
check "ambiguous override: exit nonzero" "$rc" "1"
check "ambiguous override: no identifier" "$out" ""
out="$(echo "$both" | $PICK --device nosuchphone 2>/dev/null)"; rc=$?
check "unmatched override: exit nonzero" "$rc" "1"
err="$(echo "$both" | $PICK --device nosuchphone 2>&1 >/dev/null)"
contains "unmatched override: names the selector" "$err" "nosuchphone"

echo "6. malformed input must fail, not crash into an empty identifier"
out="$(echo 'not json' | $PICK 2>/dev/null)"; rc=$?
check "bad JSON: exit nonzero" "$rc" "1"
check "bad JSON: no identifier" "$out" ""
out="$(echo '{}' | $PICK 2>/dev/null)"; rc=$?
check "no result key: exit nonzero" "$rc" "1"

echo "7. stdout carries the identifier and nothing else"
out="$(payload "$(device_json localNetwork paired)" | $PICK 2>/dev/null | wc -l | tr -d ' ')"
check "exactly one stdout line" "$out" "1"

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL == 0 ]]
