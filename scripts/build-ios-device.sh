#!/bin/bash
# Build (and optionally install) the Orchestra iOS app for a REAL iPhone with a FREE personal Apple team.
#
# Free personal team ⇒ no paid membership ⇒ Push Notifications capability is unavailable, so this lane
# signs with App-iOS/OrchestraiOS-nopush.entitlements (keychain-access-groups only, NO aps-environment).
# Board + terminals + takeover need none of it (real APNs is out of scope on the free tier; alerts come via
# the Claude/Codex apps). See notes/designs/ios-real-device-onboarding-and-transport.md §7.
#
# Your Apple team id stays OUT OF GIT — this script reads it from, in order:
#   1. $ORCH_IOS_TEAM_ID                       (env var; preferred for CI / one-offs)
#   2. App-iOS/DeviceSigning.local.xcconfig    (gitignored; a line `DEVELOPMENT_TEAM = XXXXXXXXXX`)
# Find your 10-char team id at https://developer.apple.com/account (Membership), or in Xcode ▸ Settings ▸
# Accounts ▸ your Apple ID ▸ team. A free Apple ID gets a "Personal Team" with a valid id.
#
# Usage:
#   ORCH_IOS_TEAM_ID=XXXXXXXXXX scripts/build-ios-device.sh            # build a signed .app for a device
#   ORCH_IOS_TEAM_ID=XXXXXXXXXX scripts/build-ios-device.sh --install  # also install to a connected iPhone
#   ORCH_IOS_BUNDLE_ID=com.you.orchestra scripts/build-ios-device.sh   # override bundle id (free teams
#                                                                        # often need a unique one)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

INSTALL=0
CONFIG="Debug"
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --install) INSTALL=1; shift ;;
    --release) CONFIG="Release"; shift ;;
    *) echo "error: unknown option '$1'" >&2; exit 1 ;;
  esac
done

# --- resolve the team id (never committed) --------------------------------------------------------
LOCAL_XCCONFIG="App-iOS/DeviceSigning.local.xcconfig"
TEAM="${ORCH_IOS_TEAM_ID:-}"
if [[ -z "$TEAM" && -f "$LOCAL_XCCONFIG" ]]; then
  TEAM="$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Za-z0-9]+).*/\1/p' "$LOCAL_XCCONFIG" | head -1)"
fi
if [[ -z "$TEAM" ]]; then
  cat >&2 <<EOF
error: no Apple team id. This stays out of git — provide it one of two ways:
  • export ORCH_IOS_TEAM_ID=XXXXXXXXXX
  • create $LOCAL_XCCONFIG (gitignored) with a line:  DEVELOPMENT_TEAM = XXXXXXXXXX
EOF
  exit 1
fi
BUNDLE_ID="${ORCH_IOS_BUNDLE_ID:-com.orchestra.ios}"
echo "team=$TEAM  bundle=$BUNDLE_ID  config=$CONFIG  entitlements=OrchestraiOS-nopush.entitlements"

# --- generate the project + build signed for a device ---------------------------------------------
command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }
xcodegen generate --spec App-iOS/project.yml --project App-iOS >/dev/null

# Automatic signing + free-team provisioning update; the no-push entitlements are the key difference from
# the Simulator lane. `-allowProvisioningUpdates` lets Xcode create/refresh the free development profile.
xcodebuild \
  -project App-iOS/OrchestraiOS.xcodeproj \
  -scheme OrchestraiOS \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_ENTITLEMENTS=App-iOS/OrchestraiOS-nopush.entitlements \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build

APP="$(xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {d=$2} / FULL_PRODUCT_NAME / {n=$2} END {print d "/" n}')"
echo "built: $APP"
[ -d "$APP" ] || { echo "error: no .app produced" >&2; exit 1; }
echo "entitlements: $(codesign -d --entitlements :- "$APP" 2>/dev/null | tr -d '\0' \
  | grep -oE 'aps-environment|keychain-access-groups' | sort -u | paste -sd, -)  (must NOT list aps-environment)"

# --- optionally install to a connected iPhone -----------------------------------------------------
if [[ "$INSTALL" == 1 ]]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ && /iPhone/ {print $(NF-1); exit}')"
  [ -n "$DEVICE" ] || { echo "error: no connected iPhone found (xcrun devicectl list devices)" >&2; exit 1; }
  echo "=== install to $DEVICE ==="
  xcrun devicectl device install app --device "$DEVICE" "$APP"
  echo "installed. First launch: on the iPhone, trust the developer profile in Settings ▸ General ▸ VPN & Device Management."
fi
echo "DONE"
