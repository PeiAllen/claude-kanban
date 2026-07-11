#!/bin/bash
# Build (and optionally boot+launch) the Orchestra iOS app for the Simulator.
# Mirrors scripts/build-app.sh; the iOS app needs full Xcode + xcodegen + SwiftTerm.
#
# Usage: scripts/build-ios-app.sh [--run] [--debug] [-- <extra xcodebuild args>]
#   --run     boot a Simulator, install, launch with ORCH_DEV_SOCKET, screenshot to .scratch/
#   --debug   build Debug instead of Release
set -euo pipefail
cd "$(dirname "$0")/.."

RUN=0
CONFIG="Release"
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --run)   RUN=1; shift ;;
    --debug) CONFIG="Debug"; shift ;;
    --)      shift; break ;;
    *)       echo "error: unknown option '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: full Xcode not found. Install Xcode.app or set DEVELOPER_DIR." >&2; exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install with: brew install xcodegen" >&2; exit 1
fi

xcodegen generate --spec App-iOS/project.yml --project App-iOS

scripts/lib/with-lock.sh build -- xcodebuild \
  -project App-iOS/OrchestraiOS.xcodeproj \
  -scheme OrchestraiOS \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build "$@"

echo "iOS build OK ($CONFIG)."

if [[ "$RUN" == 1 ]]; then
  # Boot a headless Simulator, install, launch against the local daemon socket, screenshot.
  # Never touches the user's screen (the Simulator runs headless; simctl drives it).
  DEV_SOCKET="${ORCH_DEV_SOCKET:-$HOME/Library/Application Support/Orchestra/orchestrad.sock}"
  # Pick the named device if set, else the first available iPhone (device names drift across Xcode
  # versions, so we don't hardcode one).
  if [[ -n "${ORCH_SIM_DEVICE:-}" ]]; then
    UDID="$(xcrun simctl list devices available | grep -m1 "    ${ORCH_SIM_DEVICE} (" | grep -oE '[0-9A-Fa-f-]{36}' | head -1)"
    [[ -n "$UDID" ]] || { echo "error: no available Simulator '$ORCH_SIM_DEVICE'"; exit 1; }
  else
    UDID="$(xcrun simctl list devices available | grep -m1 '    iPhone ' | grep -oE '[0-9A-Fa-f-]{36}' | head -1)"
    [[ -n "$UDID" ]] || { echo "error: no available iPhone Simulator (set ORCH_SIM_DEVICE)"; exit 1; }
  fi
  xcrun simctl boot "$UDID" 2>/dev/null || true
  APP="$(xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration "$CONFIG" \
    -destination 'generic/platform=iOS Simulator' -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {d=$2} / FULL_PRODUCT_NAME / {n=$2} END {print d "/" n}')"
  xcrun simctl install "$UDID" "$APP"
  # Env vars for the launched app MUST use the SIMCTL_CHILD_ prefix (simctl passes trailing args as
  # argv, not environment) — this is how ORCH_DEV_SOCKET reaches the sandboxed app process.
  SIMCTL_CHILD_ORCH_DEV_SOCKET="$DEV_SOCKET" \
    xcrun simctl launch "$UDID" com.orchestra.ios
  sleep 4
  mkdir -p .scratch
  xcrun simctl io "$UDID" screenshot .scratch/ios-board.png
  echo "Screenshot: .scratch/ios-board.png (ORCH_DEV_SOCKET=$DEV_SOCKET)"
fi
