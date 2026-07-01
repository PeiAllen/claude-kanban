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
  swift build --package-path "$REPO_ROOT" --product orchestrad >&2
  xcodegen generate --spec App/project.yml --project App >/dev/null
  xcodebuild -project App/Orchestra.xcodeproj -scheme Orchestra -configuration Debug \
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

# --- 6. screenshot the real UI by window id (never foregrounds / whole-screen) ---
sleep 1.0   # settle board layout
screencapture -x -o -l"$wid" "$OUT/board.png"
echo "  ✓ screenshot → $OUT/board.png  (window $wid)"
release_gui_slot   # free the slot for a sibling as soon as the screenshot is captured

echo "▶ PASS — isolated app+daemon UX e2e; live daemon/app untouched (torn down on exit). [run-id=$RUN_ID]"
