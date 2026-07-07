#!/bin/bash
# T4 full-stack takeover SCREENSHOT (fully isolated — no user system changes).
#
# Brings up the whole phone-only takeover path and screenshots the live surface:
#   • an ISOLATED orchestrad (orch-test, ORCH_TEST_NAME=ot4shot) with a seeded card + a stand-in live
#     `agent` tmux window (the daemon never launches a real agent under its stripped PATH),
#   • a throwaway non-root sshd on :12223 trusting the Simulator's device key (never touches Remote Login),
#   • the Debug app auto-presenting AgentTakeoverView for that card (ORCH_T4_AUTOTAKEOVER=1).
#
# The app connects to the isolated daemon (ORCH_DEV_SOCKET), takes the .phone lease, SSH-attaches the
# agent window via the takeover recipe, and heartbeats — so the screenshot shows the REAL TUI under the
# T4 chrome (owner bar / accessory bar). Also prints the daemon's owner state to prove the phone holds it.
#
# This is the phone-only stack. A live desktop app retaking control at the same time is NOT exercised here
# (see the PR notes: both-apps-live is documented as deferred).
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

ROOT="$(pwd)"
NAME=ot4shot
D="$ROOT/.scratch/t4sshd"
SHOTS="$ROOT/.scratch"
PORT=12223
BUNDLE=com.orchestra.ios
USER_NAME="$(id -un)"
CARD=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
SESSION=orchestra-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
DAEMON_SOCK="/tmp/$NAME/home/Library/Application Support/Orchestra/orchestrad.sock"
T="scripts/orch-test.sh"
mkdir -p "$SHOTS"

cleanup() {
  echo "=== cleanup ==="
  [ -f "$D/sshd.pid" ] && kill "$(cat "$D/sshd.pid")" 2>/dev/null
  pkill -f "sshd -f $D" 2>/dev/null
  ORCH_TEST_NAME=$NAME $T down >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== build (Debug, ad-hoc signed — Keychain entitlement) ==="
xcodegen generate --spec App-iOS/project.yml --project App-iOS >/dev/null
xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- \
  build > "$SHOTS/t4-build.log" 2>&1 || { echo "BUILD FAILED"; tail -20 "$SHOTS/t4-build.log"; exit 1; }
APP="$(xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {d=$2} / FULL_PRODUCT_NAME / {n=$2} END {print d "/" n}')"
[ -d "$APP" ] || { echo "no .app"; exit 1; }

UDID="$(xcrun simctl list devices available | grep -m1 '    iPhone ' | grep -oE '[0-9A-Fa-f-]{36}' | head -1)"
echo "UDID=$UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

echo "=== pass 1: generate + export device pubkey ==="
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 6
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null)"
PUBKEY_FILE="$CONTAINER/Documents/orchestra-ios-pubkey.txt"
for i in $(seq 1 10); do [ -s "$PUBKEY_FILE" ] && break; sleep 1; done
[ -s "$PUBKEY_FILE" ] || { echo "no device pubkey exported"; exit 1; }

echo "=== throwaway sshd :$PORT ==="
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
AcceptEnv LANG LC_*
EOF
/usr/sbin/sshd -f "$D/sshd_config" -E "$D/sshd.log"
sleep 1
pgrep -fl "sshd -f $D" >/dev/null || { echo "sshd failed"; tail "$D/sshd.log"; exit 1; }

echo "=== isolated orchestrad + seeded agent window ==="
ORCH_TEST_NAME=$NAME $T init >/dev/null
ORCH_TEST_NAME=$NAME $T up   >/dev/null
sleep 1
ORCH_TEST_NAME=$NAME $T tmux new-session -d -s "$SESSION" -n agent -x 80 -y 24 2>/dev/null
ORCH_TEST_NAME=$NAME $T tmux send-keys -t "$SESSION:agent" \
  "clear; printf '=== live agent TUI (stand-in) ===\\nphone owns this window via the T4 lease\\n\\n'; TERM=xterm-256color top" Enter 2>/dev/null
sleep 1

echo "=== launch app → auto takeover ==="
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
SIMCTL_CHILD_ORCH_DEV_SOCKET="$DAEMON_SOCK" \
SIMCTL_CHILD_ORCH_SSH_TARGET="$USER_NAME@127.0.0.1:$PORT" \
SIMCTL_CHILD_ORCH_SSH_ALLOW_LOOPBACK="1" \
SIMCTL_CHILD_ORCH_T4_CARD="$CARD" \
SIMCTL_CHILD_ORCH_T4_AUTOTAKEOVER="1" \
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 8
xcrun simctl io "$UDID" screenshot "$SHOTS/t4-takeover.png" >/dev/null 2>&1
echo "screenshot: $SHOTS/t4-takeover.png"

echo "=== daemon owner state (proves the phone holds the lease) ==="
OWNER_JSON=$(ORCH_TEST_NAME=$NAME $T rpc agentTerminalOwner "{\"ref\":\"aaaaaa\"}" 2>/dev/null)
echo "$OWNER_JSON"
# Gate the regression: the owner must actually be a PHONE (not just "some owner printed"). A takeover
# that silently fell back to desktop-owned / available would still print a line — assert on ownerKind.
if echo "$OWNER_JSON" | grep -q '"ownerKind"[[:space:]]*:[[:space:]]*"phone"'; then
  echo "ASSERT ok: agent terminal is phone-owned"
else
  echo "ASSERT FAIL: expected ownerKind==phone, got: $OWNER_JSON"; exit 1
fi
echo "=== grouped view sessions on the agent window (attach happened) ==="
ORCH_TEST_NAME=$NAME $T tmux list-sessions 2>/dev/null | grep -E "$SESSION" || true
echo "=== sshd auth ==="; grep -iE "Accepted|error|fatal" "$D/sshd.log" | tail -5
echo "DONE"
