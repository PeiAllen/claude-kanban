#!/bin/bash
# Vendor the document reader's JS into the OrchestraUI resource bundle.
#
# WHY THE BYTES ARE COMMITTED. A native app has no package manager inside its bundle: whatever the page
# needs at render time has to be there already, because the reader works offline on a phone. SwiftPM
# cannot fetch it either — a build-tool plugin has no network by API construction. So the only real
# choice is WHERE the copy lives before the build, and committing it is what every comparable Swift
# package does (MarkdownView, markdown-webview, WKMarkdownView all commit theirs, several of them larger
# and less selective than this).
#
# What separates vendoring from dumping a blob in the tree is the three things below, so keep them:
#   * EXACT pinned versions, fetched from the npm registry CDN — this file is the manifest.
#   * RECORDED CHECKSUMS. `SHA256SUMS` is written here and verified by DocumentReaderBundleTests, so a
#     committed file that is corrupted, hand-edited, or swapped fails the suite. This is the guarantee a
#     lockfile's `integrity` field gives, and it is the one thing a naive vendor tree lacks.
#   * `--check`, which asks the registry what the current versions are. Pinning without a way to notice
#     you are behind is how vendored trees rot.
#
# NETWORK IS REQUIRED, so run this UNSANDBOXED. Usage:
#   scripts/vendor-document-reader-assets.sh            # re-vendor at the pinned versions
#   scripts/vendor-document-reader-assets.sh --check    # report newer versions, change nothing
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=Sources/OrchestraUI/Resources/DocumentReader/vendor
MARKED=18.0.9
MKE=5.1.10
KATEX=0.18.4
PURIFY=3.4.13
BASE=https://cdn.jsdelivr.net/npm

if [[ "${1:-}" == "--check" ]]; then
  echo "pinned vs latest:"
  for pkg_ver in "marked:$MARKED" "marked-katex-extension:$MKE" "katex:$KATEX" "dompurify:$PURIFY"; do
    pkg=${pkg_ver%%:*}; pinned=${pkg_ver##*:}
    latest=$(curl -fsSL --max-time 20 "https://registry.npmjs.org/$pkg/latest" |
             sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
    if [[ "$pinned" == "$latest" ]]; then printf '  %-26s %-10s current\n' "$pkg" "$pinned"
    else                                 printf '  %-26s %-10s -> %s AVAILABLE\n' "$pkg" "$pinned" "$latest"; fi
  done
  exit 0
fi

rm -rf "$DEST"
mkdir -p "$DEST"

fetch() { curl -fsSL --retry 3 --max-time 60 "$1" -o "$2"; echo "  $(basename "$2") $(wc -c <"$2" | tr -d ' ') B"; }

echo "vendoring:"
fetch "$BASE/marked@$MARKED/lib/marked.umd.js"              "$DEST/marked.umd.js"
fetch "$BASE/marked-katex-extension@$MKE/lib/index.umd.js"  "$DEST/marked-katex-extension.umd.js"
fetch "$BASE/katex@$KATEX/dist/katex.min.js"                "$DEST/katex.min.js"
fetch "$BASE/dompurify@$PURIFY/dist/purify.min.js"          "$DEST/purify.min.js"

# NO katex.min.css and NO webfonts. The reader asks KaTeX for `output: "mathml"`, so WebKit lays the
# math out itself against the system math font (STIXTwoMath.otf, shipped on both macOS and iOS). That
# stylesheet and its 20 woff2 faces were 80% of everything vendored here, and they existed only to make
# KaTeX's own HTML layout look right in browsers that cannot do MathML. WebKit can.

printf 'marked %s\nmarked-katex-extension %s\nkatex %s\ndompurify %s\n' \
  "$MARKED" "$MKE" "$KATEX" "$PURIFY" > "$DEST/VERSIONS.txt"
( cd "$DEST" && shasum -a 256 ./*.js > SHA256SUMS )

echo
echo "total: $(du -sh "$DEST" | cut -f1)"
echo "checksums: $DEST/SHA256SUMS (verified by DocumentReaderBundleTests)"
