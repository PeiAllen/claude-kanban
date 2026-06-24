#!/bin/bash
# Type-check the SwiftUI app sources against the CLT macOS SDK + the built OrchestraCore module.
# (The .app bundle itself needs full Xcode + SwiftTerm — see App/README.md.)
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target OrchestraCore >/dev/null
MOD=".build/$(uname -m)-apple-macosx/debug/Modules"
exec swiftc -typecheck \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  -target "$(uname -m)-apple-macosx14.0" \
  -I "$MOD" \
  App/Theme.swift App/BoardModel.swift App/OrchestraApp.swift App/Views/*.swift
