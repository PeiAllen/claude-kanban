#!/usr/bin/env bash
#
# orch-ux-e2e.sh — full APP+DAEMON UX e2e on a DISPOSABLE, ISOLATED Orchestra instance.
#
# Combines the two prior half-harnesses into a real end-to-end UI test:
#   • scripts/orch-test.sh    — an isolated daemon (own HOME + tmux socket), but NO app UI
#   • scripts/orch-ui-shot.sh — the app UI, but a MOCK card with NO daemon
# Here the DEMO APP is launched against a REAL, isolated daemon, so board actions and the
# UC1–UC8 workflows can be driven through the actual UI and screenshotted — WITHOUT ever
# touching the live daemon/app the user is running.
#
# ISOLATION CONTRACT (why this can't touch live):
#   • $HOME is the ONLY steering lever. Config.home -> $HOME derives the daemon's
#     socket/data/config AND the app's ControlClient path (Config.socketPath). So an
#     isolated-$HOME app + isolated-$HOME daemon connect to EACH OTHER, never live.
#   • orchestrad is SPAWNED DIRECTLY under the isolated $HOME — NOT via launchctl. The
#     LaunchAgent label `com.orchestra.daemon` is fixed / not HOME-namespaced, so the app's
#     install path (ensureDaemonAndStart) would collide with the live agent. We never call it.
#   • ORCHESTRA_TMUX_SOCKET isolates the tmux server too (agent panes don't hit -L orchestra).
#   • PATH excludes ~/.local/bin so a spawned card can't find/bill a real `claude`
#     (USE_REAL_CLAUDE=1 opts in).
#
# CONCURRENCY CONTRACT (why N runs can run at once, overnight, unattended):
#   • Every per-run resource is namespaced by RUN_ID (default $$): the isolated $HOME/socket
#     ($ROOT), the tmux server (ISO_TMUX_SOCKET), and the screenshot dir ($OUT). Two runs with
#     different RUN_IDs share NOTHING mutable.
#   • Teardown is PID-SCOPED: cleanup() kills ONLY this run's captured $APP_PID + $DAEMON_PID and
#     removes ONLY this run's tmux socket + $ROOT. There is NO `pkill -f`/global `kill-server`, so
#     a run can NEVER tear down a sibling's daemon/tmux — the old cross-run-kill regression.
#   • The APP BUNDLE is read-only at launch, so all runs SHARE one prebuilt bundle in a shared
#     DerivedData ($DD). A build MUTEX (mkdir-based; flock is absent on macOS) serializes the
#     first-callers so concurrent xcodebuilds can't corrupt $DD; later runs reuse it read-only.
#   • A GUI concurrency CAP (mkdir-based counting semaphore, UX_E2E_GUI_SLOTS slots, default 2)
#     bounds how many real app windows fight the single macOS window server at once.
#
# Run UNSANDBOXED: builds an app bundle (xcodebuild needs ~/Library), binds a UDS socket,
# writes its data dir, launches a GUI app, and screencaptures by window id.
#
# Usage: scripts/orch-ux-e2e.sh [--no-build] [--rebuild] [--build-only] [--run-id ID] [outdir]
#   --no-build     reuse the shared prebuilt daemon+app (skip the build step)
#   --rebuild      force a fresh build even if a shared bundle already exists
#   --build-only   build the shared daemon+app bundle into $DD, then exit (for prebuild/warmup)
#   --run-id ID    namespace all per-run state under ID (default: this PID). May also be given
#                  via the RUN_ID env var; a caller (e.g. a PR card) can pass its shortId.
#   outdir         screenshot dir (default: ./.scratch/ux-e2e-<RUN_ID>)
# Env:
#   RUN_ID=…              per-run namespace (overridden by --run-id)
#   UX_E2E_GUI_SLOTS=N    max concurrent GUI launch+screenshot sections (default 2)
#   USE_REAL_CLAUDE=1     let a spawned card find the real `claude` on PATH (default: masked)
set -euo pipefail
# Force a UTF-8 locale: under C/POSIX, bash folds a trailing multibyte glyph (e.g. `…`) into an
# adjacent $var name, breaking `set -u`. macOS always ships en_US.UTF-8.
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# --- args ---
BUILD=1            # 0 with --no-build: reuse shared bundle
FORCE_BUILD=0      # 1 with --rebuild: rebuild even if present
BUILD_ONLY=0       # 1 with --build-only: build the shared bundle then exit
RUN_ID="${RUN_ID:-$$}"
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build)   BUILD=0; shift ;;
    --rebuild)    FORCE_BUILD=1; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --run-id)     RUN_ID="${2:?--run-id needs an argument}"; shift 2 ;;
    --run-id=*)   RUN_ID="${1#*=}"; shift ;;
    --*)          echo "unknown flag: $1" >&2; exit 2 ;;
    *)            OUT="$1"; shift ;;
  esac
done
# RUN_ID goes into a UDS socket path (must stay < 104 chars) and filenames — keep it tame.
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "RUN_ID must match [A-Za-z0-9._-]+ (got: $RUN_ID)" >&2; exit 2; }
OUT="${OUT:-./.scratch/ux-e2e-$RUN_ID}"
mkdir -p "$OUT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# --- per-run isolated instance roots (short /tmp path: UDS socket must stay < 104 chars) ---
# e.g. /tmp/orch-ux-e2e-aaaaaa/home/Library/Application Support/Orchestra/orchestrad.sock = 82 chars.
ROOT="/tmp/orch-ux-e2e-$RUN_ID"
ISO_HOME="$ROOT/home"
DATA="$ISO_HOME/Library/Application Support/Orchestra"
SOCK="$DATA/orchestrad.sock"
LIVE_SOCK="$HOME/Library/Application Support/Orchestra/orchestrad.sock"
ISO_TMUX_SOCKET="orch-ux-e2e-$RUN_ID"
CARD_ID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"   # shortId "aaaaaa"
DAEMON="$REPO_ROOT/.build/debug/orchestrad"
# DerivedData under a cwd-relative gitignored dir (NOT $TMPDIR — the sandbox resolves that to a
# different path than an unsandboxed run, so --no-build couldn't find the bundle). No socket here,
# so the 104-char limit that forces $ROOT into /tmp doesn't apply. SHARED across runs: the app
# binary is read-only at launch, so N runs reuse one bundle (guarded by a build mutex below).
DD="$REPO_ROOT/.scratch/orch-ux-e2e-dd"
BUILD_LOCK="$REPO_ROOT/.scratch/orch-ux-e2e-build.lock"     # mkdir-mutex dir (cross-run)
GUI_SLOT_ROOT="/tmp/orch-ux-e2e-guislots"                   # mkdir-semaphore dir (cross-run)
GUI_SLOTS="${UX_E2E_GUI_SLOTS:-2}"
if [ "${USE_REAL_CLAUDE:-0}" = "1" ]; then RUN_PATH="$PATH"; else RUN_PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"; fi
# Fake-agent fixture: when NOT opting into a real vendor binary, prepend a per-run bin dir whose
# `claude`/`codex` symlink points at scripts/fixtures/fake-agent, so a spawned card launches an inert,
# non-billing agent (ClaudeCodeAdapter/CodexAdapter resolve the binary off PATH). Populated in the
# seed step (needs $ROOT). USE_REAL_CLAUDE=1 skips this and uses the real PATH.
FAKE_BIN="$ROOT/fakebin"
if [ "${USE_REAL_CLAUDE:-0}" != "1" ]; then RUN_PATH="$FAKE_BIN:$RUN_PATH"; fi

APP_PID=""
DAEMON_PID=""
HELD_BUILD_LOCK=""
GUI_SLOT_HELD=""
# PID-scoped teardown ONLY. Never `pkill -f "$DAEMON"` or a shared `kill-server` — that is exactly
# the cross-run-kill bug: it would reap every sibling run's daemon/tmux. We kill only what THIS run
# spawned (captured $APP_PID/$DAEMON_PID) and remove only THIS run's tmux socket + $ROOT, plus
# release any cross-run lock/slot we still hold.
cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
  [[ -n "$DAEMON_PID" ]] && kill "$DAEMON_PID" 2>/dev/null || true
  tmux -L "$ISO_TMUX_SOCKET" kill-server 2>/dev/null || true   # per-run socket → only this run's tmux
  rm -rf "$ROOT"                                                # per-run root → only this run's data
  [[ -n "$GUI_SLOT_HELD" ]] && rm -rf "$GUI_SLOT_HELD" 2>/dev/null || true
  [[ -n "$HELD_BUILD_LOCK" ]] && rm -rf "$BUILD_LOCK" 2>/dev/null || true
}
trap cleanup EXIT

fail() { echo "  ✗ $*" >&2; exit 1; }

# --- cross-run mkdir locks (flock is absent on macOS; mkdir is atomic on POSIX) ---
# A dead holder never wedges the lock: we reclaim a slot/lock whose recorded PID is no longer alive.
_reclaim_if_dead() {  # $1=lockdir — rm it if its pid file names a dead process
  local d="$1" holder
  holder="$(cat "$d/pid" 2>/dev/null || true)"
  [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null && rm -rf "$d" 2>/dev/null || true
}
acquire_build_lock() {
  local waited=0
  mkdir -p "$REPO_ROOT/.scratch"
  until mkdir "$BUILD_LOCK" 2>/dev/null; do
    _reclaim_if_dead "$BUILD_LOCK"
    sleep 0.5; waited=$((waited + 1))
    [[ $waited -gt 2400 ]] && fail "build lock $BUILD_LOCK stuck (>20min)"
  done
  echo "$$" > "$BUILD_LOCK/pid"; HELD_BUILD_LOCK=1
}
release_build_lock() { rm -rf "$BUILD_LOCK" 2>/dev/null || true; HELD_BUILD_LOCK=""; }
acquire_gui_slot() {  # counting semaphore: grab any of GUI_SLOTS slot dirs
  local waited=0 i
  mkdir -p "$GUI_SLOT_ROOT"
  while true; do
    for i in $(seq 1 "$GUI_SLOTS"); do
      if mkdir "$GUI_SLOT_ROOT/slot.$i" 2>/dev/null; then
        echo "$$" > "$GUI_SLOT_ROOT/slot.$i/pid"; GUI_SLOT_HELD="$GUI_SLOT_ROOT/slot.$i"; return 0
      fi
      _reclaim_if_dead "$GUI_SLOT_ROOT/slot.$i"
    done
    sleep 0.5; waited=$((waited + 1))
    [[ $waited -gt 2400 ]] && fail "no GUI slot after >20min (UX_E2E_GUI_SLOTS=$GUI_SLOTS)"
  done
}
release_gui_slot() { [[ -n "$GUI_SLOT_HELD" ]] && rm -rf "$GUI_SLOT_HELD" 2>/dev/null || true; GUI_SLOT_HELD=""; }

# --- 0. safety: never point at the live socket ---
[[ "$SOCK" == "$LIVE_SOCK" ]] && fail "isolated socket == live socket — aborting"

# app bundle discovery (post-build); used both to decide if a build is needed and to launch.
find_app() { /usr/bin/find "$DD/Build/Products/Debug" -maxdepth 1 -name 'Orchestra.app' 2>/dev/null | head -1; }
artifacts_present() {
  [[ -x "$DAEMON" ]] || return 1
  local app; app="$(find_app)"
  [[ -n "$app" && -x "$app/Contents/MacOS/Orchestra" ]]
}

do_build() {
  echo "▶ building daemon (debug) + app (Debug)…"
  "$REPO_ROOT"/scripts/lib/with-lock.sh build -- swift build --package-path "$REPO_ROOT" --product orchestrad >&2
  xcodegen generate --spec App/project.yml --project App >/dev/null
  "$(dirname "$0")/lib/with-lock.sh" build -- xcodebuild -project App/Orchestra.xcodeproj -scheme Orchestra -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DD" build >/dev/null
}

# --- 1. build (shared, build-once) — serialize concurrent first-callers behind a mutex ---
if [[ "$BUILD" == 1 || "$BUILD_ONLY" == 1 ]]; then
  acquire_build_lock
  # Re-check INSIDE the lock: a sibling may have just built the shared bundle while we waited.
  if [[ "$FORCE_BUILD" == 1 ]] || ! artifacts_present; then
    do_build
  else
    echo "▶ reusing shared prebuilt bundle in $DD (use --rebuild to force)"
  fi
  release_build_lock
fi
if [[ "$BUILD_ONLY" == 1 ]]; then
  artifacts_present || fail "build-only: artifacts missing after build"
  echo "▶ build-only: shared daemon+app ready in $DD"
  exit 0
fi
[[ -x "$DAEMON" ]] || fail "daemon not built at $DAEMON (run without --no-build, or --build-only first)"
APP="$(find_app)"
BIN="$APP/Contents/MacOS/Orchestra"
[[ -n "$APP" && -x "$BIN" ]] || fail "app binary not found in $DD (run without --no-build, or --build-only first)"

# --- 2. seed the isolated data dir: throwaway repo + worktree + one card ---
echo "▶ seeding isolated \$HOME at ${ISO_HOME}"
rm -rf "$ROOT"; mkdir -p "$DATA" "$ROOT/repo"
# Fake-agent bin (unless USE_REAL_CLAUDE=1): a `claude`/`codex` on PATH that idles, never bills.
if [ "${USE_REAL_CLAUDE:-0}" != "1" ]; then
  mkdir -p "$FAKE_BIN"
  ln -sf "$REPO_ROOT/scripts/fixtures/fake-agent" "$FAKE_BIN/claude"
  ln -sf "$REPO_ROOT/scripts/fixtures/fake-agent" "$FAKE_BIN/codex"
fi
( cd "$ROOT/repo" && git init -q && git config user.email t@t.t && git config user.name t \
    && git commit -q --allow-empty -m init && git worktree add -q ../wt -b verify )
python3 - "$DATA/tasks.json" "$ROOT/repo" "$ROOT/wt" "$CARD_ID" <<'PY'
import json, sys
tasks, repo, wt, cid = sys.argv[1:5]
card = {"id": cid, "title": "UX e2e card", "titleProvisional": False, "desc": "", "repo": repo,
        "branch": "verify", "worktree": wt, "agentId": "claude-code",
        "model": {"id": "claude-opus-4-8", "displayName": "Opus 4.8", "family": "claude"},
        "startIn": "impl", "column": "impl", "order": 0, "status": "waiting", "ctxPct": 0,
        "priorSessionIds": [], "initialPrompt": "t", "archived": False,
        "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z"}
json.dump([card], open(tasks, "w"), indent=2)
PY

# Seed config.json so the isolated daemon ALLOWLISTS the throwaway repo — without it, an RPC `spawn`
# throws (repo not under any allowed root) and the UC replay can't create cards. reposRoot=$ROOT makes
# $ROOT/repo a valid repo; worktrees land under $ROOT/worktrees. defaultAgentId stays claude-code (the
# fake-agent `claude` on PATH). All non-optional Config keys are present so it decodes (else the daemon
# silently falls back to HOME-rooted defaults with an empty allowlist).
python3 - "$DATA/config.json" "$ROOT" <<'PY'
import json, sys
cfg_path, root = sys.argv[1:3]
cfg = {"reposRoot": root, "worktreesRoot": root + "/worktrees", "defaultAgentId": "claude-code",
       "allowlist": [root], "maxConcurrentRevivals": 4, "revivalGraceSeconds": 15,
       "statusLineMode": "orchestraDefault"}
json.dump(cfg, open(cfg_path, "w"), indent=2)
PY

# --- 3. spawn the daemon DIRECTLY under the isolated $HOME (never launchctl) ---
echo "▶ starting isolated daemon (direct spawn, not launchctl)…"
HOME="$ISO_HOME" ORCHESTRA_TMUX_SOCKET="$ISO_TMUX_SOCKET" PATH="$RUN_PATH" \
  "$DAEMON" > "$ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!   # captured so cleanup() reaps ONLY this run's daemon (no global pkill)
disown "$DAEMON_PID" 2>/dev/null || true   # silence job-control "Terminated" notices at teardown
for _ in $(seq 1 30); do grep -q "listening" "$ROOT/daemon.log" 2>/dev/null && break; sleep 0.3; done
grep -q "listening" "$ROOT/daemon.log" || { cat "$ROOT/daemon.log" >&2; fail "daemon didn't start"; }
grep -q "listening at $SOCK" "$ROOT/daemon.log" \
  || fail "daemon bound a non-isolated socket; log: $(grep listening "$ROOT/daemon.log" || true)"
[[ -S "$SOCK" ]] || fail "isolated socket $SOCK not present"
echo "  ✓ daemon isolated at $SOCK (pid $DAEMON_PID)"

# --- GUI cap: bound how many app windows fight the single window server at once ---
echo "▶ waiting for a GUI slot (max $GUI_SLOTS concurrent)…"
acquire_gui_slot
echo "  ✓ acquired GUI slot ${GUI_SLOT_HELD##*/}"

# --- 4. launch the app against the SAME isolated $HOME → it connects to the isolated daemon ---
echo "▶ launching app against the isolated daemon…"
HOME="$ISO_HOME" ORCHESTRA_TMUX_SOCKET="$ISO_TMUX_SOCKET" PATH="$RUN_PATH" "$BIN" >/dev/null 2>&1 &
APP_PID=$!
disown "$APP_PID" 2>/dev/null || true   # silence job-control "Terminated" notices at teardown

# Match the DEMO app's window by its OWNER PID — never by name: the user's LIVE Orchestra app
# shares the name "Orchestra", so a name-only match would grab (and screenshot) the live window.
window_id() {
  ORCH_APP_PID="$APP_PID" /usr/bin/swift - <<'SWIFT'
import CoreGraphics
import Foundation
let want = Int(ProcessInfo.processInfo.environment["ORCH_APP_PID"] ?? "") ?? -1
let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in infos {
    guard (w[kCGWindowOwnerPID as String] as? Int) == want else { continue }
    if let n = w[kCGWindowNumber as String] as? Int,
       let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Height"] ?? 0) > 200 {
        print(n); break
    }
}
SWIFT
}
wid=""
for _ in $(seq 1 50); do sleep 0.4; wid="$(window_id || true)"; [[ -n "$wid" ]] && break; done
[[ -n "$wid" ]] || fail "app window never appeared"

# --- AeroSpace (or any tiling WM via its CLI): FLOAT the demo window so it isn't folded into the
#     user's live workspace — which would squish the live app and yield a narrow 1/2- or 1/3-width
#     screenshot. Match strictly by APP_PID so we ONLY ever touch the demo window, never the live
#     "Orchestra" app (same app-id/title). No-op if aerospace isn't installed or its server is down.
if command -v aerospace >/dev/null 2>&1 && aerospace list-windows --all >/dev/null 2>&1; then
  awid=""
  for _ in $(seq 1 10); do   # the brand-new window may take a moment to register with the WM
    awid="$(aerospace list-windows --all --format '%{window-id}|%{app-pid}' 2>/dev/null \
              | awk -F'|' -v p="$APP_PID" '{a=$1;b=$2;gsub(/[^0-9]/,"",a);gsub(/[^0-9]/,"",b)} b==p{print a;exit}')"
    [[ -n "$awid" ]] && break
    sleep 0.3
  done
  if [[ -n "$awid" ]]; then
    aerospace layout --window-id "$awid" floating >/dev/null 2>&1 || true
    echo "  ✓ floated demo window in AeroSpace (id $awid) — off the live tiling, full-size capture"
    sleep 0.4   # let the float settle before capture
  fi
fi

# --- 5. PROVE isolation: the app can ONLY reach the isolated daemon, and it did connect ---
# (a) By construction: the app's $HOME is the isolated one, so Config.socketPath can only ever
#     resolve to the isolated socket — reaching the live daemon is impossible.
ps eww "$APP_PID" 2>/dev/null | tr ' ' '\n' | grep -qx "HOME=$ISO_HOME" \
  || fail "app \$HOME is not the isolated home — cannot guarantee isolation"
# (b) The app actually connected. macOS attributes an accepted UDS endpoint to the LISTENER, so a
#     connected client is a SECOND daemon-held fd on the socket path (fd 3u listen + fd 4u accept).
#     1 endpoint = nobody connected (onboarding); 2+ = the app is subscribed to the isolated daemon.
connected=0; n=0
for _ in $(seq 1 30); do
  n="$(lsof -- "$SOCK" 2>/dev/null | grep -c 'orchestrad\.sock' || true)"
  [[ "${n:-0}" -ge 2 ]] && { connected=1; break; }
  sleep 0.5
done
[[ "$connected" == 1 ]] || fail "app never connected — only the listener holds $SOCK (still on onboarding?)"
echo "  ✓ app connected to the ISOLATED daemon (HOME=$ISO_HOME; $n socket endpoints)"

# (c) Daemon-side proof: the isolated daemon resolves our seeded card (board is daemon-backed).
if ORCH_SOCK="$SOCK" python3 "$REPO_ROOT/scripts/orch-rpc.py" inspect '{"ref":"aaaaaa"}' 2>/dev/null \
     | grep -q "orchestra-aaaaaaaa"; then
  echo "  ✓ isolated daemon serves the seeded card (not a mock)"
fi

# --- 5.5 UC1–UC8 replay over the isolated daemon (RPC-driven; NO synthetic input) ---
# Drives the same Commands the board/CLI actions call (D3), asserting daemon STATE — not screenshots.
# Advisory per O6: a UC miss logs ⚠ but does NOT fail the run (the merge gate is unit tests + typecheck);
# a hard RPC/transport error would still surface in the daemon log. USE_REAL_CLAUDE stays unset, so all
# spawns launch the fake-agent (no billing).
rpc() { ORCH_SOCK="$SOCK" python3 "$REPO_ROOT/scripts/orch-rpc.py" "$@"; }
uc_ok()   { echo "  ✓ $1"; }
uc_warn() { echo "  ⚠ $1 (advisory)"; }
jget() { python3 -c 'import sys,json;print(json.load(sys.stdin).get(sys.argv[1],""))' "$1" 2>/dev/null; }
REPO="$ROOT/repo"

echo "▶ UC1–UC8 replay (fake-agent on PATH; USE_REAL_CLAUDE unset)"

# The whole UC replay is ADVISORY (O6): disable `set -e` inside it so no single RPC miss can abort the
# run before the (documented-advisory) screenshot step. Re-enabled right after.
set +e

# UC4/UC5 · Fork / handoff→new — spawn --seed, assert the seed rode into the new card (its ref echoes).
FORK="$(rpc spawn "{\"prompt\":\"fork task\",\"repo\":\"$REPO\",\"branch\":\"fork-1\",\"seed\":\"PARENT-SLICE\"}")"
echo "$FORK" | grep -q "PARENT-SLICE" && uc_ok "UC4/UC5 fork (spawn --seed)" || uc_warn "UC4/UC5 fork seed"

# UC6 · Fan-out — batch-spawn N, assert the cards were actually created (their branches echo back;
# `spawned:[]` on an allowlist miss would NOT contain the branch, so this can't false-positive).
FAN="$(rpc batch-spawn "{\"tasks\":[
  {\"prompt\":\"fan A\",\"repo\":\"$REPO\",\"branch\":\"fan-a\"},
  {\"prompt\":\"fan B\",\"repo\":\"$REPO\",\"branch\":\"fan-b\"}]}")"
echo "$FAN" | grep -q 'fan-a' && uc_ok "UC6 fan-out (batch-spawn N)" || uc_warn "UC6 fan-out"

# UC7 · Send / queue — enqueue to the seeded card's durable inbox (F3).
rpc send "{\"ref\":\"aaaaaa\",\"message\":\"queued via UX-e2e\"}" >/dev/null 2>&1 \
  && uc_ok "UC7 send (inbox enqueue)" || uc_warn "UC7 send"

# UC3 · Handoff → clean context (same card) — resume-in-card seeded (F1).
rpc handoff "{\"ref\":\"aaaaaa\",\"context\":\"handoff summary\"}" >/dev/null 2>&1 \
  && uc_ok "UC3 handoff (resume-in-card)" || uc_warn "UC3 handoff"

# UC1/UC2 · parallel forks + reactive DAG — spawn a child, conclude it (archive = settled terminal),
# assert `wait` returns the conclusion (merge-watch off REAL card state, F2).
CHILD="$(rpc spawn "{\"prompt\":\"child\",\"repo\":\"$REPO\",\"branch\":\"child-1\"}" | jget id)"
if [ -n "$CHILD" ]; then
  rpc archive "{\"ref\":\"$CHILD\"}" >/dev/null 2>&1
  rpc wait "{\"refs\":[\"$CHILD\"]}" | grep -q '"kind"' \
    && uc_ok "UC1/UC2 wait→conclude (real card state)" || uc_warn "UC1/UC2 wait"
else uc_warn "UC1/UC2 wait (child spawn)"; fi

# UC8 · cross-agent — spawn a Codex-adapter card with a seed (registry.get("codex"); no `if claude`).
# The `spawn` Command has no agentId param today, so this is advisory: a miss just means UC8's cross-
# agent path is exercised in the unit e2e (e2e_uc8_cross_agent_handoff), not here.
rpc spawn "{\"prompt\":\"codex fork\",\"repo\":\"$REPO\",\"branch\":\"cx-1\",\"agentId\":\"codex\",\"seed\":\"X\"}" \
  >/dev/null 2>&1 && uc_ok "UC8 cross-agent (codex spawn)" || uc_warn "UC8 cross-agent (agentId not on spawn — see unit e2e)"

# SpawnSheet trust indicator — the read-only trustState query, over the isolated daemon.
rpc trustState "{\"path\":\"$REPO\"}" | grep -q '"trusted"' \
  && uc_ok "trustState query (SpawnSheet trust wiring)" || uc_warn "trustState"

set -e   # end of advisory UC replay

# --- 6. screenshot the real UI by window id (never foregrounds / whole-screen) ---
sleep 1.0   # settle board layout
screencapture -x -o -l"$wid" "$OUT/board.png"
echo "  ✓ screenshot → $OUT/board.png  (window $wid)"
release_gui_slot   # free the slot for a sibling as soon as the screenshot is captured

echo "▶ PASS — isolated app+daemon UX e2e; live daemon/app untouched (torn down on exit). [run-id=$RUN_ID]"
