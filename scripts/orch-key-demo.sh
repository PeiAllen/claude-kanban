#!/bin/bash
# Background keyboard-navigation test for the Orchestra app.
#
# Launches an ISOLATED Debug instance seeded with a mock multi-card board (ORCH_SHOW=demo, no daemon,
# isolated HOME + tmux socket), then DRIVES it with synthetic key events posted straight to the
# instance's PID (CGEvent.postToPid — never activates it, so the user's foreground is untouched) and
# screenshots the window after each step. Produces a sequence of PNGs in the out dir. Kills + cleans
# up on exit. Run UNSANDBOXED (xcodebuild + Screen Recording).
#
# Usage: scripts/orch-key-demo.sh [--no-build] [outdir]
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=1
[[ "${1:-}" == "--no-build" ]] && { BUILD=0; shift; }
OUT="${1:-./.scratch/key-demo}"
mkdir -p "$OUT"
rm -f "$OUT"/*.png

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DD="${TMPDIR:-/tmp}/orch-key-dd"
ISO_HOME="${TMPDIR:-/tmp}/orch-key-home"
export ORCHESTRA_TMUX_SOCKET="orch-key-demo"

cleanup() {
  [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null || true
  pkill -f "orch-key-dd/Build/Products/Debug/Orchestra.app" 2>/dev/null || true
  tmux -L "$ORCHESTRA_TMUX_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$ISO_HOME"
}
trap cleanup EXIT

if [[ "$BUILD" == 1 ]]; then
  echo "▶ building Debug…"
  (cd App && xcodegen generate --spec project.yml >/dev/null 2>&1)
  scripts/lib/with-lock.sh build -- xcodebuild -project App/Orchestra.xcodeproj -scheme Orchestra -configuration Debug \
    -derivedDataPath "$DD" build >/tmp/orch-key-build.log 2>&1 \
    || { echo "BUILD FAILED"; tail -30 /tmp/orch-key-build.log; exit 1; }
fi
BIN="$DD/Build/Products/Debug/Orchestra.app/Contents/MacOS/Orchestra"

echo "▶ launching isolated demo instance (background)…"
HOME="$ISO_HOME" ORCH_SHOW=demo "$BIN" >/dev/null 2>&1 &
APP_PID=$!
sleep 4   # let the window come up

WID="$(swift scripts/keydrive.swift windowid "$APP_PID" || true)"
if [[ -z "$WID" ]]; then echo "no window id for pid $APP_PID — abort"; exit 1; fi
echo "▶ window id: $WID   pid: $APP_PID"

step=0
shot() { printf -v n "%02d" "$step"; screencapture -x -o -l"$WID" "$OUT/$n-$1.png"; echo "  · $n-$1"; step=$((step+1)); }
keys() { swift scripts/keydrive.swift keys "$APP_PID" "$@"; sleep 0.4; }

shot initial                                   # first Plan card selected
keys j;            shot j-down
keys j;            shot j-down2
keys l;            shot l-to-impl               # cross to Implementation column
keys S-l;          shot L-carry-review          # carry the card right to Review
keys g r;          shot goto-review             # g r → first Review card
keys f h;          shot hint-h                  # f then label → jump to a card
keys S-';';        shot palette-open            # : (shift-;) opens the command palette
keys esc;          shot palette-closed
keys /;            shot search-open             # / opens the search bar
keys esc;          shot search-closed
keys S-/;          shot help-open               # ? (shift-/) opens the shortcuts overlay
keys esc;          shot help-closed

echo "▶ done — PNGs in $OUT"
ls "$OUT"
