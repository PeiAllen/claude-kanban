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
# Run UNSANDBOXED: builds an app bundle (xcodebuild needs ~/Library), binds a UDS socket,
# writes its data dir, launches a GUI app, and screencaptures by window id.
#
# Usage: scripts/orch-ux-e2e.sh [--no-build] [outdir]
#   default outdir: ./.scratch/ux-e2e
set -euo pipefail
# Force a UTF-8 locale: under C/POSIX, bash folds a trailing multibyte glyph (e.g. `…`) into an
# adjacent $var name, breaking `set -u`. macOS always ships en_US.UTF-8.
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

BUILD=1
[[ "${1:-}" == "--no-build" ]] && { BUILD=0; shift; }
OUT="${1:-./.scratch/ux-e2e}"
mkdir -p "$OUT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# --- isolated instance roots (short /tmp path: UDS socket must stay < 104 chars) ---
ROOT=/tmp/orch-ux-e2e
ISO_HOME="$ROOT/home"
DATA="$ISO_HOME/Library/Application Support/Orchestra"
SOCK="$DATA/orchestrad.sock"
LIVE_SOCK="$HOME/Library/Application Support/Orchestra/orchestrad.sock"
ISO_TMUX_SOCKET="orch-ux-e2e"
CARD_ID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"   # shortId "aaaaaa"
DAEMON="$REPO_ROOT/.build/debug/orchestrad"
# DerivedData under a cwd-relative gitignored dir (NOT $TMPDIR — the sandbox resolves that to a
# different path than an unsandboxed run, so --no-build couldn't find the bundle). No socket here,
# so the 104-char limit that forces $ROOT into /tmp doesn't apply.
DD="$REPO_ROOT/.scratch/orch-ux-e2e-dd"
if [ "${USE_REAL_CLAUDE:-0}" = "1" ]; then RUN_PATH="$PATH"; else RUN_PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"; fi

APP_PID=""
cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
  pkill -f "$DAEMON" 2>/dev/null || true          # .build/debug path only — never the installed daemon
  tmux -L "$ISO_TMUX_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

fail() { echo "  ✗ $*" >&2; exit 1; }

# --- 0. safety: never point at the live socket ---
[[ "$SOCK" == "$LIVE_SOCK" ]] && fail "isolated socket == live socket — aborting"

# --- 1. build daemon (debug) + app (Debug) ---
if [[ "$BUILD" == 1 ]]; then
  echo "▶ building daemon (debug) + app (Debug)…"
  swift build --package-path "$REPO_ROOT" --product orchestrad >&2
  xcodegen generate --spec App/project.yml --project App >/dev/null
  xcodebuild -project App/Orchestra.xcodeproj -scheme Orchestra -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DD" build >/dev/null
fi
[[ -x "$DAEMON" ]] || fail "daemon not built at $DAEMON (run without --no-build)"
APP="$(/usr/bin/find "$DD/Build/Products/Debug" -maxdepth 1 -name 'Orchestra.app' | head -1)"
BIN="$APP/Contents/MacOS/Orchestra"
[[ -x "$BIN" ]] || fail "app binary not found at $BIN (run without --no-build)"

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
for _ in $(seq 1 30); do grep -q "listening" "$ROOT/daemon.log" 2>/dev/null && break; sleep 0.3; done
grep -q "listening" "$ROOT/daemon.log" || { cat "$ROOT/daemon.log" >&2; fail "daemon didn't start"; }
grep -q "listening at $SOCK" "$ROOT/daemon.log" \
  || fail "daemon bound a non-isolated socket; log: $(grep listening "$ROOT/daemon.log" || true)"
[[ -S "$SOCK" ]] || fail "isolated socket $SOCK not present"
echo "  ✓ daemon isolated at $SOCK"

# --- 4. launch the app against the SAME isolated $HOME → it connects to the isolated daemon ---
echo "▶ launching app against the isolated daemon…"
HOME="$ISO_HOME" ORCHESTRA_TMUX_SOCKET="$ISO_TMUX_SOCKET" PATH="$RUN_PATH" "$BIN" >/dev/null 2>&1 &
APP_PID=$!

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

echo "▶ PASS — isolated app+daemon UX e2e; live daemon/app untouched (torn down on exit)."
