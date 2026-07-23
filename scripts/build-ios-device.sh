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
#   ORCH_IOS_TEAM_ID=XXXXXXXXXX scripts/build-ios-device.sh            # build a signed RELEASE .app
#   ORCH_IOS_TEAM_ID=XXXXXXXXXX scripts/build-ios-device.sh --install  # also install to the paired iPhone
#   scripts/build-ios-device.sh --install --device 'Allen'             # pick one of several iPhones
#                                                                        # (or export ORCH_IOS_DEVICE)
#   scripts/build-ios-device.sh --install --debug                      # unoptimized build (debugger/symbols)
#   ORCH_IOS_BUNDLE_ID=com.you.orchestra scripts/build-ios-device.sh   # override bundle id (free teams
#                                                                        # often need a unique one)
#
# VERIFIED ON METAL 2026-07-23 — entirely over Wi-Fi, no cable: this script built `** BUILD SUCCEEDED **`
# signing `keychain-access-groups` only (no aps-environment) for team 3Q39256L2K / com.orchestra.ios, then
# `devicectl device install app` and `devicectl device process launch --terminate-existing` put it on a
# network-paired iPhone 16 Pro Max and started it. Still unverified: a bundle id colliding with another
# Apple ID (the ORCH_IOS_BUNDLE_ID escape hatch), re-signing after the 7-day profile expiry, and the
# Release configuration specifically — that run predates the Debug→Release default flip below, so what
# went on metal was a Debug build. Signing and install are configuration-independent, so this is a gap
# in the evidence rather than a known problem.
#
# ⚠️ THREE GOTCHAS, because each presents as some other, more alarming failure:
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
#
# 3. ENDING AT "trust the developer on the phone" IS SUCCESS, NOT FAILURE. iOS's Untrusted Developer
#    gate is a per-signing-identity consent step downstream of compile/sign/install, so reaching it
#    means everything this script does worked. It is manual, it is on the device, and because each
#    fresh 7-day profile is a new signing identity it recurs EVERY cycle — it is not first-install-only.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

INSTALL=0
# RELEASE by default, unlike the Simulator lane (scripts/ios-live.sh), and the two are deliberately
# NOT harmonized: this script's output goes on a real phone to be USED, where Debug's -Onone Swift is
# felt directly as UI lag (SwiftUI diffing, terminal rendering). ios-live.sh is a tight
# iterate-in-the-Simulator loop where a faster build beats a faster app, so Debug is right there.
# Optimize each lane for what it is actually for; --debug below is the escape hatch for the rare
# device build you mean to attach a debugger to or want usable symbols in.
CONFIG="Release"
DEVICE_SELECTOR="${ORCH_IOS_DEVICE:-}"   # env default; --device wins over it
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --install) INSTALL=1; shift ;;
    --debug) CONFIG="Debug"; shift ;;
    # Redundant with the default, but kept and kept MEANINGFUL: an older invocation asking for
    # Release still gets Release, and selecting rather than ignoring keeps the two flags
    # order-independent (last one wins) instead of silently letting --debug beat a later --release.
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
  # The trust gate below is per SIGNING IDENTITY, not per app, so it recurs with every fresh 7-day
  # profile — not just the first install. It sits downstream of compile/sign/install, so reaching it
  # means this script SUCCEEDED; say so plainly rather than leaving it to read as a failure.
  echo "installed."
  echo "NEXT (manual, and needed again after every new 7-day profile — this is not an error):"
  echo "  on the iPhone, Settings ▸ General ▸ VPN & Device Management ▸ your Apple ID ▸ Trust,"
  echo "  then tap the app icon. Until you do, iOS shows \"Untrusted Developer\" and refuses to launch."
  # Deliberately not offered as a substitute for the above: devicectl launches via the developer disk
  # image, a debug path the trust gate does not cover, so it works even while the developer is
  # untrusted — a successful launch here does NOT prove the home-screen icon works.
  echo "To smoke-test the build without the phone (works even while untrusted, so it proves less):"
  echo "  xcrun devicectl device process launch --device $DEVICE --terminate-existing $BUNDLE_ID"
fi
echo "DONE"
