#!/bin/bash
# Bug 3 — AUTO-OWN-ON-PHONE-SPAWN full-stack screenshot (fully isolated — no user system changes).
#
# Proves the phone-spawn → auto-takeover flow end to end: a card spawned FROM THE PHONE automatically
# becomes the phone's (it acquires the D4 lease and drops straight into the live agent surface) with NO
# manual "Take Over" tap. Builds on scripts/t4-takeover-shot.sh, but instead of auto-taking-over a
# pre-seeded card, the app SPAWNS a scratch card and we verify the takeover it triggers itself.
#
#   • an ISOLATED orchestrad (orch-test, ORCH_TEST_NAME=ot4spawn),
#   • a `claude` SHIM on the daemon's PATH (via ORCH_TEST_EXTRA_PATH) that execs a live `top` — so the
#     spawned card's `agent` window is a real TUI without launching (or billing) real Claude,
#   • a throwaway non-root sshd on :12224 trusting the Simulator's device key,
#   • the Debug app auto-opening the spawn sheet and auto-submitting a scratch spawn
#     (ORCH_SPAWN_MODE=scratch + ORCH_SPAWN_AUTOSUBMIT=1).
#
# The app spawns → the daemon creates the card + `agent` window synchronously → SpawnSheet sets
# phoneTakeoverRequest → RootView presents AgentTakeoverView → it takes the .phone lease and SSH-attaches
# the agent window. The screenshot shows the REAL TUI under the T4 chrome, and we assert the daemon
# reports the NEWLY SPAWNED card (not the seed) is phone-owned.
#
# Deferred (documented, not faked): a live DESKTOP app contending for the same just-spawned card is not
# exercised here (needs both apps up). Desktop-retake semantics are covered by t4-takeover-verify.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

ROOT="$(pwd)"
NAME=ot4spawn
D="$ROOT/.scratch/t4spawnsshd"
SHIM="$ROOT/.scratch/t4spawn-shim"
SHOTS="$ROOT/.scratch"
PORT=12224
BUNDLE=com.orchestra.ios
USER_NAME="$(id -un)"
DAEMON_SOCK="/tmp/$NAME/home/Library/Application Support/Orchestra/orchestrad.sock"
TASKS_JSON="/tmp/$NAME/home/Library/Application Support/Orchestra/tasks.json"
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
  build > "$SHOTS/t4spawn-build.log" 2>&1 || { echo "BUILD FAILED"; tail -20 "$SHOTS/t4spawn-build.log"; exit 1; }
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

echo "=== claude shim (a live TUI stand-in; ignores agent argv, execs top) ==="
rm -rf "$SHIM"; mkdir -p "$SHIM"
cat > "$SHIM/claude" <<'EOF'
#!/bin/bash
# Stand-in for real Claude: a spawned card's `agent` window becomes a live TUI without launching (or
# billing) the real agent. Ignores the adapter argv and runs a real terminal app so takeover has
# something to attach.
clear; printf '=== spawned agent TUI (claude shim stand-in) ===\nphone auto-owns this window via the T4 lease\n\n'
exec env TERM=xterm-256color top
EOF
chmod +x "$SHIM/claude"

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

echo "=== isolated orchestrad (with claude shim on PATH) ==="
ORCH_TEST_NAME=$NAME $T init >/dev/null
ORCH_TEST_NAME=$NAME ORCH_TEST_EXTRA_PATH="$SHIM" $T up >/dev/null
sleep 1

echo "=== launch app → auto-open spawn sheet → auto-submit a SCRATCH spawn → auto-takeover ==="
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
SIMCTL_CHILD_ORCH_DEV_SOCKET="$DAEMON_SOCK" \
SIMCTL_CHILD_ORCH_SSH_TARGET="$USER_NAME@127.0.0.1:$PORT" \
SIMCTL_CHILD_ORCH_SSH_ALLOW_LOOPBACK="1" \
SIMCTL_CHILD_ORCH_RESET_HOSTKEY_PINS="1" \
SIMCTL_CHILD_ORCH_SPAWN_MODE="scratch" \
SIMCTL_CHILD_ORCH_SPAWN_AUTOSUBMIT="1" \
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 12
xcrun simctl io "$UDID" screenshot "$SHOTS/t4-phone-spawn-takeover.png" >/dev/null 2>&1
echo "screenshot: $SHOTS/t4-phone-spawn-takeover.png"

echo "=== find the NEWLY SPAWNED scratch card (not the aaaaaa seed) ==="
NEWID="$(python3 - "$TASKS_JSON" <<'PY'
import json, sys
cards = json.load(open(sys.argv[1]))
# The scratch card the phone just spawned (origin scratch), newest first; the seed is a worktree card.
scratch = [c for c in cards if c.get("origin") == "scratch" or c.get("cwd","").find("/scratch/") >= 0]
scratch.sort(key=lambda c: c.get("createdAt",""))
print(scratch[-1]["id"] if scratch else "")
PY
)"
echo "spawned card id: ${NEWID:-<none found>}"

echo "=== daemon owner state for the SPAWNED card (proves auto-own) ==="
if [ -n "$NEWID" ]; then
  OWNER_JSON=$(ORCH_TEST_NAME=$NAME $T rpc agentTerminalOwner "{\"ref\":\"$NEWID\"}" 2>/dev/null)
  echo "$OWNER_JSON"
  # Gate the regression: auto-own must leave the spawned card PHONE-owned. A silent fallback to
  # desktop/available would still print a line — assert on ownerKind so it can't pass unnoticed.
  if echo "$OWNER_JSON" | grep -q '"ownerKind"[[:space:]]*:[[:space:]]*"phone"'; then
    echo "ASSERT ok: spawned card is phone-owned"
  else
    echo "ASSERT FAIL: expected ownerKind==phone for spawned card, got: $OWNER_JSON"; exit 1
  fi
else
  echo "ASSERT FAIL: no spawned card id found"; exit 1
fi
echo "=== grouped view sessions (attach happened) ==="
ORCH_TEST_NAME=$NAME $T tmux list-sessions 2>/dev/null | grep -E "__agent" || echo "(no grouped view-session yet)"
echo "=== sshd auth ==="; grep -iE "Accepted|error|fatal" "$D/sshd.log" | tail -5
echo "DONE"
