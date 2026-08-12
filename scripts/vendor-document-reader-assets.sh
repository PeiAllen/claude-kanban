#!/bin/bash
# Vendor the document reader's JS/CSS/fonts into the OrchestraUI resource bundle.
#
# Re-runnable, and it pins exact versions so the vendored tree is reproducible. NETWORK IS REQUIRED,
# so run this UNSANDBOXED. The output is COMMITTED — the app never fetches anything at runtime, which
# is what makes the reader work offline on a phone.
#
# Fonts: woff2 ONLY. Every @font-face in katex.min.css lists woff2 first, so a browser that supports
# woff2 (WebKit does) never requests the woff/ttf siblings. All three formats would cost ~1.1 MB
# instead of ~254 KB.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=Sources/OrchestraUI/Resources/DocumentReader/vendor
MARKED=18.0.9
MKE=5.1.10
KATEX=0.18.4
PURIFY=3.4.13
BASE=https://cdn.jsdelivr.net/npm

rm -rf "$DEST"
mkdir -p "$DEST/fonts"

fetch() { curl -fsSL --retry 3 --max-time 60 "$1" -o "$2"; echo "  $(basename "$2") $(wc -c <"$2" | tr -d ' ') B"; }

echo "vendoring:"
fetch "$BASE/marked@$MARKED/lib/marked.umd.js"              "$DEST/marked.umd.js"
fetch "$BASE/marked-katex-extension@$MKE/lib/index.umd.js"  "$DEST/marked-katex-extension.umd.js"
fetch "$BASE/katex@$KATEX/dist/katex.min.js"                "$DEST/katex.min.js"
fetch "$BASE/katex@$KATEX/dist/katex.min.css"               "$DEST/katex.min.css"
fetch "$BASE/dompurify@$PURIFY/dist/purify.min.js"          "$DEST/purify.min.js"

# The 20 woff2 families, read out of the CSS we just fetched so the list can never drift from it.
grep -o 'fonts/KaTeX_[A-Za-z0-9-]*\.woff2' "$DEST/katex.min.css" | sed 's|fonts/||' | sort -u |
while read -r f; do fetch "$BASE/katex@$KATEX/dist/fonts/$f" "$DEST/fonts/$f"; done

printf 'marked %s\nmarked-katex-extension %s\nkatex %s\ndompurify %s\n' \
  "$MARKED" "$MKE" "$KATEX" "$PURIFY" > "$DEST/VERSIONS.txt"

echo
echo "fonts: $(find "$DEST/fonts" -name '*.woff2' | wc -l | tr -d ' ')"
echo "total: $(du -sh "$DEST" | cut -f1)"
