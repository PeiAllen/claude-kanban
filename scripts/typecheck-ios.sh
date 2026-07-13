#!/bin/bash
# Type-check (compile-only, no signing, no install) the Orchestra iOS APP TARGET for the Simulator.
# The iOS equivalent of scripts/typecheck-app.sh — but iOS has no CLT-SDK swiftc shortcut that also
# resolves SwiftTerm/OrchestraUI iOS modules, so it drives `xcodebuild build` instead.
#
# Note: scripts/typecheck-ios-ui.sh (F2) already typechecks the shared OrchestraUI *library* for iOS.
# This script is the fuller gate — it compiles+links the whole App-iOS bundle (OrchestraKit +
# OrchestraUI + SwiftTerm + the app sources).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not found (brew install xcodegen)"; exit 1; }
xcodegen generate --spec App-iOS/project.yml --project App-iOS
exec scripts/lib/with-lock.sh build -- xcodebuild \
  -project App-iOS/OrchestraiOS.xcodeproj \
  -scheme OrchestraiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
