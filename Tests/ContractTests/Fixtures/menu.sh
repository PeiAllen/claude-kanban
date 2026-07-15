#!/usr/bin/env bash
# menu.sh — a tiny arrow-key selector used to assert send-keys Up/Down/Enter semantics against real
# tmux. Reads raw keystrokes; on each arrow clears the pane and redraws only the CURRENT selection as
# SELECTED=<label>; on Enter prints CHOSE=<label> and idles so the pane can still be captured.
#
# NOTE: each draw ends in a newline on purpose — stdout to a pty is line-buffered, so a bare '\r'
# redraw would never flush and the pane would read blank. The ESC[2J/ESC[H clear keeps only the
# current selection visible, so `contains SELECTED=X` still means "X is selected right now".
set -u
labels=(ALPHA BRAVO CHARLIE)
sel=0
draw() { printf '\033[2J\033[HSELECTED=%s\n' "${labels[$sel]}"; }
draw
while true; do
  IFS= read -rsn1 c || continue
  if [ "$c" = $'\x1b' ]; then          # ESC — start of an arrow sequence
    read -rsn2 rest
    case "$rest" in
      '[A'|'OA') [ "$sel" -gt 0 ] && sel=$((sel-1)) ;;   # Up
      '[B'|'OB') [ "$sel" -lt 2 ] && sel=$((sel+1)) ;;   # Down
    esac
  elif [ -z "$c" ]; then               # read strips the trailing newline → empty == Enter
    printf '\033[2J\033[HCHOSE=%s\n' "${labels[$sel]}"
    sleep 30                            # keep the pane alive so the choice can be captured
    exit 0
  fi
  draw
done
