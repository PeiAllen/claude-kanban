#!/bin/bash
# Build (and optionally launch) the Orchestra.app SwiftUI bundle, installing it into /Applications.
#
# Unlike the dependency-free core (scripts/build.sh / `swift build`), the app needs full Xcode +
# SwiftTerm. This regenerates the xcodeproj from App/project.yml, builds it with xcodebuild, and
# copies the resulting bundle into /Applications (replacing any previous install).
#
# Usage: scripts/build-app.sh [--run] [--debug] [-- <extra xcodebuild args>]
#   --run     launch the installed app when the build succeeds
#   --debug   build the Debug configuration instead of the default (Release)
set -euo pipefail
cd "$(dirname "$0")/.."

DEST_DIR="/Applications"

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

# Point at full Xcode. xcode-select may still target the Command Line Tools (which can't build the
# bundle), so prefer an explicit Xcode.app unless DEVELOPER_DIR is already set to one.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: full Xcode not found. Install Xcode.app or set DEVELOPER_DIR." >&2
  exit 1
fi

# Regenerate the project from the spec so source/file changes are picked up.
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi
xcodegen generate --spec App/project.yml --project App

xcodebuild \
  -project App/Orchestra.xcodeproj \
  -scheme Orchestra \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  build "$@"

BUILT_APP="$(xcodebuild -project App/Orchestra.xcodeproj -scheme Orchestra -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {d=$2} / FULL_PRODUCT_NAME / {n=$2} END {print d "/" n}')"

# Embed the daemon/CLI binaries inside the app bundle so it's self-contained. They go in
# Contents/Resources/bin (NOT Contents/MacOS): the macOS filesystem is case-insensitive, so the
# `orchestra` CLI would clobber the `Orchestra` app executable if they shared a directory. The app
# resolves orchestrad from this dir; orchestrad in turn finds `orchestra` as its own sibling here.
echo "Building daemon binaries (release)…"
swift build -c release --product orchestrad
swift build -c release --product orchestra
swift build -c release --product orchestra-mcp
SWIFT_BIN=".build/release"

BIN_DIR="$BUILT_APP/Contents/Resources/bin"
mkdir -p "$BIN_DIR"
for b in orchestrad orchestra orchestra-mcp; do
  cp -f "$SWIFT_BIN/$b" "$BIN_DIR/$b"
done

# OrchestraCore ships resources (the LaunchAgent plist + hooks templates) in a SwiftPM resource
# bundle loaded via Bundle.module, which is resolved next to the running executable. Copy it beside
# the binaries or orchestrad fatal-errors on launch ("could not load resource bundle").
RES_BUNDLE="Orchestra_OrchestraCore.bundle"
if [[ -d "$SWIFT_BIN/$RES_BUNDLE" ]]; then
  rm -rf "$BIN_DIR/$RES_BUNDLE"
  cp -R "$SWIFT_BIN/$RES_BUNDLE" "$BIN_DIR/$RES_BUNDLE"
fi

# Adding files to the bundle invalidates the app's signature, so re-sign everything ad-hoc (sufficient
# for local runs under hardened runtime). Sign inside-out — nested binaries first, then the outer
# bundle (which seals the flat resource bundle as data — it has no Info.plist, so it must NOT be
# signed on its own).
for b in orchestrad orchestra orchestra-mcp; do
  codesign --force --options runtime --timestamp=none --sign - "$BIN_DIR/$b"
done

# Re-sign nested Mach-O code (frameworks + any dylibs) ad-hoc before sealing the bundle. Debug builds
# split the app code into Contents/MacOS/Orchestra.debug.dylib; left with Xcode's original "Sign to
# Run Locally" signature it carries a team identifier the ad-hoc main executable lacks, so dyld
# refuses to load it ("different Team IDs" → "Orchestra could not be opened"). Signing the whole code
# graph ad-hoc keeps the team identifiers consistent (all absent). Release builds link statically and
# have neither dir, so the guards make this a no-op there. (Process substitution + the `-d` guard keep
# a missing dir from tripping `set -euo pipefail`.)
for dir in "$BUILT_APP/Contents/Frameworks" "$BUILT_APP/Contents/MacOS"; do
  [[ -d "$dir" ]] || continue
  while IFS= read -r -d '' c; do
    codesign --force --options runtime --timestamp=none --sign - "$c"
  done < <(find "$dir" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0 2>/dev/null)
done

codesign --force --options runtime --timestamp=none \
  --entitlements App/Orchestra.entitlements --sign - "$BUILT_APP"

# Install into /Applications, replacing any previous copy. ditto preserves the bundle's codesign.
INSTALLED_APP="$DEST_DIR/$(basename "$BUILT_APP")"
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"

echo "Installed: $INSTALLED_APP"
if [[ "$RUN" == 1 ]]; then
  open "$INSTALLED_APP"
fi
