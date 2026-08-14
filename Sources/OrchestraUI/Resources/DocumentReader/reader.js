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

  // The anchored passages, as SEGMENTS rather than as a block range. One highlight is
  // `{segments: [{index, hash, start, end}]}`, where `start`/`end` are character offsets into that
  // block's RENDERED text. A selection that crosses three blocks is three segments.
  //
  // Offsets over rendered text, not over the markdown source, because that is the only coordinate the
  // page can measure exactly. The source line range stays a separate, coarser answer — see the mouseup
  // handler. Carrying `hash` with each segment is what lets a highlight survive a re-render: the block
  // may move up or down as the agent edits above it, but its text is the same text.
  let highlights = [];

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
    const switchedDocument = docKey !== prevDocKey;
    if (switchedDocument) { prevHashes = null; prevDocKey = docKey; }

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

    // Re-anchor the highlights onto the rebuilt DOM. Every render throws the old elements away, so a
    // highlight that is not re-applied here simply vanishes while the agent is editing — which is the
    // one moment the reviewer most needs to see what they anchored to.
    if (switchedDocument) { highlights = []; lastDetached = ""; lastVisible = null; }
    applyHighlights();
    reportDetached();

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

  function blockEl(i) { return document.querySelector('.block[data-block="' + i + '"]'); }

  // ── highlighting an exact range ───────────────────────────────────────────────────────────────
  //
  // The reader used to tint whole `.block` elements, and a block is one top-level markdown token — so
  // dragging through three words lit up the entire paragraph, the entire list, or the entire table.
  // These functions tint what the user actually picked.

  // Every text node under `el`, in document order. MathML is EXCLUDED: WebKit lays `<math>` out
  // natively, and inserting an HTML span inside it breaks that layout. Math is therefore invisible to
  // both the offset arithmetic and the wrapping, which keeps the two consistent with each other.
  function textNodesIn(el) {
    const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) =>
        n.parentElement && n.parentElement.closest("math")
          ? NodeFilter.FILTER_REJECT
          : NodeFilter.FILTER_ACCEPT,
    });
    const out = [];
    for (let n = walk.nextNode(); n; n = walk.nextNode()) out.push(n);
    return out;
  }

  // Character offset of the boundary (node, offset) within `root`'s text.
  //
  // A selection boundary does NOT always land inside a text node. Drag past the end of an `<em>` and
  // the boundary is an ELEMENT plus a child index. So when the walk never reaches the boundary node,
  // compare positions instead of assuming zero.
  function offsetIn(root, node, offset) {
    const probe = document.createRange();
    try { probe.setStart(node, offset); probe.collapse(true); } catch (e) { return 0; }
    let total = 0;
    for (const t of textNodesIn(root)) {
      if (t === node) return total + offset;
      try {
        // The boundary sits before this text node, so it sits at the count so far.
        if (probe.comparePoint(t, 0) > 0) return total;
      } catch (e) { /* not comparable — keep counting */ }
      total += t.data.length;
    }
    return total;
  }

  // Wrap [start, end) of `el`'s text in `<span class="hl">`. Returns the first span, which is what the
  // rail scrolls to. Wrapping never changes `textContent`, so the offsets stay valid afterwards.
  function wrapSegment(el, start, end, id, active) {
    if (!(end > start)) return null;
    let pos = 0, first = null;
    // Collect the nodes BEFORE mutating. Each wrap splits only the node it touches, so the rest of a
    // pre-collected list stays valid, while a live walker would revisit the pieces it just made.
    for (const t of textNodesIn(el)) {
      const nodeStart = pos;
      pos += t.data.length;
      const a = Math.max(start, nodeStart), b = Math.min(end, pos);
      if (b <= a) continue;
      const r = document.createRange();
      r.setStart(t, a - nodeStart);
      r.setEnd(t, b - nodeStart);
      const span = document.createElement("span");
      span.className = active ? "hl hl-active" : "hl";
      span.dataset.hl = id;
      // The range lies inside ONE text node, so this can only fail on a DOM the sanitizer let through
      // in an unexpected shape. A missing tint is the right failure — never a thrown handler.
      try { r.surroundContents(span); } catch (e) { continue; }
      if (!first) first = span;
    }
    return first;
  }

  // Take every highlight span back out, and re-join the text nodes the wrapping split. Without the
  // `normalize()` a repeated select/clear cycle shatters the text into fragments, which costs nothing
  // visually but makes the offset arithmetic progressively slower.
  function unwrapAll() {
    const spans = document.querySelectorAll("span.hl");
    const parents = new Set();
    spans.forEach((s) => {
      const p = s.parentNode;
      if (!p) return;
      while (s.firstChild) p.insertBefore(s.firstChild, s);
      p.removeChild(s);
      parents.add(p);
    });
    parents.forEach((p) => p.normalize());
  }

  // Find the block a segment now lives in. The fast path is that nothing moved. Otherwise search by
  // hash, claiming matches so two segments cannot both land on the same repeated paragraph.
  function resolveSegment(seg, used) {
    if (blocks[seg.index] && blocks[seg.index].hash === seg.hash) return seg.index;
    for (let i = 0; i < blocks.length; i++) {
      if (blocks[i].hash === seg.hash && !used.has(i)) { used.add(i); return i; }
    }
    return -1;                                   // the agent rewrote this passage
  }

  // Paint every highlight onto the CURRENT DOM. Called after each render, so an anchored passage keeps
  // its tint while the agent edits the document around it.
  function applyHighlights() {
    const used = new Set();
    for (const h of highlights) {
      h.detached = false;
      h.anchor = null;
      for (const seg of h.segments) {
        const i = resolveSegment(seg, used);
        if (i < 0) { h.detached = true; continue; }
        seg.index = i;
        const el = blockEl(i);
        if (!el) { h.detached = true; continue; }
        const span = wrapSegment(el, seg.start, seg.end, h.id, h.active);
        if (span && !h.anchor) h.anchor = span;
      }
    }
    // Document order, so the rail and `reportVisible` both read top to bottom.
    highlights.sort((a, b) => (a.segments[0].index || 0) - (b.segments[0].index || 0));
  }

  // Add a passage and focus it. The PAGE mints the id, because the page is the only side that can hold
  // the segments — Swift never sees a character offset. Swift stores the id on its comment and hands
  // the set back through `setHighlights`, which is how the two stay agreed on what is live.
  let nextHighlightID = 0;

  function addHighlight(segments) {
    const id = "h" + ++nextHighlightID;
    highlights.push({ id: id, segments: segments, active: false });
    focusHighlight(id);
    return id;
  }

  function focusHighlight(id) {
    for (const h of highlights) h.active = h.id === id;
    unwrapAll();
    applyHighlights();
    reportDetached();
  }

  // SWIFT DRIVES THE SET. `keep` is every comment still in the rail, and `active` is the focused one.
  // Deliberately NOT part of the render payload: that would rebuild the DOM and re-lex the whole
  // document every time the reviewer clicked a different card in the rail.
  function setHighlights(opts) {
    opts = opts || {};
    const keep = new Set(opts.keep || []);
    highlights = highlights.filter((h) => keep.has(h.id));
    focusHighlight(opts.active);
  }

  // Tell Swift which anchors the agent has rewritten out from under. Sent only when the set CHANGES,
  // because `applyHighlights` runs on every render and a poll runs every couple of seconds.
  let lastDetached = "";
  function reportDetached() {
    const ids = highlights.filter((h) => h.detached).map((h) => h.id);
    const key = ids.join(",");
    if (key === lastDetached) return;
    lastDetached = key;
    if (ids.length) post({ kind: "detached", ids: ids });
  }

  // Tell Swift which anchor is at the top of the viewport, so the rail can follow the reading position.
  // Throttled, and sent only on a change: this rides the scroll event.
  let lastVisible = null;
  function reportVisible() {
    let top = null;
    for (const h of highlights) {
      if (!h.anchor) continue;
      const box = h.anchor.getBoundingClientRect();
      if (box.bottom > 0) { top = h.id; break; }        // highlights are already in document order
    }
    if (top === lastVisible) return;
    lastVisible = top;
    if (top) post({ kind: "visible", highlight: top });
  }

  let visibleTimer = null;
  window.addEventListener("scroll", () => {
    if (visibleTimer) return;
    visibleTimer = setTimeout(() => { visibleTimer = null; reportVisible(); }, 150);
  }, { passive: true });

  // Turn a DOM Range into per-block segments. A DOM Range is always ordered, so its start container is
  // in the first block and its end container in the last.
  function segmentsFromRange(range) {
    const first = blockElFrom(range.startContainer), last = blockElFrom(range.endContainer);
    if (!first || !last) return null;
    const lo = +first.dataset.block, hi = +last.dataset.block;
    if (!(hi >= lo)) return null;
    const segs = [];
    for (let i = lo; i <= hi; i++) {
      const el = blockEl(i);
      if (!el || !blocks[i]) continue;
      const len = textNodesIn(el).reduce((n, t) => n + t.data.length, 0);
      const start = i === lo ? offsetIn(el, range.startContainer, range.startOffset) : 0;
      const end = i === hi ? offsetIn(el, range.endContainer, range.endOffset) : len;
      // A selection that stops at the very start of a block leaves an empty tail segment. Drop it, or
      // the highlight claims a block it does not actually cover.
      if (end > start) segs.push({ index: i, hash: blocks[i].hash, start: start, end: end });
    }
    return segs.length ? segs : null;
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
    // The anchor is the whole block, expressed as ONE segment covering all of its text — the same
    // machinery the Mac's range uses, so there is only one kind of highlight to reason about.
    //
    // A tap ARMS the offer, exactly as a drag does on the Mac. A tap is easy to make by accident while
    // reading, and the phone's rail is a sheet that would rise over the document to greet it.
    if (platform !== "ios") return;
    if (e.target === commentButton || commentButton.contains(e.target)) return;
    const el = blockElFrom(e.target);
    if (!el) { disarm(); return; }
    const i = +el.dataset.block;
    if (!blocks[i]) { disarm(); return; }
    const len = textNodesIn(el).reduce((n, t) => n + t.data.length, 0);
    arm({ segments: [{ index: i, hash: blocks[i].hash, start: 0, end: len }],
          blockIndex: i,
          startLine: +el.dataset.lineStart, endLine: +el.dataset.lineEnd,
          text: el.textContent },
        el.getBoundingClientRect());
  });

  // ── selecting, then DECIDING to comment ──────────────────────────────────────────────────────
  //
  // Selecting text does NOT create a comment. People drag through text constantly while reading, and a
  // reader that turned every one of those into a card would be unusable. A selection only ARMS the
  // offer: a button appears beside it, and the comment exists once you click that button or press its
  // shortcut. Everything measured at mouseup is held until then, because the DOM must be measured
  // while the selection is still live.
  let pending = null;

  const commentButton = document.createElement("button");
  commentButton.id = "orch-comment-btn";
  commentButton.type = "button";
  commentButton.hidden = true;
  commentButton.append(document.createTextNode("Comment"));
  const shortcutHint = document.createElement("span");
  shortcutHint.className = "key";
  shortcutHint.append(document.createTextNode("⌘⇧M"));
  commentButton.append(shortcutHint);
  document.body.appendChild(commentButton);

  function disarm() {
    pending = null;
    commentButton.hidden = true;
  }

  /// Offer the button at the end of the selection, where the cursor already is.
  function arm(measured, rect) {
    pending = measured;
    // Unhide FIRST: the button has no size while hidden, and its size decides where it fits.
    commentButton.hidden = false;
    const w = commentButton.offsetWidth, h = commentButton.offsetHeight;

    // ABOVE the selection, not below. Below covers the next line — the text you are about to read on
    // your way to deciding whether to comment at all. Falls back to below when the selection is close
    // enough to the top of the document that above would be off the page.
    let top = rect.top + window.scrollY - h - 6;
    if (top < window.scrollY + 2) top = rect.bottom + window.scrollY + 6;
    // Anchor the right edge to the selection's end, then keep it on the page.
    let left = rect.right + window.scrollX - w;
    left = Math.max(4, Math.min(left, document.documentElement.clientWidth - w - 4));

    // CSSOM writes, never a `style` attribute: the page's CSP forbids inline styles, and setting the
    // attribute would be blocked while these property assignments are not. Verified in a real
    // WKWebView under the shipped CSP — the probe read the values back.
    commentButton.style.left = Math.round(left) + "px";
    commentButton.style.top = Math.round(top) + "px";
  }

  // MAC: arbitrary range. Report the START block's first line and the END block's last line, then
  // refine within a single block when the selection can be located UNAMBIGUOUSLY in its source.
  document.addEventListener("mouseup", () => {
    if (platform === "ios") return;
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount) { disarm(); return; }
    const range = sel.getRangeAt(0);
    const text = sel.toString();
    if (!text.trim()) { disarm(); return; }
    const segments = segmentsFromRange(range);
    if (!segments) { disarm(); return; }
    const lo = segments[0].index, hi = segments[segments.length - 1].index;
    if (!blocks[lo] || !blocks[hi]) { disarm(); return; }
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
    // Paint the anchor. WebKit drops the native selection highlight as soon as focus moves to the
    // native compose field, so without this the user would compose against a passage with nothing on
    // screen showing which one it is.
    // ARMED, not committed. Nothing is created and nothing is reported until the offer is taken.
    arm({ segments: segments, blockIndex: lo, startLine: startLine, endLine: endLine, text: text },
        range.getBoundingClientRect());
  });

  /// Take the offer: tint the passage and tell Swift about it.
  function commit() {
    if (!pending) return;
    const p = pending;
    disarm();
    // Re-anchor from the measurement taken while the selection was live. Wrapping mutates the DOM, so
    // any older highlight has to come out first or the offsets shift under it.
    unwrapAll();
    const id = addHighlight(p.segments);
    // `text` is the rendered text the user picked. Swift does NOT trust it: it accepts the string as a
    // quote only after proving the same words occur in its own copy of these lines. See
    // `DocumentComment.capture`. So the bridge still cannot put words in the user's mouth — it can
    // only choose between quoting the exact selection and quoting the whole block.
    post({ kind: "selection", blockIndex: p.blockIndex, highlight: id,
           startLine: p.startLine, endLine: p.endLine, text: p.text.slice(0, 4000) });
    const sel = window.getSelection();
    if (sel) sel.removeAllRanges();                  // the tint replaces it, so two marks never overlap
  }

  commentButton.addEventListener("mousedown", (e) => {
    e.preventDefault();                              // do not let the button steal the selection first
    commit();
  });
  // The phone never sends `mousedown`, and its tap has to beat the document-level handler that would
  // otherwise treat the button as a tap outside a block and retire the offer.
  commentButton.addEventListener("click", (e) => { e.stopPropagation(); commit(); });

  // ⌘⇧M, handled IN THE PAGE. The webview holds first responder while you are selecting in it, so a
  // native SwiftUI shortcut would not fire — and the page already knows what is selected.
  document.addEventListener("keydown", (e) => {
    if (e.metaKey && e.shiftKey && (e.key === "m" || e.key === "M")) {
      e.preventDefault();
      commit();
    } else if (e.key === "Escape") {
      disarm();
    }
  });

  // Any new drag, or a scroll, retires a stale offer — the button must never sit somewhere the
  // selection no longer is.
  document.addEventListener("mousedown", (e) => {
    if (e.target !== commentButton && !commentButton.contains(e.target)) disarm();
  });
  window.addEventListener("scroll", () => { if (pending) disarm(); }, { passive: true });

  // Scroll a passage into view, and flash it. The rail calls this when a comment card is clicked.
  function reveal(id) {
    const h = highlights.find((x) => x.id === id);
    if (h && h.anchor) h.anchor.scrollIntoView({ behavior: "smooth", block: "center" });
  }

  window.orchestra = { render, setHighlights, reveal };
})();
