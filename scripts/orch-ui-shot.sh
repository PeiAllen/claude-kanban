#!/bin/bash
# Headless visual-check harness for the Orchestra app's inspector — a TOOL for looking at UI you just
# changed, not a regression suite (see "the shot list" below).
#
# Builds a Debug app bundle to a throwaway DerivedData dir, then launches it with an ISOLATED HOME +
# an ISOLATED tmux socket (ORCHESTRA_TMUX_SOCKET) and one of the DEBUG `ORCH_SHOW=…` hooks (a mock
# card — no daemon, so the live app/daemon are never touched). The isolated tmux socket matters: the
# app's terminal panes attach via `tmux -L <socket>`, so without the override a mock card would spawn
# orphan `<uuid>__agent`/`__shell-N` view sessions on the user's LIVE `-L orchestra` server. Pointing
# it at a throwaway socket keeps that litter on a server we kill on teardown. Each launch is
# screenshotted by window id (never foregrounds the user's screen) and then killed.
#
# The agent/shell terminal panes render empty (a mock card has no tmux behind it) — only the chrome is
# ever visible here. Run UNSANDBOXED (xcodebuild needs ~/Library).
#
# WHAT THE ISOLATED $HOME DOES *NOT* ISOLATE: preferences. `@AppStorage`/NSUserDefaults reads go
# through cfprefsd, which is keyed per-USER, not per-HOME — so these shots render at whatever
# `inspectorWidth` (etc.) the human has dragged their real app to, NEVER the shipped default. A
# layout bug that only appears at the default width is invisible here and WILL pass this harness.
# To test an exact width, pass it through the NSUserDefaults *argument* domain, which outranks the
# stored value without mutating the user's prefs:
#     "$BIN" -inspectorWidth 392        # the shipped default (App/OrchestraApp.swift)
#     "$BIN" -inspectorWidth 320        # the drag minimum (InspectorResizer.resolve)
# and A/B against a mock WITHOUT the element under test, so overflow is attributable. This is how
# the inspector diffstat was caught clipping the close button at 392 after passing these shots.
#
# Usage: scripts/orch-ui-shot.sh [--no-build] [--only <glob>] [outdir]
#   --no-build     reuse the last build — pass it whenever no app source changed since the last run
#   --only <glob>  shoot only the shots whose name matches (a shell glob, quoted):
#                      scripts/orch-ui-shot.sh --no-build --only '1[1-9]-*'
#                      scripts/orch-ui-shot.sh --only '*-tree-*'
#   default outdir: ./.scratch/ui-shots
#
# THE SHOT LIST AT THE BOTTOM IS A MENU, NOT A SUITE. Each `shoot` line is an example invocation some
# past UI PR appended and left behind — the shell strip, the focus rings, the phone-takeover
# placeholder, the diffstat, the tree badge. Nothing diffs the PNGs against a baseline, nothing
# asserts, and they land in gitignored `.scratch/`; a human (or the agent that made the change) looks
# at them. Running the whole list proves nothing about the shots your change can't reach.
#
# So: **run only the shots your change affects, with `--only`, and append your own** for whatever you
# just built. Every shot is a full launch/screenshot/kill of the app — the mock state is injected at
# process start, so a variant cannot be shot without relaunching — which makes a full pass ~19 app
# windows flashing up and dying on the human's screen, for a couple of minutes, every time. The
# per-change subset costs seconds and nothing visible.
#
# Whether an existing shot still renders correctly is worth knowing when you touched what it shows —
# then shoot it. `git log -p -- scripts/orch-ui-shot.sh` tells you which PR each line came from if you
# need to know what one was meant to demonstrate.
set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/wm-float.sh"

BUILD=1
ONLY=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    --only)     ONLY="${2:-}"; shift 2 ;;
    *)          echo "error: unknown option '$1'" >&2; exit 1 ;;
  esac
done
OUT="${1:-./.scratch/ui-shots}"
mkdir -p "$OUT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Every piece of throwaway state is keyed to THIS checkout. `$TMPDIR` is per-user, not per-worktree,
# so two cards running this harness at once shared one DerivedData dir, one isolated $HOME, one tmux
# socket, and one binary path — and `pkill -f "$BIN"` plus `rm -rf "$ISO_HOME"` in cleanup are then
# aimed at each other. Measured failure: a sibling worktree's rebuild landed in the shared DD between
# a build and a capture, so the shots showed the OTHER branch's app; its pkill also killed this run's
# window mid-capture. The suffix makes concurrent cards invisible to one another.
WT="$(printf '%s' "$PWD" | /usr/bin/shasum | cut -c1-8)"
DD="${TMPDIR:-/tmp}/orch-ui-shot-dd-$WT"
ISO_HOME="${TMPDIR:-/tmp}/orch-ui-shot-home-$WT"
# Throwaway tmux server for the mock cards' terminal panes — never the live `-L orchestra` server.
ISO_TMUX_SOCKET="orch-ui-shot-$WT"
export ORCHESTRA_TMUX_SOCKET="$ISO_TMUX_SOCKET"
cleanup() { pkill -f "${BIN:-__none__}" 2>/dev/null || true; tmux -L "$ISO_TMUX_SOCKET" kill-server 2>/dev/null || true; rm -rf "$ISO_HOME"; }
trap cleanup EXIT

if [[ "$BUILD" == 1 ]]; then
  echo "▶ regenerating xcodeproj + building Debug…"
  xcodegen generate --spec App/project.yml --project App >/dev/null
  scripts/lib/with-lock.sh build -- xcodebuild -project App/Orchestra.xcodeproj -scheme Orchestra -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DD" build >/dev/null
fi

APP="$(/usr/bin/find "$DD/Build/Products/Debug" -maxdepth 1 -name 'Orchestra.app' | head -1)"
BIN="$APP/Contents/MacOS/Orchestra"
[[ -x "$BIN" ]] || { echo "error: built binary not found at $BIN (run without --no-build)"; exit 1; }

# Fresh isolated HOME for everything that IS keyed to $HOME (the app's own state dir, caches).
#
# It does NOT isolate preferences, and nothing can: cfprefsd resolves a domain per-UID, so an
# `@AppStorage` write from this app lands in the human's real `com.orchestra.app` no matter what
# $HOME says. Measured: a run of this script left `shellPanelHeight = 420` — the constant the
# "4-panel-tall" shot used — in the live domain, next to fractional drag-written neighbours.
# So the harness never WRITES a preference. Anything it needs to control goes through the
# NSUserDefaults **argument domain** (`"$BIN" -someKey value`, the args after `--` in `shoot`),
# which outranks the persistent domain for the launched process only and is never stored.
rm -rf "$ISO_HOME"; mkdir -p "$ISO_HOME"

# Find the launched app's window id (tiny Swift one-shot via CGWindowList) — capture by id so we
# never foreground the app or grab the whole screen. Filter by the spawned process's PID, NOT the
# owner name: when the user's LIVE Orchestra app is already running, an owner-name match would grab
# their real window instead of our throwaway isolated instance. (Same "filter by PID not name"
# convention the keyboard-driving harness uses.)
window_id() {
  /usr/bin/swift - "$1" <<'SWIFT'
import CoreGraphics
import Foundation
let want = Int(CommandLine.arguments.dropFirst().first ?? "") ?? -1
let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in infos where (w[kCGWindowOwnerPID as String] as? Int) == want {
    if let n = w[kCGWindowNumber as String] as? Int,
       let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Height"] ?? 0) > 200 {
        print(n); break
    }
}
SWIFT
}

shoot() { # name  env VAR=VAL…  [-- binary args…]
  local name="$1"; shift
  # Unquoted on the right of `!=` so it is matched as a GLOB, not compared as a literal.
  [[ -n "$ONLY" && "$name" != $ONLY ]] && return 0
  # Everything before `--` launches the process (the `env VAR=VAL` prefix); everything after it is
  # passed to the binary, i.e. the NSUserDefaults argument domain — see the isolation note above.
  local launch=() args=() seen=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then seen=1; continue; fi
    if [[ "$seen" == 1 ]]; then args+=("$a"); else launch+=("$a"); fi
  done
  pkill -f "$BIN" 2>/dev/null || true
  sleep 0.5
  # `${arr[@]+…}` guards the empty-array expansion, which is an unbound-variable error under
  # `set -u` in the bash 3.2 that ships with macOS.
  HOME="$ISO_HOME" "${launch[@]}" "$BIN" ${args[@]+"${args[@]}"} >/dev/null 2>&1 &
  local pid=$!
  # Give SwiftUI time to lay out + the DEBUG hook to inject the mock card.
  local wid=""
  for _ in $(seq 1 40); do
    sleep 0.4
    wid="$(window_id "$pid" || true)"
    [[ -n "$wid" ]] && break
  done
  if [[ -z "$wid" ]]; then echo "  ✗ $name: no window found"; kill "$pid" 2>/dev/null || true; return 1; fi
  # Float it off the user's tiling WM, or the capture is a squished sliver (see lib/wm-float.sh).
  float_window_for_pid "$pid"
  sleep 1.0   # settle terminal/chrome layout
  screencapture -x -o -l"$wid" "$OUT/$name.png"
  echo "  ✓ $OUT/$name.png  (window $wid)"
  kill "$pid" 2>/dev/null || true
  sleep 0.3
}

# ── The menu. Each block was appended by the PR that built the thing it shows; see the header. Pick
#    yours with `--only`, add yours at the end, leave the rest alone.
echo "▶ capturing inspector states…"
# The shell strip: the "New terminal" button swaps to the tab ribbon, and the panel is resizable.
shoot "1-no-shells"     env ORCH_SHOW=shells ORCH_SHELLS_N=0
shoot "2-shells-ribbon" env ORCH_SHOW=shells ORCH_SHELLS_N=2
shoot "3-panel-short"   env ORCH_SHOW=shells ORCH_SHELLS_N=2 -- -shellPanelHeight 110
shoot "4-panel-tall"    env ORCH_SHOW=shells ORCH_SHELLS_N=2 -- -shellPanelHeight 420
# Inspector focus ring: board zone (plain hairline) vs terminal zone (accent ring + glow).
shoot "5-focus-board"   env ORCH_SHOW=shells ORCH_SHELLS_N=0
shoot "6-focus-terminal" env ORCH_SHOW=shells ORCH_SHELLS_N=0 ORCH_FOCUS=terminal
# Region-scoped focus ring: with shells open the accent ring hugs the agent block (top) vs the
# shell block (bottom), depending on which pane owns the keyboard.
shoot "7-focus-shell"        env ORCH_SHOW=shells ORCH_SHELLS_N=2 ORCH_FOCUS=shell
shoot "8-focus-agent-shells" env ORCH_SHOW=shells ORCH_SHELLS_N=2 ORCH_FOCUS=terminal

# PR D5: a phone owns the card's agent terminal → the desktop unmounts the live terminal and shows the
# "Taken over by phone" placeholder. Fresh owner ⇒ Retake Terminal; stale owner ⇒ Force Retake.
shoot "9-takeover-placeholder"       env ORCH_SHOW=takeover
shoot "10-takeover-placeholder-stale" env ORCH_SHOW=takeover ORCH_STALE=1

# Tree state in the shared inspector header (`ORCH_TREE`): every badge the board card can show, plus
# the Diff tab — the badge lives in the shared header precisely so it survives that swap. `in-sync`
# is here because it must render NOTHING, and an empty slot is only worth looking at next to the
# filled ones. Shot 16 shows the badge surviving the swap to the Diff tab.
shoot "11-tree-stale"        env ORCH_SHOW=shells ORCH_SHELLS_N=0 ORCH_TREE=stale ORCH_BEHIND=3
shoot "12-tree-restack"      env ORCH_SHOW=shells ORCH_SHELLS_N=0 ORCH_TREE=restack
shoot "13-tree-merge-req"    env ORCH_SHOW=shells ORCH_SHELLS_N=0 ORCH_TREE=merge-requested
shoot "14-tree-stalled"      env ORCH_SHOW=shells ORCH_SHELLS_N=0 ORCH_TREE=stalled
shoot "15-tree-in-sync"      env ORCH_SHOW=shells ORCH_SHELLS_N=0 ORCH_TREE=in-sync
shoot "16-tree-stale-diff-tab" env ORCH_SHOW=shells ORCH_SHELLS_N=0 ORCH_TREE=stale ORCH_INSPECTOR=diff
# The header row PINNED to the widths that decide its `ViewThatFits` rung, because every shot above
# renders at whatever width the human last dragged this app to (see the preferences note at the top)
# and so can't tell you which rung real users get. The two 392pt shots are the interesting pair: at the
# shipped default the shared chip holds the diffstat AND a one-digit badge, but a two-digit `↓12` is
# ~15pt more than the row's remaining slack and drops the ladder a rung, trading the diffstat away.
# That is the intended give — see the chip comment in InspectorView — and 17-vs-18 is the evidence.
shoot "17-tree-392"          env ORCH_SHOW=shells ORCH_SHELLS_N=0 ORCH_TREE=stale ORCH_BEHIND=3 -- -inspectorWidth 392
shoot "18-tree-392-2digit"   env ORCH_SHOW=shells ORCH_SHELLS_N=0 ORCH_TREE=stale ORCH_BEHIND=12 -- -inspectorWidth 392
shoot "19-tree-320"          env ORCH_SHOW=shells ORCH_SHELLS_N=0 ORCH_TREE=stale ORCH_BEHIND=12 -- -inspectorWidth 320

echo "▶ done → $OUT  (isolated tmux server '$ISO_TMUX_SOCKET' torn down on exit)"
