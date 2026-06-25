#!/bin/bash
# Tear down Orchestra's local state: stop the daemon, remove its LaunchAgent, kill the tmux server,
# and delete the daemon data store + the app's UI prefs. By default the git worktrees under
# ~/.orchestra are LEFT ALONE (they can hold uncommitted work) — pass --worktrees to remove them too.
#
# Usage: scripts/reset-state.sh [--worktrees] [-y]
#   --worktrees   also delete ~/.orchestra/worktrees (DESTRUCTIVE — may contain uncommitted work)
#   -y, --yes     skip the confirmation prompt
set -euo pipefail

LABEL="com.orchestra.daemon"
DATA_DIR="$HOME/Library/Application Support/Orchestra"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
WORKTREES="$HOME/.orchestra"
APP_PREFS_DOMAIN="com.orchestra.app"
TMUX_SOCKET="orchestra"

WIPE_WORKTREES=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --worktrees) WIPE_WORKTREES=1 ;;
    -y|--yes)    ASSUME_YES=1 ;;
    *)           echo "error: unknown option '$arg'" >&2; exit 1 ;;
  esac
done

echo "This will remove Orchestra's local state:"
echo "  • stop + unload the LaunchAgent ($LABEL)"
echo "  • kill the '$TMUX_SOCKET' tmux server (agent terminals)"
echo "  • delete $DATA_DIR"
echo "  • clear app prefs ($APP_PREFS_DOMAIN)"
if [[ "$WIPE_WORKTREES" == 1 ]]; then
  echo "  • delete $WORKTREES  ← worktrees, may contain uncommitted work"
else
  echo "  • (keeping worktrees at $WORKTREES — pass --worktrees to remove)"
fi

if [[ "$ASSUME_YES" != 1 ]]; then
  printf 'Continue? [y/N] '
  read -r reply
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] || { echo "Aborted."; exit 0; }
fi

# Unload the LaunchAgent (bootout matches DaemonLifecycle.uninstall) and remove its plist.
uid="$(id -u)"
launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

# Kill the tmux server hosting the agent terminals (socket -L orchestra).
tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true

# Delete the daemon data store (config.json, tasks.json, socket, log, hooks).
rm -rf "$DATA_DIR"

# Clear the app's @AppStorage UI prefs (accent / density / dark mode).
defaults delete "$APP_PREFS_DOMAIN" 2>/dev/null || true

if [[ "$WIPE_WORKTREES" == 1 ]]; then
  rm -rf "$WORKTREES"
fi

echo "Done. Orchestra state reset."
