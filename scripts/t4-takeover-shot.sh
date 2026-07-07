#!/bin/bash
# T4 full-stack takeover SCREENSHOT (fully isolated — no user system changes).
#
# Two modes, one harness (the sim build/sshd/key-trust block lives in scripts/lib/t4-sim-harness.sh):
#
#   (default) SEEDED takeover — an ISOLATED orchestrad (ORCH_TEST_NAME=ot4shot) with a seeded card + a
#     stand-in live `agent` tmux window (the daemon never launches a real agent under its stripped PATH);
#     the Debug app auto-presents AgentTakeoverView for that card (ORCH_T4_AUTOTAKEOVER=1). Proves the
#     phone takes the .phone lease, SSH-attaches the agent window via the takeover recipe, and heartbeats.
#
#   --spawn   AUTO-OWN-ON-PHONE-SPAWN — an ISOLATED orchestrad (ORCH_TEST_NAME=ot4spawn) with a `claude`
#     SHIM on its PATH (execs a live `top`, so a spawned card's `agent` window is a real TUI without
#     launching/billing real Claude); the Debug app auto-opens the spawn sheet and auto-submits a scratch
#     spawn (ORCH_SPAWN_MODE=scratch + ORCH_SPAWN_AUTOSUBMIT=1). Proves a card spawned FROM THE PHONE
#     auto-becomes the phone's (D4 lease) with NO manual "Take Over" tap; asserts the NEWLY SPAWNED card
#     (not the seed) is phone-owned.
#
# Both use a throwaway non-root sshd on loopback trusting the Simulator's device key (never touches
# Remote Login). The screenshot shows the REAL TUI under the T4 chrome, and the daemon's owner state is
# asserted to prove the phone holds the lease.
#
# This is the phone-only stack. A live DESKTOP app retaking control at the same time is NOT exercised
# here (documented as deferred; desktop-retake semantics are covered by t4-takeover-verify.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

SPAWN=0
[ "${1:-}" = "--spawn" ] && SPAWN=1

ROOT="$(pwd)"
SHOTS="$ROOT/.scratch"
BUNDLE=com.orchestra.ios
USER_NAME="$(id -un)"
T="scripts/orch-test.sh"
if [ "$SPAWN" = 1 ]; then
  NAME=ot4spawn; PORT=12224
  D="$ROOT/.scratch/t4spawnsshd"
  SHIM="$ROOT/.scratch/t4spawn-shim"
  BUILD_LOG="$SHOTS/t4spawn-build.log"
  SHOT="$SHOTS/t4-phone-spawn-takeover.png"
  TASKS_JSON="/tmp/$NAME/home/Library/Application Support/Orchestra/tasks.json"
else
  NAME=ot4shot; PORT=12223
  D="$ROOT/.scratch/t4sshd"
  BUILD_LOG="$SHOTS/t4-build.log"
  SHOT="$SHOTS/t4-takeover.png"
  CARD=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
  SESSION=orchestra-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
fi
DAEMON_SOCK="/tmp/$NAME/home/Library/Application Support/Orchestra/orchestrad.sock"
mkdir -p "$SHOTS"
source scripts/lib/t4-sim-harness.sh

cleanup() {
  echo "=== cleanup ==="
  [ -f "$D/sshd.pid" ] && kill "$(cat "$D/sshd.pid")" 2>/dev/null
  pkill -f "sshd -f $D" 2>/dev/null
  ORCH_TEST_NAME=$NAME $T down >/dev/null 2>&1 || true
}
trap cleanup EXIT

t4_build_install
t4_export_pubkey

if [ "$SPAWN" = 1 ]; then
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
fi

t4_start_sshd

if [ "$SPAWN" = 1 ]; then
  echo "=== isolated orchestrad (with claude shim on PATH) ==="
  ORCH_TEST_NAME=$NAME $T init >/dev/null
  ORCH_TEST_NAME=$NAME ORCH_TEST_EXTRA_PATH="$SHIM" $T up >/dev/null
  sleep 1
else
  echo "=== isolated orchestrad + seeded agent window ==="
  ORCH_TEST_NAME=$NAME $T init >/dev/null
  ORCH_TEST_NAME=$NAME $T up   >/dev/null
  sleep 1
  ORCH_TEST_NAME=$NAME $T tmux new-session -d -s "$SESSION" -n agent -x 80 -y 24 2>/dev/null
  ORCH_TEST_NAME=$NAME $T tmux send-keys -t "$SESSION:agent" \
    "clear; printf '=== live agent TUI (stand-in) ===\\nphone owns this window via the T4 lease\\n\\n'; TERM=xterm-256color top" Enter 2>/dev/null
  sleep 1
fi

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
if [ "$SPAWN" = 1 ]; then
  echo "=== launch app → auto-open spawn sheet → auto-submit a SCRATCH spawn → auto-takeover ==="
  SIMCTL_CHILD_ORCH_DEV_SOCKET="$DAEMON_SOCK" \
  SIMCTL_CHILD_ORCH_SSH_TARGET="$USER_NAME@127.0.0.1:$PORT" \
  SIMCTL_CHILD_ORCH_SSH_ALLOW_LOOPBACK="1" \
  SIMCTL_CHILD_ORCH_SPAWN_MODE="scratch" \
  SIMCTL_CHILD_ORCH_SPAWN_AUTOSUBMIT="1" \
    xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  sleep 12
else
  echo "=== launch app → auto takeover ==="
  SIMCTL_CHILD_ORCH_DEV_SOCKET="$DAEMON_SOCK" \
  SIMCTL_CHILD_ORCH_SSH_TARGET="$USER_NAME@127.0.0.1:$PORT" \
  SIMCTL_CHILD_ORCH_SSH_ALLOW_LOOPBACK="1" \
  SIMCTL_CHILD_ORCH_T4_CARD="$CARD" \
  SIMCTL_CHILD_ORCH_T4_AUTOTAKEOVER="1" \
    xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  sleep 8
fi
xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null 2>&1
echo "screenshot: $SHOT"

if [ "$SPAWN" = 1 ]; then
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
else
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
fi
echo "=== sshd auth ==="; grep -iE "Accepted|error|fatal" "$D/sshd.log" | tail -5
echo "DONE"
