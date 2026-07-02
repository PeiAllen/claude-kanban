#!/bin/bash
# Build + install Orchestra.app, then restart BOTH the running app and the daemon so each picks up
# the freshly-built binaries.
#
# Why a dedicated script: build-app.sh replaces the bundle on disk, but the *running* processes keep
# executing the old code until they restart. Two separate refreshes are needed:
#   • App front-end  — updated by quitting + relaunching Orchestra.app.
#   • Daemon         — the KeepAlive LaunchAgent (com.orchestra.daemon) is pinned to the bundle's
#                      orchestrad. Relaunching the app alone is NOT enough: DaemonLifecycle
#                      .ensureRunning() no-ops whenever a daemon is already answering the socket. So
#                      we stop the old daemon first; the relaunched app then reinstalls the plist
#                      (pinned to the new orchestrad) and bootstraps a fresh daemon.
#
# Agent terminals (the 'orchestra' tmux server) are LEFT RUNNING — this is a code refresh, not a
# state reset. The daemon re-attaches to existing sessions on restart. For a full teardown use
# scripts/reset-state.sh instead.
#
# Usage: scripts/build-and-launch-app.sh [--debug] [-- <extra xcodebuild args>]
#   --debug   build the Debug configuration (passed through to build-app.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="com.orchestra.daemon"
APP_ID="com.orchestra.app"
APP_PATH="/Applications/Orchestra.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
uid="$(id -u)"

# --run is meaningless here (we manage the relaunch ourselves) — drop it so build-app doesn't open
# the app before we've restarted the daemon.
BUILD_ARGS=()
for a in "$@"; do
  [[ "$a" == "--run" ]] && continue
  BUILD_ARGS+=("$a")
done

# 1. Build + install the bundle (daemon binaries included, re-signed) into /Applications.
#    (${arr[@]+…} guard: expanding an empty array under `set -u` errors on macOS bash 3.2.)
scripts/build-app.sh ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}

# 2. Quit the running app gracefully so its relaunch loads the new bundle. Fall back to a signal if
#    it doesn't exit promptly.
if pgrep -x Orchestra >/dev/null 2>&1; then
  echo "Quitting Orchestra.app ..."
  osascript -e "tell application id \"$APP_ID\" to quit" 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -x Orchestra >/dev/null 2>&1 || break
    sleep 0.25
  done
  pkill -x Orchestra 2>/dev/null || true
fi

# 3. Restart the daemon on the new binary. bootout removes the stale process from the GUI domain
#    (KeepAlive can't resurrect it), then we bootstrap + enable it again ourselves. We do NOT rely
#    on the app's ensureRunning() to re-bootstrap — in practice it does not fire reliably on relaunch.
#    The plist's ProgramArguments is pinned to the bundle's orchestrad (a stable path), so the fresh
#    bootstrap execs the newly-installed binary.
echo "Restarting daemon ($LABEL) on the new binary ..."
launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
if [[ -f "$PLIST" ]]; then
  launchctl bootstrap "gui/$uid" "$PLIST" 2>/dev/null || true
  launchctl enable "gui/$uid/$LABEL" 2>/dev/null || true
else
  echo "  (no plist at $PLIST — the app will install + bootstrap it on launch)"
fi

# 4. Relaunch the app (also a safety net: its ensureRunning() installs the plist if step 3 had none).
echo "Launching ${APP_PATH} ..."
open "$APP_PATH"

echo "Done. App + daemon restarted on the new build."
