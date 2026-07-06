#!/bin/bash
# T1 live SSH-PTY attach verification (fully isolated — no user system changes).
#
# Proves the iOS SwiftTerm terminal attaches over an in-process SSH PTY to a live tmux window and
# renders it, and that reconnect reuses the SAME tmux view session (idempotent). Uses a throwaway
# non-root sshd on :12222 and a throwaway tmux server (-L t1term); never touches the user's Remote
# Login or live board. Screenshots to .scratch/.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

ROOT="$(pwd)"
D="$ROOT/.scratch/t1sshd"
SHOTS="$ROOT/.scratch"
SOCK_TMUX="t1term"
BASE="orchestra-t1demo"
WIN="agent"
PORT=12222
BUNDLE=com.orchestra.ios
USER_NAME="$(id -un)"

cleanup() {
  echo "=== cleanup ==="
  [ -f "$D/sshd.pid" ] && kill "$(cat "$D/sshd.pid")" 2>/dev/null
  pkill -f "sshd -f $D" 2>/dev/null
  tmux -L "$SOCK_TMUX" kill-server 2>/dev/null
}
trap cleanup EXIT

# 1. Build Debug app ad-hoc SIGNED (so the Keychain entitlement from OrchestraiOS.entitlements is
# applied — an unsigned build has no application-identifier and SecItem returns -34018). The compile
# gate (typecheck-ios) stays unsigned; this harness signs to exercise the real Keychain path.
echo "=== build (Debug, ad-hoc signed) ==="
xcodegen generate --spec App-iOS/project.yml --project App-iOS >/dev/null
xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- \
  build > "$SHOTS/ios-build.log" 2>&1 || { echo "BUILD FAILED"; tail -20 "$SHOTS/ios-build.log"; exit 1; }
APP="$(xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {d=$2} / FULL_PRODUCT_NAME / {n=$2} END {print d "/" n}')"
echo "APP=$APP"; [ -d "$APP" ] || { echo "no .app"; exit 1; }
echo "entitlements: $(codesign -d --entitlements :- "$APP" 2>/dev/null | tr -d '\0' | grep -o 'keychain-access-groups' | head -1)"

# 2. Boot a Simulator, install.
UDID="$(xcrun simctl list devices available | grep -m1 '    iPhone ' | grep -oE '[0-9A-Fa-f-]{36}' | head -1)"
echo "UDID=$UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

# 3. Launch pass 1 → generate Keychain key + export pubkey to the app container.
echo "=== pass 1: generate + export device pubkey ==="
# Also clear any stale TOFU host-key pin for 127.0.0.1 (pins are keyed by host, so a prior loopback-sshd
# harness — e.g. the board-over-SSH e2e on a different port — would otherwise trip a hostKeyChanged
# refusal here). No attach races this launch, so the reset lands before pass 2 connects.
SIMCTL_CHILD_ORCH_RESET_HOSTKEY_PINS="1" \
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 6
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null)"
PUBKEY_FILE="$CONTAINER/Documents/orchestra-ios-pubkey.txt"
for i in $(seq 1 10); do [ -s "$PUBKEY_FILE" ] && break; sleep 1; done
[ -s "$PUBKEY_FILE" ] || { echo "no device pubkey exported ($PUBKEY_FILE)"; exit 1; }
echo "device pubkey: $(cat "$PUBKEY_FILE")"

# 4. Throwaway sshd trusting the device key.
echo "=== start throwaway sshd :$PORT ==="
rm -rf "$D"; mkdir -p "$D"; D="$(cd "$D" && pwd)"
ssh-keygen -q -t ed25519 -f "$D/hostkey" -N ""
cat "$PUBKEY_FILE" > "$D/authorized_keys"; chmod 600 "$D/authorized_keys" "$D/hostkey"
cat > "$D/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $D/hostkey
PidFile $D/sshd.pid
AuthorizedKeysFile $D/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PubkeyAuthentication yes
AcceptEnv LANG LC_*
LogLevel VERBOSE
EOF
/usr/sbin/sshd -f "$D/sshd_config" -E "$D/sshd.log"
sleep 1
pgrep -fl "sshd -f $D" >/dev/null || { echo "sshd failed"; tail "$D/sshd.log"; exit 1; }

# 5. Live tmux window to attach to (banner + a live TUI so the render is unmistakable).
echo "=== start tmux $BASE:$WIN on -L $SOCK_TMUX ==="
tmux -L "$SOCK_TMUX" kill-server 2>/dev/null
tmux -L "$SOCK_TMUX" new-session -d -s "$BASE" -n "$WIN" -x 80 -y 24
tmux -L "$SOCK_TMUX" send-keys -t "$BASE:$WIN" \
  "clear; printf '=== T1 LIVE SSH-PTY ATTACH ===\\niOS SwiftTerm over swift-nio-ssh -> tmux -L $SOCK_TMUX\\n\\n'; TERM=xterm-256color top" Enter
sleep 1

launch_attach() {
  local label="$1"
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  SIMCTL_CHILD_ORCH_SSH_TARGET="$USER_NAME@127.0.0.1:$PORT" \
  SIMCTL_CHILD_ORCH_SSH_ALLOW_LOOPBACK="1" \
  SIMCTL_CHILD_ORCH_RESET_HOSTKEY_PINS="1" \
  SIMCTL_CHILD_ORCH_T1_SOCKET="$SOCK_TMUX" \
  SIMCTL_CHILD_ORCH_T1_SESSION="$BASE" \
  SIMCTL_CHILD_ORCH_T1_WINDOW="$WIN" \
  SIMCTL_CHILD_ORCH_T1_AUTOATTACH="1" \
    xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  sleep 6
  xcrun simctl io "$UDID" screenshot "$SHOTS/$label" >/dev/null 2>&1
  echo "screenshot: $SHOTS/$label"
}

# 6. Attach #1.
echo "=== pass 2: live attach #1 ==="
launch_attach "t1-live-attach-1.png"
echo "view sessions after attach #1:"; tmux -L "$SOCK_TMUX" list-sessions 2>/dev/null

# 7. Attach #2 (reconnect) — must REUSE the same view session (idempotent), not spawn a second.
echo "=== pass 3: reconnect (attach #2) ==="
launch_attach "t1-live-attach-2.png"
echo "view sessions after attach #2:"; tmux -L "$SOCK_TMUX" list-sessions 2>/dev/null
VIEWS="$(tmux -L "$SOCK_TMUX" list-sessions 2>/dev/null | grep -c "${BASE}__${WIN}")"
echo "grouped view-session count for ${BASE}__${WIN}: $VIEWS (expect 1 = idempotent)"

echo "=== sshd auth log ==="; grep -iE "Accepted|Postponed|error|fatal" "$D/sshd.log" | tail -10
echo "DONE"
