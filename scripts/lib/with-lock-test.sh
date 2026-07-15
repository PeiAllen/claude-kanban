#!/bin/bash
# Tests for scripts/lib/with-lock.sh — the build/ship mutex.
#
# Each case pins a property that a code review proved we could not get wrong safely:
#   1. mutual exclusion            — the whole point
#   2. crash safety                — kill -9 the holder, the lock must free
#   3. NO fd leak to a daemon      — the bug that would strand the mutex for hours
#   4. fail-open on timeout        — a build must never FAIL because it waited
#   5. exit code + argv fidelity   — the wrapper must be transparent
#   6. uncontended = no overhead   — must not slow a single card's build
#
# Usage: scripts/lib/with-lock-test.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
WITH_LOCK="scripts/lib/with-lock.sh"
LOCK_FILE="$(git rev-parse --git-common-dir)/orchestra-testlock.lock"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

echo "1. mutual exclusion — two contending commands must not overlap"
# Each writes start/end markers; with a mutex the intervals cannot interleave.
( $WITH_LOCK testlock -- bash -c 'echo A-start >> '"$TMP"'/order; sleep 1.5; echo A-end >> '"$TMP"'/order' ) &
sleep 0.3
( $WITH_LOCK testlock -- bash -c 'echo B-start >> '"$TMP"'/order; sleep 0.2; echo B-end >> '"$TMP"'/order' ) &
wait
check "serialized (no interleave)" "$(tr '\n' ' ' < "$TMP/order" | xargs)" "A-start A-end B-start B-end"

echo "2. crash safety — kill -9 the holder, the next waiter must proceed"
$WITH_LOCK testlock -- bash -c 'echo $$ > '"$TMP"'/holder.pid; sleep 30' &
sleep 1
# kill the whole holder tree hard
HOLDER_WRAPPER=$!
kill -9 $(cat "$TMP/holder.pid") 2>/dev/null
kill -9 $HOLDER_WRAPPER 2>/dev/null
wait 2>/dev/null
START=$(date +%s)
timeout_guard=$( ORCH_BUILD_LOCK_TIMEOUT=20 $WITH_LOCK testlock -- echo "acquired-after-crash" 2>/dev/null )
ELAPSED=$(( $(date +%s) - START ))
check "lock freed after kill -9" "$timeout_guard" "acquired-after-crash"
if [[ $ELAPSED -le 5 ]]; then ok "freed promptly (${ELAPSED}s)"; else bad "took ${ELAPSED}s — did it fail open instead of being freed?"; fi

echo "3. NO fd leak — a daemonised grandchild must NOT keep holding the lock"
# The regression that would strand the machine-wide mutex: a backgrounded daemon inheriting
# the lock fd (flock frees on last close of the file description, not on the locker's exit).
$WITH_LOCK testlock -- bash -c "nohup sleep 30 > /dev/null 2>&1 & echo \$! > $TMP/daemon.pid; exit 0"
sleep 0.5
DAEMON_PID=$(cat "$TMP/daemon.pid")
if kill -0 "$DAEMON_PID" 2>/dev/null; then
  # The daemon is still alive. If it inherited the lock fd, the lock is still held.
  START=$(date +%s)
  got=$( ORCH_BUILD_LOCK_TIMEOUT=8 $WITH_LOCK testlock -- echo "lock-not-leaked" 2>/dev/null )
  ELAPSED=$(( $(date +%s) - START ))
  check "lock released despite live daemonised grandchild" "$got" "lock-not-leaked"
  if [[ $ELAPSED -le 3 ]]; then ok "acquired immediately (${ELAPSED}s) — fd did not leak"
  else bad "waited ${ELAPSED}s — the daemon LEAKED the lock fd"; fi
  kill -9 "$DAEMON_PID" 2>/dev/null
else
  bad "test setup: daemon did not survive"
fi

echo "4. fail-open — a build must NEVER fail merely because it waited"
$WITH_LOCK testlock -- sleep 10 &
HOG=$!
sleep 0.5
START=$(date +%s)
out=$( ORCH_BUILD_LOCK_TIMEOUT=2 $WITH_LOCK testlock -- echo "ran-unlocked" 2>"$TMP/warn.txt" )
ELAPSED=$(( $(date +%s) - START ))
check "ran anyway after timeout" "$out" "ran-unlocked"
if grep -q "proceeding WITHOUT the lock" "$TMP/warn.txt"; then ok "warned loudly on stderr"; else bad "no loud warning"; fi
if [[ $ELAPSED -ge 2 && $ELAPSED -le 6 ]]; then ok "waited ~timeout then proceeded (${ELAPSED}s)"; else bad "unexpected wait ${ELAPSED}s"; fi
kill -9 $HOG 2>/dev/null; wait 2>/dev/null

echo "5. transparency — exit code and argv must pass through untouched"
$WITH_LOCK testlock -- bash -c 'exit 42'; check "exit code preserved" "$?" "42"
check "args with spaces preserved" "$($WITH_LOCK testlock -- printf '%s|' one 'two three' four)" "one|two three|four|"

echo "6. visible wait — a waiting card must SAY it is waiting"
$WITH_LOCK testlock -- sleep 3 &
HOG=$!
sleep 0.5
ORCH_BUILD_LOCK_TIMEOUT=30 $WITH_LOCK testlock -- true 2>"$TMP/wait.txt"
if grep -q "waiting for slot" "$TMP/wait.txt"; then ok "wait is visible on stderr"; else bad "wait was SILENT — violates the DoD"; fi
kill -9 $HOG 2>/dev/null; wait 2>/dev/null

echo "7. no overhead when uncontended"
START=$(date +%s%N)
$WITH_LOCK testlock -- true
MS=$(( ( $(date +%s%N) - START ) / 1000000 ))
if [[ $MS -lt 1000 ]]; then ok "uncontended overhead ${MS}ms"; else bad "uncontended overhead ${MS}ms — too slow"; fi

echo "8. SIGTERM must NOT orphan the child and silently release the lock"
# Regression: with `subprocess.call` and no signal handling, killing the wrapper left the
# compiler running UNLOCKED while the next card grabbed the lock and built concurrently.
# `orchestra exec` kills at 120s and Bash caps at 600s, so this is a routine event.
$WITH_LOCK testlock -- bash -c 'echo $$ > '"$TMP"'/child.pid; sleep 30' &
WRAPPER=$!
sleep 1
CHILD=$(cat "$TMP/child.pid")
kill -TERM $WRAPPER 2>/dev/null
sleep 1.5
if kill -0 "$CHILD" 2>/dev/null; then
  bad "child ORPHANED — it is still running unlocked after the holder was killed"
  kill -9 "$CHILD" 2>/dev/null
else
  ok "SIGTERM forwarded — child died with the holder (no unlocked orphan)"
fi
wait 2>/dev/null

echo "9. --strict must NEVER fail open (it guards shared state)"
$WITH_LOCK --strict shiptest -- sleep 5 &
HOG=$!
sleep 0.5
if ORCH_SHIPTEST_LOCK_TIMEOUT=1 $WITH_LOCK --strict shiptest -- echo "SHOULD-NOT-RUN" >"$TMP/strict.out" 2>"$TMP/strict.err"; then
  bad "strict lock PROCEEDED without the lock — would corrupt /Applications"
else
  if grep -q "SHOULD-NOT-RUN" "$TMP/strict.out"; then bad "strict lock ran the command anyway"
  else ok "strict lock failed CLOSED (did not run the command unlocked)"; fi
fi
kill -9 $HOG 2>/dev/null; wait 2>/dev/null

echo "10. signal-killed child reports the shell-conventional code (128+N, not 247)"
$WITH_LOCK testlock -- bash -c 'kill -9 $$'; RC=$?
check "SIGKILLed child -> 137" "$RC" "137"

echo "11. must work from a cwd that is NOT a git repo (agents call it from anywhere)"
OUTSIDE="$(mktemp -d)"
got=$( cd "$OUTSIDE" && "$OLDPWD/$WITH_LOCK" testlock -- echo "ran-outside-repo" 2>/dev/null )
check "runs from a non-git cwd" "$got" "ran-outside-repo"
rmdir "$OUTSIDE" 2>/dev/null

rm -f "$LOCK_FILE" "$(git rev-parse --git-common-dir)/orchestra-shiptest.lock"
echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
