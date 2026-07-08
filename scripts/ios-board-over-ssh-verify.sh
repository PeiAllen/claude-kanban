#!/bin/bash
# Loopback board-over-SSH e2e — the runtime PROOF that the iOS board reaches `.live` over SSH and
# round-trips a `version` RPC, with NO physical device and WITHOUT touching the user's live app/daemon.
#
# It stands up, entirely throwaway and isolated:
#   • an isolated orchestrad (own HOME + UDS) via scripts/orch-test.sh  — the daemon the board talks to
#   • a throwaway non-root sshd on :12322 (temp host key, high port, loopback-only)                — the
#     SSH server the phone's in-process swift-nio-ssh client dials; its authorized_keys trusts the
#     Simulator's Keychain-generated device key
# then runs the gated XCTest `BoardOverSSHE2ETests` in the Simulator. The test builds the real
# `ControlClient(transport: SSHControlTransport(session: …))`, connects, and asserts `.live` + `version`
# + a reconnect. The exec bridge (`nc -U <daemon.sock>`) runs on THIS Mac via sshd, so it reaches the
# isolated socket. Never touches Remote Login, the live board, or the live daemon.
#
# Runs unsandboxed (binds a UDS + a listen socket + enumerates processes). Screenshots/logs to .scratch/.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

ROOT="$(pwd)"
D="$ROOT/.scratch/ios-board-sshd"          # throwaway sshd state
LOG="$ROOT/.scratch"
PORT=12322
BUNDLE=com.orchestra.ios
USER_NAME="$(id -un)"
export ORCH_TEST_NAME=ioboard               # isolate the daemon from live + parallel orch-test runs
T=scripts/orch-test.sh
# The isolated daemon's UDS (orch-test.sh's fixed layout) — the bridge `nc -U`s this ABSOLUTE path.
DAEMON_SOCK="/tmp/$ORCH_TEST_NAME/home/Library/Application Support/Orchestra/orchestrad.sock"

FAILED=0
cleanup() {
  echo "=== cleanup ==="
  [ -f "$D/sshd.pid" ] && kill "$(cat "$D/sshd.pid")" 2>/dev/null
  pkill -f "sshd -f $D" 2>/dev/null
  $T down >/dev/null 2>&1 || true
  rm -rf "$D"
}
trap cleanup EXIT

# 1. Build + ad-hoc SIGN the app for testing (signed so the Keychain entitlement applies — an unsigned
# build has no application-identifier and SecItem returns -34018; see scripts/t1-live-attach.sh). Using
# build-for-testing + test-without-building means the SAME signed binary generates the key (pass 1) and
# runs the test (pass 3) with no rebuild in between, so the Keychain identity matches.
echo "=== build-for-testing (Debug, ad-hoc signed) ==="
xcodegen generate --spec App-iOS/project.yml --project App-iOS >/dev/null
DERIVED="$ROOT/.scratch/ios-e2e-derived"
xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- \
  build-for-testing > "$LOG/ios-e2e-build.log" 2>&1 \
  || { echo "BUILD FAILED"; tail -30 "$LOG/ios-e2e-build.log"; exit 1; }
XCTESTRUN="$(ls "$DERIVED"/Build/Products/*.xctestrun 2>/dev/null | head -1)"
APP="$(ls -d "$DERIVED"/Build/Products/Debug-iphonesimulator/OrchestraiOS.app 2>/dev/null | head -1)"
[ -n "$XCTESTRUN" ] && [ -d "$APP" ] || { echo "no xctestrun/.app produced"; exit 1; }
echo "xctestrun=$XCTESTRUN"

# 2. Boot a Simulator, install the signed app.
UDID="$(xcrun simctl list devices available | grep -m1 '    iPhone ' | grep -oE '[0-9A-Fa-f-]{36}' | head -1)"
echo "UDID=$UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

# 3. Pass 1 — launch the app once to generate the Keychain key + export the pubkey to the container.
echo "=== pass 1: generate + export device pubkey ==="
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 6
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null)"
PUBKEY_FILE="$CONTAINER/Documents/orchestra-ios-pubkey.txt"
for _ in $(seq 1 10); do [ -s "$PUBKEY_FILE" ] && break; sleep 1; done
[ -s "$PUBKEY_FILE" ] || { echo "no device pubkey exported ($PUBKEY_FILE)"; exit 1; }
echo "device pubkey: $(cat "$PUBKEY_FILE")"

# 4. Throwaway sshd trusting the device key.
echo "=== start throwaway sshd :$PORT ==="
rm -rf "$D"; mkdir -p "$D"; D="$(cd "$D" && pwd)"
ssh-keygen -q -t ed25519 -f "$D/hostkey" -N ""
cat "$PUBKEY_FILE" > "$D/authorized_keys"; chmod 600 "$D/authorized_keys" "$D/hostkey"
cat > "$D/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $D/hostkey
PidFile $D/sshd.pid
AuthorizedKeysFile $D/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PubkeyAuthentication yes
LogLevel VERBOSE
EOF
/usr/sbin/sshd -f "$D/sshd_config" -E "$D/sshd.log"
sleep 1
pgrep -fl "sshd -f $D" >/dev/null || { echo "sshd failed"; tail "$D/sshd.log"; exit 1; }

# 5. Isolated orchestrad the board will talk to (own HOME + UDS + tmux socket).
echo "=== start isolated orchestrad (ORCH_TEST_NAME=$ORCH_TEST_NAME) ==="
$T init >/dev/null
$T up    >/dev/null
[ -S "$DAEMON_SOCK" ] || { echo "isolated daemon socket missing: $DAEMON_SOCK"; $T log; exit 1; }
echo "daemon sock: $DAEMON_SOCK"

# 6. Pass 3 — run the gated e2e XCTest against the sshd + isolated socket. Env reaches the Simulator test
# runner via the TEST_RUNNER_ prefix (xcodebuild strips it and injects the rest into the runner's
# environment). ORCH_SSH_ALLOW_LOOPBACK=1 opens the DEBUG-only tailnet-guard escape for 127.0.0.1.
echo "=== pass 3: run BoardOverSSHE2ETests ==="
rm -f "$LOG/ios-e2e-test.log"    # never let a stale prior-run log mask a build/test failure
TEST_RUNNER_ORCH_SSH_ALLOW_LOOPBACK=1 \
TEST_RUNNER_ORCH_E2E_SSH_TARGET="$USER_NAME@127.0.0.1:$PORT" \
TEST_RUNNER_ORCH_E2E_DAEMON_SOCK="$DAEMON_SOCK" \
  xcodebuild test-without-building -xctestrun "$XCTESTRUN" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:OrchestraiOSTests/BoardOverSSHE2ETests \
    > "$LOG/ios-e2e-test.log" 2>&1 || FAILED=1

echo "=== sshd auth log ==="; grep -iE "Accepted|Postponed|error|fatal" "$D/sshd.log" | tail -10
# `xcodebuild test-without-building` prints "** TEST EXECUTE SUCCEEDED **" (plain `test` prints
# "** TEST SUCCEEDED **") — accept either, and require the suite line to confirm 0 failures.
if [ "$FAILED" = 0 ] && grep -qE "TEST( EXECUTE)? SUCCEEDED" "$LOG/ios-e2e-test.log" \
   && grep -q "with 0 failures" "$LOG/ios-e2e-test.log"; then
  echo "=== BOARD-OVER-SSH E2E: PASSED ✅ (board reached .live + version RPC + reconnect) ==="
  exit 0
else
  echo "=== BOARD-OVER-SSH E2E: FAILED ❌ ==="
  echo "--- test log tail ---"; tail -40 "$LOG/ios-e2e-test.log"
  echo "--- daemon log tail ---"; $T log 2>/dev/null | tail -15
  exit 1
fi
