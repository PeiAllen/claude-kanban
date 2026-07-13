#!/bin/bash
# Headless visual-check harness for the Orchestra inspector's shell strip.
#
# Builds a Debug app bundle to a throwaway DerivedData dir, then launches it with an ISOLATED HOME +
# an ISOLATED tmux socket (ORCHESTRA_TMUX_SOCKET) and the DEBUG `ORCH_SHOW=shells` hook (a mock
# running card + N shell tabs — no daemon, so the live app/daemon are never touched). The isolated
# tmux socket matters: the app's terminal panes attach via `tmux -L <socket>`, so without the
# override a mock card would spawn orphan `<uuid>__agent`/`__shell-N` view sessions on the user's
# LIVE `-L orchestra` server. Pointing it at a throwaway socket keeps that litter on a server we
# kill on teardown. Each launch is screenshotted by window id (never foregrounds the user's screen)
# and then killed. Produces a set of PNGs that show:
#   1. no shells          → full-width "New terminal" button
#   2. shells open        → tab ribbon (the button is gone; closing the last shell brings it back)
#   3/4. shells, 2 heights → the resizable shell panel at a short vs tall height (resize wiring)
#
# The agent/shell terminal panes render empty (a mock card has no tmux behind it) — only the chrome
# (strip swap + panel height) is under test here. Run UNSANDBOXED (xcodebuild needs ~/Library).
#
# Usage: scripts/orch-ui-shot.sh [--no-build] [outdir]
#   default outdir: ./.scratch/ui-shots
set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/wm-float.sh"

BUILD=1
[[ "${1:-}" == "--no-build" ]] && { BUILD=0; shift; }
OUT="${1:-./.scratch/ui-shots}"
mkdir -p "$OUT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DD="${TMPDIR:-/tmp}/orch-ui-shot-dd"
ISO_HOME="${TMPDIR:-/tmp}/orch-ui-shot-home"
# Throwaway tmux server for the mock cards' terminal panes — never the live `-L orchestra` server.
ISO_TMUX_SOCKET="orch-ui-shot"
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

# Fresh isolated HOME so the app's @AppStorage/onboarding prefs land in a throwaway domain, never
# the user's real ~/Library.
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

shoot() { # name  env...
  local name="$1"; shift
  pkill -f "$BIN" 2>/dev/null || true
  sleep 0.5
  HOME="$ISO_HOME" "$@" "$BIN" >/dev/null 2>&1 &
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

echo "▶ capturing inspector states…"
shoot "1-no-shells"     env ORCH_SHOW=shells ORCH_SHELLS_N=0
shoot "2-shells-ribbon" env ORCH_SHOW=shells ORCH_SHELLS_N=2
shoot "3-panel-short"   env ORCH_SHOW=shells ORCH_SHELLS_N=2 ORCH_SHELL_HEIGHT=110
shoot "4-panel-tall"    env ORCH_SHOW=shells ORCH_SHELLS_N=2 ORCH_SHELL_HEIGHT=420
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

echo "▶ done → $OUT  (isolated tmux server '$ISO_TMUX_SOCKET' torn down on exit)"
