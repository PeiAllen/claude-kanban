#!/bin/bash
# Copy the cross-compiled Orchestra daemon to a Linux box and set it up as an always-on systemd
# USER service. Run this after scripts/build-linux-daemon.sh.
#
# Usage:
#   scripts/deploy-linux-daemon.sh <user@host> [--remote-dir DIR] [--arch x86_64|aarch64]
#     <user@host>    SSH target of the Linux box (a Tailscale hostname works too)
#     --remote-dir   where to install on the box (default: ~/orchestra)
#     --arch         which dist/linux-<arch> build to ship (default: x86_64)
#
# Prerequisites on the box (not shipped by this script): git, tmux, and the agent CLIs
# (claude / codex). The daemon shells out to them and the agents run on the box.
#
# SSH key auth to <user@host> must already work (this script runs several non-interactive ssh/rsync
# commands). Tailscale hostname or plain host both fine.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=""
REMOTE_DIR=""
ARCH="x86_64"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
    --arch)       ARCH="$2"; shift 2 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    --*)          echo "error: unknown option '$1'" >&2; exit 1 ;;
    *)            TARGET="$1"; shift ;;
  esac
done
[[ -n "$TARGET" ]] || { echo "error: missing <user@host>" >&2; exit 1; }
[[ -n "$REMOTE_DIR" ]] || REMOTE_DIR="orchestra"   # relative to remote $HOME
DIST="dist/linux-$ARCH"
[[ -d "$DIST" ]] || { echo "error: $DIST not found — run scripts/build-linux-daemon.sh --arch $ARCH first" >&2; exit 1; }

echo "Deploying $DIST → $TARGET:~/$REMOTE_DIR"

# 1) Ship the binaries + resource bundle. --rsync-path ensures the dir exists; -z compresses.
ssh "$TARGET" "mkdir -p ~/$REMOTE_DIR"
rsync -az --delete-excluded "$DIST"/ "$TARGET:$REMOTE_DIR/"
ssh "$TARGET" "chmod +x ~/$REMOTE_DIR/orchestrad ~/$REMOTE_DIR/orchestra ~/$REMOTE_DIR/orchestra-mcp"

# 2) Install the systemd user unit + enable linger so it runs on a headless / logged-out box.
#    %h expands to the box's $HOME inside systemd, so the unit stays portable.
ssh "$TARGET" bash -s -- "$REMOTE_DIR" <<'REMOTE'
set -euo pipefail
REMOTE_DIR="$1"
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/orchestra.service <<UNIT
[Unit]
Description=Orchestra daemon (orchestrad)
After=default.target

[Service]
ExecStart=%h/${REMOTE_DIR}/orchestrad
Restart=always
RestartSec=2
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
UNIT

# enable-linger lets the user service run without an active login session (headless work box).
loginctl enable-linger "$USER" 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable --now orchestra.service
sleep 1
systemctl --user --no-pager status orchestra.service | sed -n '1,6p' || true
REMOTE

# 3) Report the socket path to paste into the app's connection settings (Linux XDG data dir).
SOCK="\${XDG_DATA_HOME:-\$HOME/.local/share}/orchestra/orchestrad.sock"
REMOTE_SOCK="$(ssh "$TARGET" "echo $SOCK")"
echo
echo "Done. Daemon running on $TARGET via systemd (--user, restart=always, linger enabled)."
echo
echo "In the app → Settings → Connections, add a remote connection:"
echo "    SSH target:          $TARGET"
echo "    Remote socket path:  $REMOTE_SOCK"
echo "    Remote tmux socket:  orchestra"
echo
echo "Manage the daemon on the box with:  ssh $TARGET systemctl --user {status,restart,stop} orchestra"
