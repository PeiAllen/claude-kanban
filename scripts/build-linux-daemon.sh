#!/bin/bash
# Cross-compile the Orchestra daemon + CLI as static Linux binaries FROM a Mac (no Swift toolchain on
# the target box). Uses the Swift Static Linux SDK (musl) so the output is a zero-dependency static
# executable you can scp to any Linux box and run.
#
# Products built: orchestrad, orchestra, orchestra-mcp — plus the Orchestra_OrchestraCore.bundle
# resource dir (the daemon loads embedded.conf / hook templates from it at runtime, beside the binary).
#
# Usage:
#   scripts/build-linux-daemon.sh [--arch x86_64|aarch64] [--out DIR]
#     --arch   target CPU of the Linux box (default: x86_64). Use aarch64 for ARM boxes.
#     --out    output dir (default: dist/linux-<arch>)
#
# One-time prerequisite: the musl static SDK must be installed for your toolchain, e.g.
#   swift sdk install \
#     https://download.swift.org/swift-6.0.3-release/static-sdk/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz \
#     --checksum 67f765e0030e661a7450f7e4877cfe008db4f57f177d5a08a6e26fd661cdd0bd
# (Grab the URL + checksum matching YOUR `swift --version` from https://www.swift.org/download/ →
# "Static Linux SDK". This script checks for an installed SDK and points you here if it's missing.)
#
# NOTE: the Linux socket port has shipped (UDSSocket.swift is Glibc/musl-ported with a MSG_NOSIGNAL
# send-flag under #if os(Linux)), so this cross-build produces a working static binary. See
# docs/08-building-operations.md ("Deploying orchestrad to a remote Linux box") for the full setup.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="x86_64"
OUT=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --out)  OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "error: unknown option '$1'" >&2; exit 1 ;;
  esac
done
[[ -n "$OUT" ]] || OUT="dist/linux-$ARCH"

case "$ARCH" in
  x86_64)  TRIPLE="x86_64-swift-linux-musl" ;;
  aarch64) TRIPLE="aarch64-swift-linux-musl" ;;
  *) echo "error: --arch must be x86_64 or aarch64 (got '$ARCH')" >&2; exit 1 ;;
esac

# Find an installed static Linux (musl) SDK. `swift sdk list` prints installed SDK ids one per line;
# depending on the release these are named `…_static-linux-<ver>` (the artifactbundle) rather than
# containing the literal "musl", so match either — the destination triple `*-swift-linux-musl` is what
# the build below selects regardless of the id's spelling.
if ! swift sdk list 2>/dev/null | grep -qiE 'musl|static-linux'; then
  cat >&2 <<'EOF'
error: no Swift Static Linux (musl) SDK is installed.

Install the one matching your toolchain (see `swift --version`), then re-run. Example for 6.0.3:

  swift sdk install \
    https://download.swift.org/swift-6.0.3-release/static-sdk/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz \
    --checksum 67f765e0030e661a7450f7e4877cfe008db4f57f177d5a08a6e26fd661cdd0bd

Find the URL + checksum for your exact toolchain at https://www.swift.org/download/ (Static Linux SDK).
EOF
  exit 2
fi

echo "Cross-compiling for $TRIPLE (static musl) → $OUT"
for product in orchestrad orchestra orchestra-mcp; do
  echo "  building ${product}..."
  scripts/lib/with-lock.sh build -- swift build -c release --swift-sdk "$TRIPLE" --product "$product"
done

BIN_DIR=".build/$TRIPLE/release"
[[ -x "$BIN_DIR/orchestrad" ]] || BIN_DIR="$(swift build -c release --swift-sdk "$TRIPLE" --show-bin-path)"

mkdir -p "$OUT"
for b in orchestrad orchestra orchestra-mcp; do
  cp -f "$BIN_DIR/$b" "$OUT/$b"
done

# The daemon loads OrchestraCore's SwiftPM resources (embedded.conf, hook templates, plist) from a
# resource bundle resolved next to the executable — copy it or orchestrad fatal-errors on launch.
RES_BUNDLE="Orchestra_OrchestraCore.resources"
if [[ -d "$BIN_DIR/$RES_BUNDLE" ]]; then
  rm -rf "$OUT/$RES_BUNDLE"
  cp -R "$BIN_DIR/$RES_BUNDLE" "$OUT/$RES_BUNDLE"
elif [[ -d "$BIN_DIR/Orchestra_OrchestraCore.bundle" ]]; then
  rm -rf "$OUT/Orchestra_OrchestraCore.bundle"
  cp -R "$BIN_DIR/Orchestra_OrchestraCore.bundle" "$OUT/Orchestra_OrchestraCore.bundle"
fi

echo
echo "Built → $OUT"
ls -lh "$OUT"
echo
echo "Next: scripts/deploy-linux-daemon.sh <user@host> --arch $ARCH"
