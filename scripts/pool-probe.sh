#!/bin/bash
# Measure PEAK COOPERATIVE-POOL STARVATION during `swift test --parallel`.
#
# Why this exists: `BranchLineage` / `RemoteParents` / `WorktreeRegistry` are actors that call
# synchronous `Proc.run` (a `git` fork), which parks the calling thread on a DispatchSemaphore. An
# actor runs on Swift's cooperative pool, which is ~one thread per core and NEVER GROWS — so a fork
# inside an actor consumes a non-replaceable pool thread. Enough of them and every async task in the
# process stops. This script measures how close we actually get.
#
# Per sample, for the test helper process:
#   total   = total threads
#   coop    = COOPERATIVE-POOL threads. Identified by the `sample` THREAD HEADER naming the queue
#             (`com.apple.root.<qos>.cooperative`) — NOT by a `swift_job_run` frame, which does not
#             appear in a symbolicated stack and yields a clean `parked=0` on a process that is
#             provably 100% starved. See scripts/pool-probe-control/ for the positive control.
#   blocked = threads parked on a semaphore (i.e. inside `Proc.run`'s `exited.wait()`)
#   parked  = threads that are BOTH -> a pool thread consumed by a git fork. THE NUMBER THAT MATTERS.
#
# Starvation requires `parked` to approach `hw.activecpu`. Measured 2026-07-12 on a wide run:
# peak parked = 1 of 18 across 1060 tests / 73 samples. See docs/09-design-decisions.md
# (the nudge-leak + cooperative-pool-starvation note).
#
# The suite does not terminate today (an unrelated pre-existing hang), so this stops itself once the
# helper goes CPU-idle and reaps its runner's whole descendant tree — otherwise a survivor holds the
# SwiftPM `.build` lock and the NEXT run blocks on it forever.
set -uo pipefail
cd "$(dirname "$0")/.."

WIDTH=$(sysctl -n hw.activecpu)
OUT=.scratch/pool-probe
rm -rf "$OUT"; mkdir -p "$OUT"
REPORT="$OUT/report.txt"
CSV="$OUT/samples.csv"
echo "t,helper_pid,total,coop,parked,blocked" > "$CSV"

echo "pool width (hw.activecpu) = $WIDTH" | tee "$REPORT"

# --- launch the suite in its own process group -------------------------------
perl -e 'setpgrp(0,0); exec @ARGV' swift test --parallel --disable-xctest > "$OUT/test.log" 2>&1 &
RUNNER=$!
PGID=$(ps -o pgid= -p $RUNNER | tr -d ' ')
echo "runner pid=$RUNNER pgid=$PGID" | tee -a "$REPORT"

# Neither the process group nor a name pattern is a safe handle for teardown:
#  - `swift-test` and `swiftpm-testing-helper` each setpgrp into their OWN group, so `kill -PGID`
#    misses them. A survivor keeps the SwiftPM `.build` LOCK and the next run blocks on it forever
#    (this cost a 40-minute no-op run);
#  - a `pkill -f swift-test` would kill ANOTHER AGENT's concurrent test run on this machine.
# So: enumerate the descendant tree of OUR runner by PID (ownership proof) and kill exactly those.
HELPER=""
descendants() {                       # echo every pid whose ancestor chain reaches $1
  ps -o pid=,ppid= -ax | awk -v root="$1" '
    { ppid[$1]=$2; pids[++n]=$1 }
    END {
      for (i=1; i<=n; i++) {
        p = pids[i]; q = p
        for (d=0; d<12; d++) {
          if (q == root) { print p; break }
          if (!(q in ppid) || q <= 1) break
          q = ppid[q]
        }
      }
    }'
}
cleanup() {
  local victims
  victims="$(descendants "$RUNNER") $RUNNER"
  for p in $victims; do kill -TERM "$p" 2>/dev/null; done
  sleep 2
  for p in $victims; do kill -KILL "$p" 2>/dev/null; done
  sleep 1
  local alive=""
  for p in $victims; do ps -p "$p" >/dev/null 2>&1 && alive="$alive $p"; done
  if [[ -n "$alive" ]]; then
    echo "WARNING: survivors (hold the .build lock!):$alive" | tee -a "$REPORT"
  else
    echo "cleanup: whole runner tree reaped, .build lock released" | tee -a "$REPORT"
  fi
  return 0
}
trap cleanup EXIT

PEAK_PARKED=0; PEAK_COOP=0; PEAK_TOTAL=0; PEAK_BLOCKED=0
IDLE=0; PREV_CPU=""
T0=$SECONDS

while true; do
  T=$((SECONDS - T0))
  (( T > 2400 )) && { echo "TIMEOUT 40m" | tee -a "$REPORT"; break; }

  # The actual test process (not the swift-build driver). It MUST be a DESCENDANT of our runner:
  #  - swift-test and swiftpm-testing-helper each create their OWN process group, so a pgid filter
  #    silently matches nothing (the sampler spins while the suite runs);
  #  - a bare name match would latch onto a stale reparented helper from an earlier run, OR onto
  #    ANOTHER AGENT's concurrent `swift test` — there is routinely one on this machine.
  # So walk the ppid chain up from each candidate and keep only one rooted at $RUNNER.
  HP=$(ps -o pid=,ppid=,comm= -ax | awk -v root="$RUNNER" '
    { ppid[$1]=$2; comm[$1]=$3 }
    END {
      for (p in comm) {
        if (comm[p] !~ /swiftpm-testing-helper|OrchestraPackageTests/) continue
        q = p
        for (i = 0; i < 12; i++) {            # bounded walk to the root
          if (q == root) { print p; exit }
          if (!(q in ppid) || q <= 1) break
          q = ppid[q]
        }
      }
    }')
  # Fail FAST if a stale SwiftPM holds the .build lock, instead of silently waiting out the timeout.
  if grep -q "already running using" "$OUT/test.log" 2>/dev/null; then
    echo "ABORT: .build lock held by another SwiftPM instance — nothing was measured" | tee -a "$REPORT"
    break
  fi
  if [[ -z "$HP" ]]; then
    kill -0 $RUNNER 2>/dev/null || { echo "runner exited at ${T}s" | tee -a "$REPORT"; break; }
    sleep 3; continue
  fi

  # Wedge detection uses ACCUMULATED CPU TIME, not %cpu: `ps %cpu` is a decaying average and reads
  # 0.0 on a helper that is actively running tests, which false-positives the idle detector and cuts
  # the run short. Ticks of consumed CPU cannot lie.
  HELPER="$HP"
  CPU=$(ps -o time= -p "$HP" 2>/dev/null | tr -d ' ')   # e.g. 01:23.45

  S="$OUT/s.txt"
  if sample "$HP" 1 -f "$S" >/dev/null 2>&1; then
    # split the sample's "Binary Images"-free call-graph into per-thread blocks and classify each
    # `sample` thread headers look like:  "    37 Thread_69321716   DispatchQueue_1: ..."
    # coop  = thread is running a Swift concurrency job (several possible frame names)
    # block = thread is parked on a semaphore (our Proc.run fork wait)
    # A cooperative-pool thread announces itself in its `sample` THREAD HEADER, e.g.
    #   Thread_69821020   DispatchQueue_9: com.apple.root.background-qos.cooperative  (concurrent)
    # There is NO `swift_job_run` frame to key on — keying on one reports 0 even on a process that is
    # provably 100% starved (validated against scripts/pool-probe-control, which parks all 18 pool threads).
    read -r TOTAL COOP PARKED BLOCKED < <(awk '
      function flush() { if (t) { tot++; if (c) coop++; if (b) blk++; if (c && b) parked++ } }
      /^ +[0-9]+ Thread_/ { flush(); t=1; c=0; b=0; if ($0 ~ /cooperative/) c=1 }
      /libswift_Concurrency/ { c=1 }
      /semaphore_wait_trap|_dispatch_sema4_wait|__psynch_cvwait/ { b=1 }
      END { flush(); print tot+0, coop+0, parked+0, blk+0 }
    ' "$S")
    echo "$T,$HP,$TOTAL,$COOP,$PARKED,$BLOCKED" >> "$CSV"
    (( PARKED > PEAK_PARKED )) && { PEAK_PARKED=$PARKED; cp "$S" "$OUT/peak-parked.sample"; }
    (( COOP  > PEAK_COOP  ))   && PEAK_COOP=$COOP
    (( TOTAL > PEAK_TOTAL ))   && PEAK_TOTAL=$TOTAL
    (( BLOCKED > PEAK_BLOCKED )) && { PEAK_BLOCKED=$BLOCKED; cp "$S" "$OUT/peak-blocked.sample"; }
    printf 't=%-5s cpu=%-9s total=%-4s coop=%-3s parked=%-3s blocked=%-3s | peak parked=%s/%s\n' \
      "$T" "$CPU" "$TOTAL" "$COOP" "$PARKED" "$BLOCKED" "$PEAK_PARKED" "$WIDTH"
  fi

  # wedge detector: helper's consumed CPU time stops advancing for ~90s => bug-#2 wedge; we already
  # have the entire load window, which is all this probe needs.
  if [[ "$CPU" == "$PREV_CPU" ]]; then IDLE=$((IDLE+1)); else IDLE=0; fi
  PREV_CPU="$CPU"
  if (( IDLE >= 45 )); then echo "helper CPU-idle ~90s at t=${T}s => bug-#2 wedge; stopping" | tee -a "$REPORT"; break; fi

  sleep 2
done

{
  echo "---"
  echo "pool width (hw.activecpu) : $WIDTH"
  echo "PEAK total threads        : $PEAK_TOTAL"
  echo "PEAK cooperative threads  : $PEAK_COOP"
  echo "PEAK blocked threads (any): $PEAK_BLOCKED"
  echo "PEAK PARKED coop threads  : $PEAK_PARKED   <-- the number that decides the card"
  echo "tests run: $(grep -cE '^Test .* (passed|failed) after' "$OUT/test.log" 2>/dev/null || echo '?')"
} | tee -a "$REPORT"
