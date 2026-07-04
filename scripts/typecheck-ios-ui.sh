#!/usr/bin/env bash
# F2 acceptance gate: the shared OrchestraUI target (Theme + BoardModel + the four platform protocols)
# must compile for iOS with zero AppKit — every macOS/daemon reference is behind `#if os(macOS)` and
# drops out for the phone.
#
# We deliberately do NOT use `swift build --target OrchestraUI -Xswiftc -sdk iphoneos ...` (the shape
# scripts/typecheck-kit-ios.sh uses for the leaf OrchestraKit): OrchestraUI has a *macOS-conditional*
# OrchestraCore dependency, and SwiftPM — whose build platform is the macOS host — still resolves that
# dependency and tries to compile OrchestraCore (which uses `Process`) for the iOS triple, which fails.
# Instead we typecheck OrchestraUI's *sources* directly against an iOS-built OrchestraKit module — which
# is exactly what the real iOS app compiles (OrchestraCore is never in the iOS graph).
set -euo pipefail
cd "$(dirname "$0")/.."

SDK_NAME=iphoneos
TRIPLE=arm64-apple-ios17.0

echo "== (1) emit an iOS OrchestraKit module =="
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# shellcheck disable=SC2046
xcrun --sdk "$SDK_NAME" swiftc -emit-module -module-name OrchestraKit -target "$TRIPLE" \
  $(find Sources/OrchestraKit -name '*.swift') \
  -emit-module-path "$OUT/OrchestraKit.swiftmodule"
echo "ok: OrchestraKit emits an $TRIPLE module"

echo "== (2) typecheck OrchestraUI for $TRIPLE (AppKit / OrchestraCore are #if os(macOS)-fenced out) =="
# If any AppKit / NSApp / NSPasteboard / OrchestraCore reference escaped a macOS fence, this fails.
# shellcheck disable=SC2046
xcrun --sdk "$SDK_NAME" swiftc -typecheck -target "$TRIPLE" -I "$OUT" \
  $(find Sources/OrchestraUI -name '*.swift')
echo "ok: OrchestraUI (Theme + BoardModel + platform protocols) typechecks for $TRIPLE with no AppKit"
