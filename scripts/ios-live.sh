#!/bin/bash
# Launch a VISIBLE, interactive Orchestra iOS app in the Simulator, wired to your LIVE Mac daemon.
# Unlike build-ios-app.sh --run (headless + screenshot), this opens the Simulator window so you can
# tap around a live board. Read-only render off the daemon's Unix socket — the same one the Mac app uses.
#
# Usage: scripts/ios-live.sh [--release]   (Debug by default for a faster build)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="Debug"
[[ "${1:-}" == "--release" ]] && CONFIG="Release"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)"; exit 1; }

DEV_SOCKET="${ORCH_DEV_SOCKET:-$HOME/Library/Application Support/Orchestra/orchestrad.sock}"
[[ -S "$DEV_SOCKET" ]] || echo "warning: daemon socket not found at $DEV_SOCKET — is the Mac app/daemon running?"

echo "== generating project =="
xcodegen generate --spec App-iOS/project.yml --project App-iOS

echo "== building ($CONFIG) =="
"$(dirname "$0")/lib/with-lock.sh" build -- xcodebuild \
  -project App-iOS/OrchestraiOS.xcodeproj \
  -scheme OrchestraiOS \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null
echo "build OK"

# Pick a Simulator: prefer an already-booted iPhone, else the named/first available iPhone (then boot it).
UDID="$(xcrun simctl list devices booted | grep -m1 '    iPhone ' | grep -oE '[0-9A-Fa-f-]{36}' | head -1 || true)"
if [[ -z "$UDID" ]]; then
  if [[ -n "${ORCH_SIM_DEVICE:-}" ]]; then
    UDID="$(xcrun simctl list devices available | grep -m1 "    ${ORCH_SIM_DEVICE} (" | grep -oE '[0-9A-Fa-f-]{36}' | head -1)"
  else
    UDID="$(xcrun simctl list devices available | grep -m1 '    iPhone ' | grep -oE '[0-9A-Fa-f-]{36}' | head -1)"
  fi
  [[ -n "$UDID" ]] || { echo "error: no available iPhone Simulator (set ORCH_SIM_DEVICE)"; exit 1; }
  xcrun simctl boot "$UDID" 2>/dev/null || true
fi

open -a Simulator            # show the Simulator window so it's interactive
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

APP="$(xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration "$CONFIG" \
  -destination 'generic/platform=iOS Simulator' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {d=$2} / FULL_PRODUCT_NAME / {n=$2} END {print d "/" n}')"
xcrun simctl install "$UDID" "$APP"
# Env for the launched app MUST use the SIMCTL_CHILD_ prefix (simctl passes trailing args as argv).
SIMCTL_CHILD_ORCH_DEV_SOCKET="$DEV_SOCKET" xcrun simctl launch "$UDID" com.orchestra.ios

echo "Launched live on Simulator $UDID (ORCH_DEV_SOCKET=$DEV_SOCKET). The Simulator window is now interactive."
