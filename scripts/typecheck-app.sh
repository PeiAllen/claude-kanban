#!/bin/bash
# Type-check the SwiftUI app sources against the CLT macOS SDK + its built OrchestraCore/UI modules.
# (The .app bundle itself needs full Xcode + SwiftTerm — see App/README.md.)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh
scripts/lib/with-lock.sh build -- swift build --target OrchestraUI >/dev/null
MOD=".build/$(uname -m)-apple-macosx/debug/Modules"
exec swiftc -typecheck \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  -target "$(uname -m)-apple-macosx14.0" \
  -I "$MOD" \
  App/*.swift App/Views/*.swift
