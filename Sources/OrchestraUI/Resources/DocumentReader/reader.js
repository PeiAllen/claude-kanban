"use strict";
//
// The note reader's page. Swift calls `window.orchestra.render(markdown, opts)`; the page posts a
// SELECTION back and nothing else.
//
// The bridge is deliberately one-way and one-shaped. It reports `{blockIndex, startLine, endLine}` —
// no paths, no content, no requests — because the compose field is native and never needs more. Swift
// then slices the quote from ITS OWN copy of the source, so the worst a compromised page can do is
// misreport which lines the user picked, and the message the user reads stays internally consistent.
//
(function () {
  const NORMALIZE = (s) => s.replace(/\r\n|\r/g, "\n");

  let platform = "mac";
  let blocks = [];          // [{start, end, raw, token, hash}]
  let prevHashes = null;    // multiset of the previous render's block hashes
  let prevDocKey = null;    // which document that multiset describes

  // MathML, not KaTeX's own HTML+CSS layout. WebKit lays math out natively against the system math
  // font (STIXTwoMath.otf, present on both macOS and iOS), so this drops KaTeX's stylesheet and all 20
  // of its webfonts — 80% of the vendored payload — with no loss of quality. KaTeX stays only as the
  // LaTeX parser, which is the part the platform genuinely does not provide.
  marked.use(markedKatex({ throwOnError: false, output: "mathml" }));

  // A tiny non-cryptographic digest. It only has to answer "did this block's text move?", so FNV-1a is
  // the right tool — it is not a security boundary.
  function hash(s) {
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
    return (h >>> 0).toString(36);
  }

  // Rewrite note-relative image sources so they resolve against the NOTE's directory, not the page's.
  // The page lives at `orchestra-doc://doc/index.html`, so a document at `docs/07-app-ui.md` referencing
  // `images/board.png` would otherwise request `<worktree>/images/board.png` instead of
  // `<worktree>/docs/images/board.png`. The usual fix — <base href> — is closed off on purpose by the
  // CSP's `base-uri 'none'`, so rewrite explicitly and keep the CSP intact.
  function resolveAssets(el, documentDir) {
    el.querySelectorAll("img[src]").forEach((img) => {
      // ONE function decides this, shared with the Swift allowlist and checked against it — see
      // docpath.js. Getting it wrong here is a silently broken image, never an error.
      const resolved = orchestraDocPath.resolveOne(img.getAttribute("src") || "", documentDir);
      if (resolved === null) return;          // remote, data:, or protocol-relative — the CSP decides
      // Re-encode so the URL is well-formed; WebKit decodes it again on the way to the handler.
      img.setAttribute("src", "orchestra-doc://doc/" + encodeURI(resolved));
    });
  }

  // Walk top-level tokens, accumulating `raw` length to get each block's 1-based inclusive line range.
  // Concatenated `raw` reconstructs the normalized source exactly, which is what makes this precise.
  // Verified against headings, multi-line lists, fences containing blank lines, tables, and a final
  // paragraph with no trailing newline.
  //
  // Lex ONCE and keep `toks.links`: a link reference definition (`[s]: https://…`) is its own token, so
  // re-parsing each block in isolation renders `[text][s]` elsewhere as literal text.
  function layout(src) {
    const toks = marked.lexer(src);
    const out = [];
    let line = 1;
    for (const t of toks) {
      const raw = t.raw || "";
      const nl = (raw.match(/\n/g) || []).length;
      const trimmedTrailing = (raw.match(/\n+$/) || [""])[0].length;
      const start = line;
      const end = Math.max(start, line + nl - trimmedTrailing);
      line += nl;
      // `space` and `def` tokens still advance `line` (above) but never become blocks: `space` has no
      // content, and `def` renders to the empty string — emitting it would leave an invisible but
      // TAPPABLE empty block in the page.
      if (t.type !== "space" && t.type !== "def") {
        out.push({ start, end, raw, token: t, hash: hash(raw.trim()) });
      }
    }
    return { blocks: out, links: toks.links || {} };
  }

  // Render ONE block's token with the document-wide link definitions attached.
  function renderBlock(b, links) {
    const arr = [b.token];
    arr.links = links;
    return marked.parser(arr);
  }

  // Apply the app's Theme as CSS custom properties. Without this the stylesheet falls back to a
  // near-black default and the reader draws dark text on the app's dark inspector background.
  function applyTheme(theme) {
    if (!theme) return;
    const root = document.documentElement;
    for (const k of Object.keys(theme)) root.style.setProperty("--" + k, theme[k]);
  }

  function render(markdown, opts) {
    opts = opts || {};
    platform = opts.platform || "mac";
    applyTheme(opts.theme);

    // Flash means "this note changed under you", so the baseline is PER NOTE. Without this, switching
    // files diffs the new note against the previous document's hashes and flashes essentially everything.
    const docKey = opts.documentPath || "";
    if (docKey !== prevDocKey) { prevHashes = null; prevDocKey = docKey; }

    const src = NORMALIZE(markdown);
    const laid = layout(src);
    blocks = laid.blocks;

    const host = document.getElementById("doc");

    // Live refresh must NOT throw the reader back to the top: an agent saving every few seconds would
    // make a long note unreadable. Anchor on the topmost block still on screen and restore after the
    // rebuild — an offset alone drifts when block heights change above the viewport.
    let anchor = null;
    for (const el of host.querySelectorAll(".block")) {
      const box = el.getBoundingClientRect();
      if (box.bottom > 0) { anchor = { hash: el.dataset.hash, delta: box.top }; break; }
    }

    host.innerHTML = "";
    const counts = new Map();
    if (prevHashes) for (const [k, v] of prevHashes) counts.set(k, v);

    blocks.forEach((b, i) => {
      const el = document.createElement("div");
      el.className = "block";
      el.dataset.block = String(i);
      el.dataset.lineStart = String(b.start);
      el.dataset.lineEnd = String(b.end);
      el.dataset.hash = b.hash;                 // the scroll anchor survives a rebuild
      el.innerHTML = DOMPurify.sanitize(renderBlock(b, laid.links), {
        ADD_TAGS: ["semantics", "annotation"], ADD_ATTR: ["encoding"],
      });
      resolveAssets(el, opts.documentDir);          // AFTER sanitize, so the sanitizer saw the original
      // Flash only genuinely NEW content. Matching by hash multiset (not by index) means inserting a
      // block flashes just that block instead of everything below it.
      if (prevHashes) {
        const left = counts.get(b.hash) || 0;
        // No timer to take the class off again: every render rebuilds these elements from scratch, so
        // the class only ever rides a fresh one, and the animation has no `forwards` fill to leave
        // behind. Removing it later would have been a no-op on a detached node.
        if (left > 0) counts.set(b.hash, left - 1);
        else el.classList.add("flash");
      }
      host.appendChild(el);
    });

    // Heading ids, so in-document anchors resolve. marked assigns none by default.
    host.querySelectorAll("h1,h2,h3,h4,h5,h6").forEach((h) => {
      if (!h.id) {
        h.id = (h.textContent || "").toLowerCase().trim()
          .replace(/[^\w\s-]/g, "").replace(/\s+/g, "-");
      }
    });

    prevHashes = new Map();
    for (const b of blocks) prevHashes.set(b.hash, (prevHashes.get(b.hash) || 0) + 1);
    document.body.dataset.platform = platform;

    // Restore the reading position against the same block, if it survived the edit.
    if (anchor && anchor.hash) {
      const el = host.querySelector('.block[data-hash="' + anchor.hash + '"]');
      if (el) window.scrollBy(0, el.getBoundingClientRect().top - anchor.delta);
    }
  }

  // The ONLY channel to Swift, and it carries a selection and nothing else.
  function post(msg) {
    if (window.webkit && webkit.messageHandlers && webkit.messageHandlers.orchestraSelection) {
      webkit.messageHandlers.orchestraSelection.postMessage(msg);
    }
  }

  function blockElFrom(node) {
    let n = node && node.nodeType === 3 ? node.parentNode : node;
    while (n && n !== document.body && !(n.dataset && n.dataset.block)) n = n.parentNode;
    return n && n.dataset && n.dataset.block ? n : null;
  }

  function markSelected(lo, hi) {
    document.querySelectorAll(".block.sel").forEach((e) => e.classList.remove("sel"));
    for (let i = lo; i <= hi; i++) {
      const el = document.querySelector('.block[data-block="' + i + '"]');
      if (el) el.classList.add("sel");
    }
  }

  // In-document anchors are handled ENTIRELY here and never reach the navigation delegate, which
  // cancels everything after the initial load.
  document.addEventListener("click", (e) => {
    const a = e.target.closest && e.target.closest("a[href^='#']");
    if (a) {
      e.preventDefault();
      const t = document.getElementById(a.getAttribute("href").slice(1));
      if (t) t.scrollIntoView({ behavior: "smooth", block: "start" });
      return;
    }
    // PHONE: tap a block. Native text interaction is disabled from Swift, so a tap is unambiguous.
    if (platform !== "ios") return;
    const el = blockElFrom(e.target);
    if (!el) return;
    markSelected(+el.dataset.block, +el.dataset.block);
    post({ blockIndex: +el.dataset.block,
           startLine: +el.dataset.lineStart, endLine: +el.dataset.lineEnd });
  });

  // MAC: arbitrary range. Report the START block's first line and the END block's last line, then
  // refine within a single block when the selection can be located UNAMBIGUOUSLY in its source.
  document.addEventListener("mouseup", () => {
    if (platform === "ios") return;
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount) return;
    const a = blockElFrom(sel.anchorNode), b = blockElFrom(sel.focusNode);
    if (!a || !b) return;
    const ia = +a.dataset.block, ib = +b.dataset.block;
    const lo = Math.min(ia, ib), hi = Math.max(ia, ib);
    let startLine = blocks[lo].start, endLine = blocks[hi].end;

    if (lo === hi) {
      // Rendered text and markdown source differ (`**bold**` renders as `bold`, a link renders as its
      // label), so a miss here is common and EXPECTED — the fallback is the whole block, coarse but
      // never wrong.
      //
      // Refine ONLY on a unique match. First-occurrence matching is not safe: in "**same**\nsame",
      // selecting the rendered second "same" finds the copy inside the bold markers on line 1 and
      // would quote the WRONG line. A wrong line is worse than a coarse one, because the user cannot
      // see that it is wrong.
      const text = sel.toString();
      const raw = blocks[lo].raw;
      const first = raw.indexOf(text);
      const unique = first >= 0 && raw.indexOf(text, first + 1) === -1;
      // Refine only over PLAIN markdown. Uniqueness proves the match is the only one in the SOURCE, not
      // that it is the text the user picked, and raw HTML or entities break that premise outright: in
      // `<span title="foo">` + `&#102;oo`, selecting the visible word yields "foo", whose sole raw
      // occurrence is the ATTRIBUTE on the line above. The match is unique and wrong. `<` and `&` are
      // the only two ways source and rendered text can diverge like that, so their absence is the
      // guard — and their presence costs a coarse whole-block anchor, which is the fallback anyway.
      const plain = raw.indexOf("<") === -1 && raw.indexOf("&") === -1;
      if (plain && unique && text.trim()) {
        const before = (raw.slice(0, first).match(/\n/g) || []).length;
        const within = (text.match(/\n/g) || []).length;
        startLine = blocks[lo].start + before;
        endLine = startLine + within;
      }
    }
    // Mark the anchored blocks. The native selection highlight can be dropped when focus moves to the
    // native compose field, and there is deliberately no quote preview — so without this the user
    // could compose against a quote with nothing on screen showing what it is.
    markSelected(lo, hi);
    post({ blockIndex: lo, startLine, endLine });
  });

  window.orchestra = { render };
})();
