#!/bin/bash
# Float a throwaway demo/test window in a tiling WM, so it isn't folded into the user's live
# workspace. Without this, AeroSpace tiles the instance we just launched alongside whatever the user
# has open: the window comes up a half- or third-width sliver, screenshots capture a squished layout
# (columns collapse, the inspector eats the frame), and the user's real windows get shoved around.
#
# Strictly PID-matched: the demo instance and the user's LIVE app share the app-id and the title
# "Orchestra", so a name match could float — and disturb — the real window. No-op when aerospace
# isn't installed or its server is down.
#
#   source scripts/lib/wm-float.sh
#   float_window_for_pid "$APP_PID"

float_window_for_pid() {
  local pid="$1"
  command -v aerospace >/dev/null 2>&1 || return 0
  aerospace list-windows --all >/dev/null 2>&1 || return 0

  local awid=""
  for _ in $(seq 1 10); do   # a brand-new window takes a moment to register with the WM
    awid="$(aerospace list-windows --all --format '%{window-id}|%{app-pid}' 2>/dev/null \
              | awk -F'|' -v p="$pid" '{a=$1;b=$2;gsub(/[^0-9]/,"",a);gsub(/[^0-9]/,"",b)} b==p{print a;exit}')"
    [[ -n "$awid" ]] && break
    sleep 0.3
  done
  [[ -n "$awid" ]] || return 0

  aerospace layout --window-id "$awid" floating >/dev/null 2>&1 || true
  echo "  ✓ floated window in AeroSpace (id $awid) — off the live tiling, full-size capture"
  sleep 0.4   # let the float settle before any capture
}
