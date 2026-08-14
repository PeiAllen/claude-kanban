"use strict";
//
// HALF OF A CONTRACT. The other half is `MarkdownAssets.add` in Swift.
//
// This file decides which path the PAGE will request for an image. Swift decides which paths the daemon
// will SERVE. A disagreement between them is a silently broken image — never an error, never a log line,
// and invisible until someone opens the right document.
//
// They drifted twice while the rule lived in a comment that said "keep these identical":
//   - percent-encoding: WebKit decodes `url.path` before the scheme handler sees it, so an allowlist
//     holding `my%20image.png` could never match a request for `my image.png`.
//   - scheme detection: `1x:a.png` was a scheme to Swift and a relative path to the page.
//
// So the rule lives HERE, in one function, on its own so it can be executed outside a browser — and
// `Tests/ContractTests/Documents/DocumentPathContractTests.swift` runs this file and the Swift side over
// the SAME vector table. That test is the reason this is a separate file rather than two more functions
// inside reader.js.
//
(function (root) {

  // Collapse `.` and `..`. Mirrors MarkdownAssets.normalize.
  function normalizePath(p) {
    const out = [];
    for (const seg of p.split("/")) {
      if (!seg || seg === ".") continue;
      if (seg === "..") { out.pop(); continue; }
      out.push(seg);
    }
    return out.join("/");
  }

  // Resolve one markdown image source against the document's directory.
  //
  // Returns the worktree-relative path the daemon should be asked for, or null when this is not ours to
  // serve — a remote URL, a `data:` URI, or a protocol-relative `//host/…`. Mirrors MarkdownAssets.add,
  // and the mirroring is checked rather than asserted.
  function resolveOne(src, documentDir) {
    if (typeof src !== "string") return null;
    src = src.trim();
    if (!src || src.startsWith("//")) return null;
    // A scheme must begin with a LETTER (RFC 3986). `1x:a.png` is therefore a file, not a URL — the
    // exact case the two sides once disagreed about.
    if (/^[a-z][a-z0-9+.\-]*:/i.test(src)) return null;
    const cut = src.search(/[?#]/);
    if (cut >= 0) src = src.slice(0, cut);
    try { src = decodeURIComponent(src); } catch (e) { /* malformed escape: use it as written */ }
    if (!src) return null;
    const joined = src.startsWith("/") ? src.slice(1)
                                       : (documentDir ? documentDir + "/" + src : src);
    const path = normalizePath(joined);
    return path || null;
  }

  root.orchestraDocPath = { normalizePath, resolveOne };
  // Present under `node` for the contract test, absent in the page. The page has no module loader, so
  // this is inert there.
  if (typeof module !== "undefined" && module.exports) module.exports = root.orchestraDocPath;

})(typeof globalThis !== "undefined" ? globalThis : this);
