#!/usr/bin/env bash
# T4 phone-takeover LEASE round-trip against an isolated daemon (no live app touched).
#
# Drives the D4 ownership RPCs in the EXACT sequence the phone's TakeoverController performs, proving the
# lease half of the T4 gate without needing the iOS app or the desktop app running:
#
#   1. agentTerminalOwner            → available (owner null)
#   2. takeOver(kind=phone)          → owner=phone, epoch++   (what "Take Over Agent Terminal" does)
#   3. agentTerminalOwner            → confirms phone owns at that epoch (what the surface reads)
#   4. heartbeat(phone, epoch)       → stays phone + fresh     (the 10s heartbeat loop)
#   5. takeOver(kind=desktop)        → owner=desktop, epoch++  (a DESKTOP RETAKE — the drop signal)
#   6. release(phone, OLD epoch)     → epoch-guarded no-op; owner STAYS desktop (can't clear a newer owner)
#   7. release(desktop, new epoch)   → available again
#
# Runs unsandboxed (the daemon binds a UDS socket + writes its data dir). Uses ORCH_TEST_NAME=ot4 so it
# never collides with the live daemon or a parallel orch-test run.
set -uo pipefail
cd "$(dirname "$0")/.."

export ORCH_TEST_NAME=ot4
T=scripts/orch-test.sh
REF=aaaaaa                      # shortId of orch-test's fixed seeded card
PHONE=phone-t4
DESK=desk-t4
FAILED=0

jq_field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
owner_kind() { $T rpc agentTerminalOwner "{\"ref\":\"$REF\"}" 2>/dev/null | jq_field "((d.get('owner') or {}) or {}).get('ownerKind')"; }
owner_epoch() { $T rpc agentTerminalOwner "{\"ref\":\"$REF\"}" 2>/dev/null | jq_field "d.get('epoch')"; }

check() { # label expected actual
  if [ "$2" = "$3" ]; then echo "  ✓ $1 ($3)"; else echo "  ✗ $1 — expected '$2', got '$3'"; FAILED=1; fi
}

SESSION=orchestra-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee   # orchestra-<lowercased CARD_ID>

echo "=== T4 lease round-trip (isolated daemon ORCH_TEST_NAME=$ORCH_TEST_NAME) ==="
$T init  >/dev/null
$T up     >/dev/null
sleep 1
trap '$T down >/dev/null 2>&1 || true' EXIT

# Seed a stand-in `agent` window on the daemon's isolated tmux socket. The orch-test daemon runs under a
# PATH with no real claude/codex, so it never launches an agent (or a tmux session) on its own — but the
# takeover lease resolves the target by finding the card's `agent` window, so we create one (a live TUI, so
# an attach would render something). This is exactly the window a real agent occupies; provider-neutral.
$T tmux new-session -d -s "$SESSION" -n agent -x 80 -y 24 2>/dev/null
$T tmux send-keys -t "$SESSION:agent" \
  "clear; printf '=== T4 agent window (stand-in) ===\\n'; TERM=xterm-256color top" Enter 2>/dev/null
sleep 1

echo "1. initial owner"
check "available at start" "None" "$(owner_kind)"
E0=$(owner_epoch); echo "   epoch0=$E0"

echo "2. phone takeover"
R=$($T rpc takeOverAgentTerminal "{\"ref\":\"$REF\",\"clientId\":\"$PHONE\",\"kind\":\"phone\"}" 2>/dev/null)
E1=$(printf '%s' "$R" | jq_field "d['state']['epoch']")
KIND1=$(printf '%s' "$R" | jq_field "d['state']['owner']['ownerKind']")
TGT=$(printf '%s' "$R" | jq_field "d['target']['target']")
check "owner=phone after takeover" "phone" "$KIND1"
check "epoch incremented" "True" "$([ "$E1" -gt "$E0" ] && echo True || echo False)"
echo "   attach target=$TGT  epoch1=$E1"

echo "3. owner query reflects phone"
check "agentTerminalOwner=phone" "phone" "$(owner_kind)"
check "owner query epoch=epoch1" "$E1" "$(owner_epoch)"

echo "4. heartbeat keeps it phone"
$T rpc heartbeatAgentTerminal "{\"ref\":\"$REF\",\"clientId\":\"$PHONE\",\"epoch\":$E1}" >/dev/null 2>&1
check "still phone after heartbeat" "phone" "$(owner_kind)"

echo "5. DESKTOP RETAKE (the drop signal)"
RD=$($T rpc takeOverAgentTerminal "{\"ref\":\"$REF\",\"clientId\":\"$DESK\",\"kind\":\"desktop\"}" 2>/dev/null)
E2=$(printf '%s' "$RD" | jq_field "d['state']['epoch']")
check "owner flips to desktop" "desktop" "$(owner_kind)"
check "retake epoch > phone epoch" "True" "$([ "$E2" -gt "$E1" ] && echo True || echo False)"
echo "   epoch2=$E2  → phoneTakeoverStatus would now read LOST"

echo "6. stale phone release is epoch-guarded"
$T rpc releaseAgentTerminal "{\"ref\":\"$REF\",\"clientId\":\"$PHONE\",\"epoch\":$E1}" >/dev/null 2>&1
check "stale phone release did NOT clear desktop" "desktop" "$(owner_kind)"

echo "7. desktop releases at current epoch"
$T rpc releaseAgentTerminal "{\"ref\":\"$REF\",\"clientId\":\"$DESK\",\"epoch\":$E2}" >/dev/null 2>&1
check "available after desktop release" "None" "$(owner_kind)"

echo
if [ "$FAILED" = 0 ]; then echo "=== T4 LEASE ROUND-TRIP: ALL CHECKS PASSED ==="; else echo "=== T4 LEASE ROUND-TRIP: FAILURES ==="; fi
exit $FAILED
