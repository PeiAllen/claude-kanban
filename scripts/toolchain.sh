#!/bin/bash
# Pin the Swift toolchain to Command Line Tools (CLT) so `swift build` / `swift test` compile the
# OrchestraCore/UI modules against the SAME macOS SDK that `typecheck-app.sh`'s `swiftc -sdk` targets.
#
# Why: the ambient toolchain is Xcode (xcode-select -p → Xcode.app). Without this pin, `swift test`
# leaves an Xcode-SDK module in `.build/`, and the CLT-SDK app typecheck then fails to import it
# ("module compiled with a different SDK"). The only "fix" at that point is clearing a global SwiftPM
# module cache under ~/Library — which is OUTSIDE the sandbox-writable set and triggers a human-approval
# prompt (fatal for an unattended run). Pinning DEVELOPER_DIR here removes the mismatch at the source, so
# no cache ever has to be cleared. All the scripts already target CLT (swift-testing-flags.sh adds the CLT
# framework paths; typecheck-app.sh uses `-sdk .../CommandLineTools/...`) — this just makes the *builder*
# agree with them.
#
# Sourced by typecheck-app.sh (NOT test.sh — the test suites `import XCTest`, which the CLT toolchain
# does not expose on its search path, so tests run under the ambient Xcode toolchain). typecheck-app.sh's
# own `swift build --target OrchestraUI` then rebuilds both modules under this CLT SDK so its `swiftc -sdk`
# matches. Only pins when the CLT toolchain is present; override by exporting DEVELOPER_DIR yourself.
_CLT_DIR="/Library/Developer/CommandLineTools"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$_CLT_DIR" ]; then
  export DEVELOPER_DIR="$_CLT_DIR"
fi
unset _CLT_DIR
