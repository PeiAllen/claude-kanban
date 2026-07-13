#!/usr/bin/env bash
# F1 acceptance gate: OrchestraKit must be client-safe.
#  (1) zero Foundation.Process / posix_spawn / AppKit / UIKit references, and
#  (2) it typechecks against the iOS SDK in isolation.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== (1) source audit: forbidden references in OrchestraKit =="
# \bProcess\( matches `Process(` but NOT `ProcessInfo` — Config legitimately uses
# ProcessInfo.processInfo.environment, which exists on iOS and is allowed.
if grep -rnE 'import AppKit|import UIKit|Foundation\.Process|posix_spawn|\bProcess\(' Sources/OrchestraKit/ ; then
  echo "FAIL: OrchestraKit contains a forbidden client-unsafe reference (see above)"; exit 1
fi
echo "ok: no Process/AppKit/UIKit references"

echo "== (2) iOS-SDK typecheck of the OrchestraKit target in isolation =="
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
scripts/lib/with-lock.sh build -- swift build --target OrchestraKit \
  -Xswiftc -sdk -Xswiftc "$SDK" \
  -Xswiftc -target -Xswiftc arm64-apple-ios17.0
echo "ok: OrchestraKit typechecks for arm64-apple-ios17.0"
