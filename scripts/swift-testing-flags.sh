#!/bin/bash
# Shared flags so `swift-testing` works under a Command Line Tools (no full Xcode) toolchain.
# CLT ships Testing.framework + lib_TestingInterop.dylib but doesn't put them on the default
# search/rpath, so we add them explicitly. Sourced by build.sh / test.sh.
#
# Guarded: only when the AMBIENT developer dir (DEVELOPER_DIR, else `xcode-select -p`) is bare
# CLT — no full Xcode.app. A full Xcode already bundles its own (newer) Testing.framework on its
# default search path; forcing the CLT one in ahead of it shadows the version the active
# toolchain's own TestingMacros plugin actually expects, producing a macro-ABI mismatch
# ("module 'Testing' has no member named '__SourceBounds'", etc.) instead of a missing symbol.
_DEV_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)}"
SWIFT_TESTING_FLAGS=()
if [[ "$_DEV_DIR" != *"Xcode.app"* ]]; then
  CLT_FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
  CLT_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
  SWIFT_TESTING_FLAGS=(
    -Xswiftc -F -Xswiftc "$CLT_FW"
    -Xlinker -F -Xlinker "$CLT_FW"
    -Xlinker -rpath -Xlinker "$CLT_FW"
    -Xlinker -rpath -Xlinker "$CLT_LIB"
  )
fi
unset _DEV_DIR
