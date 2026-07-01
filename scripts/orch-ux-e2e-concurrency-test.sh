#!/usr/bin/env bash
#
# orch-ux-e2e-concurrency-test.sh — prove scripts/orch-ux-e2e.sh is concurrency-safe.
#
# Launches N (default 3) instances of the UX-e2e harness CONCURRENTLY, each with its own RUN_ID,
# and asserts the properties an unattended overnight fan-out needs:
#   1. each run gets its OWN isolated $HOME/socket, tmux server, and screenshot dir (distinct paths);
#   2. each run produces its OWN screenshot;
#   3. ALL runs complete successfully — none is killed by a sibling's teardown (the regression the
#      old single-instance harness had: shared /tmp root + `pkill -f daemon` + shared `kill-server`);
#   4. the live daemon/app is untouched.
#
# It shares ONE prebuilt app bundle (built once via `--build-only`), then runs the instances with
# `--no-build`, so N concurrent runs don't each rebuild (and can't corrupt the shared DerivedData).
#
# Run UNSANDBOXED (the harness binds a UDS socket, launches a GUI app, screencaptures).
#
# Usage: scripts/orch-ux-e2e-concurrency-test.sh [N]
# Env:   UX_E2E_GUI_SLOTS=N  GUI concurrency cap passed through (default 2 → with N=3 the cap gates)
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
HARNESS="$REPO_ROOT/scripts/orch-ux-e2e.sh"
[[ -x "$HARNESS" ]] || { echo "missing $HARNESS" >&2; exit 1; }

N="${1:-3}"
ALL_IDS=(cctA1 cctB2 cctC3 cctD4 cctE5)   # distinct, tame RUN_IDs (→ short UDS socket paths)
IDS=("${ALL_IDS[@]:0:$N}")
LOGDIR="$REPO_ROOT/.scratch/cc-test"
LIVE_SOCK="$HOME/Library/Application Support/Orchestra/orchestrad.sock"

rm -rf "$LOGDIR"; mkdir -p "$LOGDIR"
fails=0
note() { echo "  $*"; }
check() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; fails=$((fails + 1)); fi; }

echo "== live daemon/app snapshot BEFORE =="
live_before="$(lsof -t -- "$LIVE_SOCK" 2>/dev/null | sort | tr '\n' ' ' || true)"
echo "  live socket listener pids: ${live_before:-<none / live daemon not running>}"

echo "== prebuild the shared bundle once (--build-only) =="
"$HARNESS" --build-only

echo "== launching $N concurrent runs (--no-build), RUN_IDs: ${IDS[*]} =="
pids=()
for id in "${IDS[@]}"; do
  ( RUN_ID="$id" "$HARNESS" --no-build > "$LOGDIR/run-$id.log" 2>&1; echo $? > "$LOGDIR/run-$id.rc" ) &
  pids+=("$!")
  note "started run-$id (pid $!)"
done
# Collect via rc files, not wait's status, so one failure doesn't abort the assertions (set -e).
for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
echo "== all runs finished; asserting =="

# --- per-run assertions ---
declare -a roots=()
for id in "${IDS[@]}"; do
  log="$LOGDIR/run-$id.log"; rc="$(cat "$LOGDIR/run-$id.rc" 2>/dev/null || echo 99)"
  out=".scratch/ux-e2e-$id/board.png"
  echo "-- run-$id (exit $rc) --"
  check "run-$id exited 0 (not killed by a sibling)"      "[[ '$rc' == '0' ]]"
  check "run-$id reached PASS"                            "grep -q '▶ PASS' '$log'"
  check "run-$id produced its OWN screenshot ($out)"      "[[ -s '$REPO_ROOT/$out' ]]"
  check "run-$id used its OWN isolated socket (…-$id/…)"  "grep -q 'daemon isolated at /tmp/orch-ux-e2e-$id/' '$log'"
  check "run-$id used its OWN tmux/OUT namespace"         "grep -q 'run-id=$id' '$log'"
  # record the isolated ROOT token this run reported (space-free: stops before /home/… which
  # contains 'Application Support'), for the cross-run distinctness check.
  r="$(grep -oE '/tmp/orch-ux-e2e-[A-Za-z0-9._-]+' "$log" | head -1 || true)"
  roots+=("$r")
  # no run may ever reference the LIVE socket path
  check "run-$id never touched the live socket"          "! grep -q 'listening at $LIVE_SOCK' '$log'"
done

# --- cross-run distinctness: every run's isolated root (→ socket/HOME/data) is unique ---
uniq_roots="$(printf '%s\n' "${roots[@]}" | sort -u | grep -c . || true)"
check "all $N runs used DISTINCT isolated roots/sockets"  "[[ '$uniq_roots' == '$N' ]]"

# --- distinct screenshots (distinct paths, all present) ---
present=0; for id in "${IDS[@]}"; do [[ -s "$REPO_ROOT/.scratch/ux-e2e-$id/board.png" ]] && present=$((present+1)); done
check "all $N runs produced a screenshot at a distinct path" "[[ '$present' == '$N' ]]"

# --- live daemon/app untouched ---
echo "== live daemon/app snapshot AFTER =="
live_after="$(lsof -t -- "$LIVE_SOCK" 2>/dev/null | sort | tr '\n' ' ' || true)"
echo "  live socket listener pids: ${live_after:-<none>}"
check "live daemon listener unchanged (before == after)"  "[[ '$live_before' == '$live_after' ]]"

echo
if [[ "$fails" == 0 ]]; then
  echo "▶ CONCURRENCY TEST PASS — $N runs isolated, all completed, no cross-run kill, live untouched."
  exit 0
else
  echo "▶ CONCURRENCY TEST FAIL — $fails assertion(s) failed. Logs in $LOGDIR/"
  exit 1
fi
