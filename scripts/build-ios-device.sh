#!/bin/bash
# Build (and optionally install) the Orchestra iOS app for a REAL iPhone with a FREE personal Apple team.
#
# Free personal team ⇒ no paid membership ⇒ Push Notifications capability is unavailable, so this lane
# signs with App-iOS/OrchestraiOS-nopush.entitlements (keychain-access-groups only, NO aps-environment).
# Board + terminals + takeover need none of it (real APNs is out of scope on the free tier; alerts come via
# the Claude/Codex apps). See docs/08-building-operations.md (§Building the iOS app for a real device).
#
# Your Apple team id stays OUT OF GIT — this script reads it from, in order:
#   1. $ORCH_IOS_TEAM_ID                       (env var; preferred for CI / one-offs)
#   2. App-iOS/DeviceSigning.local.xcconfig    (gitignored; a line `DEVELOPMENT_TEAM = XXXXXXXXXX`)
# Find your 10-char team id at https://developer.apple.com/account (Membership), or in Xcode ▸ Settings ▸
# Accounts ▸ your Apple ID ▸ team. A free Apple ID gets a "Personal Team" with a valid id.
#
# Usage:
#   ORCH_IOS_TEAM_ID=XXXXXXXXXX scripts/build-ios-device.sh            # build a signed .app for a device
#   ORCH_IOS_TEAM_ID=XXXXXXXXXX scripts/build-ios-device.sh --install  # also install to the paired iPhone
#   scripts/build-ios-device.sh --install --device 'Allen'             # pick one of several iPhones
#                                                                        # (or export ORCH_IOS_DEVICE)
#   ORCH_IOS_BUNDLE_ID=com.you.orchestra scripts/build-ios-device.sh   # override bundle id (free teams
#                                                                        # often need a unique one)
#
# VERIFIED ON METAL 2026-07-23 — entirely over Wi-Fi, no cable: this script built `** BUILD SUCCEEDED **`
# signing `keychain-access-groups` only (no aps-environment) for team 3Q39256L2K / com.orchestra.ios, then
# `devicectl device install app` and `devicectl device process launch --terminate-existing` put it on a
# network-paired iPhone 16 Pro Max and started it. Still unverified: a bundle id colliding with another
# Apple ID (the ORCH_IOS_BUNDLE_ID escape hatch), and re-signing after the 7-day profile expiry.
#
# ⚠️ TWO GOTCHAS, because both present as some other, more alarming failure:
#
# 1. THE PHONE MUST BE UNLOCKED, or mounting the developer disk image fails with
#    kAMDMobileImageMounterDeviceLocked / CoreDeviceError 12040. It reads like a pairing or transport
#    fault; it is the lock screen. Unlock to the home screen and re-run.
#
# 2. THIS SCRIPT CANNOT MINT A FREE-TEAM PROFILE — only consume one. `xcodebuild` cannot reach the
#    keychain-backed session of the Apple ID signed into Xcode from a non-GUI shell, so on a
#    profile-less bundle it fails with "No Accounts: Add a new account in Accounts settings" +
#    "No profiles for '<bundle id>' were found" EVEN THOUGH the Apple ID is signed in correctly.
#    That message invites the wrong diagnosis ("I'm not signed in") — you are; there is simply no
#    profile on disk yet. -allowProvisioningUpdates is still passed below because it does refresh an
#    existing profile. So the free-tier cycle is: ⌘R once from the Xcode GUI to mint the 7-day
#    profile, after which this scripted lane works unattended until it expires. See
#    App-iOS/DEPLOY-TO-DEVICE.md and docs/08-building-operations.md (§Building the iOS app for a real device).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

INSTALL=0
CONFIG="Debug"
DEVICE_SELECTOR="${ORCH_IOS_DEVICE:-}"   # env default; --device wins over it
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --install) INSTALL=1; shift ;;
    --release) CONFIG="Release"; shift ;;
    --device) DEVICE_SELECTOR="${2:-}"; [ -n "$DEVICE_SELECTOR" ] || { echo "error: --device needs a value" >&2; exit 1; }; shift 2 ;;
    --device=*) DEVICE_SELECTOR="${1#*=}"; shift ;;
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
scripts/lib/with-lock.sh build -- xcodebuild \
  -project App-iOS/OrchestraiOS.xcodeproj \
  -scheme OrchestraiOS \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_ENTITLEMENTS=OrchestraiOS-nopush.entitlements \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build
# NOTE on CODE_SIGN_ENTITLEMENTS: Xcode resolves it relative to $(SRCROOT), which for this project is
# App-iOS/ (the dir holding OrchestraiOS.xcodeproj). So it MUST be a bare basename — the file lives at
# App-iOS/OrchestraiOS-nopush.entitlements. A leading `App-iOS/` here double-nests to
# App-iOS/App-iOS/OrchestraiOS-nopush.entitlements (nonexistent) → signing silently uses the target's
# default OrchestraiOS.entitlements (which HAS aps-environment) and free-team signing fails. project.yml's
# own `CODE_SIGN_ENTITLEMENTS: OrchestraiOS.entitlements` (bare) confirms the SRCROOT-relative convention.

APP="$(xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {d=$2} / FULL_PRODUCT_NAME / {n=$2} END {print d "/" n}')"
echo "built: $APP"
[ -d "$APP" ] || { echo "error: no .app produced" >&2; exit 1; }
echo "entitlements: $(codesign -d --entitlements :- "$APP" 2>/dev/null | tr -d '\0' \
  | grep -oE 'aps-environment|keychain-access-groups' | sort -u | paste -sd, -)  (must NOT list aps-environment)"

# --- optionally install to the paired iPhone ------------------------------------------------------
if [[ "$INSTALL" == 1 ]]; then
  # Ask devicectl for JSON rather than scraping its table. `devicectl list devices --help` states that
  # "JSON output to a user-provided file on disk is the ONLY supported interface for scripts/programs
  # to consume command output" — and the table is exactly what broke this lane before: its State column
  # renders a network-paired iPhone (the normal state once "Connect via network" is ticked) as
  # `available (paired)`, so filtering rows for `connected` matched nothing and the install died after a
  # good build. There is no `state` field in the JSON to key off either — that column is assembled from
  # connectionProperties — so scripts/lib/ios-pick-device.py selects on device IDENTITY instead
  # (platform/reality/deviceType) and never on connection state. See that file for the full policy;
  # scripts/lib/ios-pick-device-test.sh pins it against captured JSON, no phone required.
  #
  # --json-output takes a path, so route it through a temp file we own and clean up. devicectl still
  # prints its human table to stdout; drop that and keep stderr, which carries the real diagnosis when
  # CoreDevice itself is unhappy (e.g. the XPC/CoreDeviceService errors you get in a sandbox).
  DEVICES_JSON="$(mktemp -t orch-ios-devices)"
  trap 'rm -f "$DEVICES_JSON"' EXIT
  xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null \
    || { echo "error: 'xcrun devicectl list devices' failed (see above)" >&2; exit 1; }
  # Array, not ${VAR:+…}: a selector is routinely a name with a space in it ("Allen's iPhone"), and an
  # unquoted conditional expansion would word-split it into two arguments.
  PICK_ARGS=(--json "$DEVICES_JSON")
  if [[ -n "$DEVICE_SELECTOR" ]]; then PICK_ARGS+=(--device "$DEVICE_SELECTOR"); fi
  # `set -e` aborts here if the picker can't choose one device; it has already explained why on stderr.
  DEVICE="$(scripts/lib/ios-pick-device.py "${PICK_ARGS[@]}")"

  echo "=== install to $DEVICE ==="
  # A locked phone fails here with kAMDMobileImageMounterDeviceLocked / CoreDeviceError 12040, which
  # reads like a pairing fault — say so up front rather than leaving that to be rediscovered.
  xcrun devicectl device install app --device "$DEVICE" "$APP" \
    || { echo "hint: is the iPhone unlocked? a locked phone fails the developer-disk-image mount (CoreDeviceError 12040)." >&2; exit 1; }
  echo "installed. Launch it from the home screen, or:"
  echo "  xcrun devicectl device process launch --device $DEVICE --terminate-existing $BUNDLE_ID"
  echo "First install only: trust the developer profile on the iPhone in Settings ▸ General ▸ VPN & Device Management."
fi
echo "DONE"
