#!/bin/bash
# Shared flags so `swift-testing` works under a Command Line Tools (no full Xcode) toolchain.
# CLT ships Testing.framework + lib_TestingInterop.dylib but doesn't put them on the default
# search/rpath, so we add them explicitly. Sourced by build.sh / test.sh.
CLT_FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
SWIFT_TESTING_FLAGS=(
  -Xswiftc -F -Xswiftc "$CLT_FW"
  -Xlinker -F -Xlinker "$CLT_FW"
  -Xlinker -rpath -Xlinker "$CLT_FW"
  -Xlinker -rpath -Xlinker "$CLT_LIB"
)
