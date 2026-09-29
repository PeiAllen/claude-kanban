import SwiftUI
import AppKit
import OrchestraUI
import OrchestraCore

/// Renders one file's diff as TEXT (a single `NSTextView`) instead of as a view per line.
///
/// The per-line-view design this replaces cost ~8.5ms per hit test and ~0.2MB per row, both scaling
/// with diff size — a 2000-row file measured 50.7ms and 645MB. As text the same content measures
/// 0.046ms and ~77MB, flat with diff size, because the content is an attributed string rather than
/// thousands of view objects and their attribute-graph nodes. That also puts the diff view on the
/// same footing as its sibling surfaces: the agent terminal is one `LocalProcessTerminalView` and the
/// document reader is one `WKWebView`.
///
/// Two things the row views gave us are drawn by hand here instead, both bounded to the *visible*
/// line fragments so the cost stays flat:
///   - the full-bleed add/remove band (an attributed `.backgroundColor` only paints behind glyphs);
///   - the line-number gutter, drawn rather than inserted into the text, so copying a diff yields
///     clean code with no line numbers pasted into it.

// MARK: - Palette

/// The `Theme` colours this renderer needs, resolved once into AppKit colours (drawing is AppKit).
/// `Equatable` so `updateNSView` can tell a real theme change from an ordinary re-render.
struct DiffTextPalette: Equatable {
    let code, addText, removeText, gutterText, hunkText: NSColor
    let addTint, removeTint, hunkBand, gutterBg, fillerTint, hair, headerBackground: NSColor

    init(theme: Theme) {
        code = NSColor(theme.term)
        addText = NSColor(theme.green.text)
        removeText = NSColor(theme.red.text)
        gutterText = NSColor(theme.text3)
        hunkText = NSColor(theme.text3)
        addTint = NSColor(theme.green.tint)
        removeTint = NSColor(theme.red.tint)
        hunkBand = NSColor(theme.accent.opacity(theme.dark ? 0.10 : 0.06))
        gutterBg = NSColor(theme.dark ? Color.white.opacity(0.03) : Color.black.opacity(0.025))
        fillerTint = NSColor(theme.termPrompt)
        hair = NSColor(theme.hair)
        headerBackground = NSColor(theme.termPrompt)
    }
}

// MARK: - The text view

/// An `NSTextView` that paints the diff's row bands and line-number gutter itself.
///
/// Both passes run inside `drawBackground(in:)` and enumerate only the line fragments intersecting
/// the dirty rect, so they are O(visible lines) rather than O(diff). The row index for a fragment
/// comes from a binary search over a precomputed table of line-start character offsets.
final class DiffTextView: NSTextView {
    var lines: [DiffTextLine] = []
    /// Character offset at which each line begins, ascending. Same count as `lines`.
    var lineStarts: [Int] = []
    var palette: DiffTextPalette?
    /// Width reserved on the left for the gutter. 0 hides it (the split layout's right-hand column).
    var gutterWidth: CGFloat = 0
    /// Unified shows old AND new numbers; split shows one per side.
    var showsBothNumbers = true
    /// The `contentKey` of the rows currently in the text storage, or nil before the first apply.
    /// `updateNSView` compares against it so an update that changes nothing rebuilds nothing.
    var appliedKey: String?
    /// Kept separately from `appliedKey`: a palette change can redraw existing glyphs without
    /// replacing the attributed string or clearing the user's selection.
    var appliedPalette: DiffTextPalette?

    private static let numberFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    /// Shift the text right by the gutter so drawn numbers never collide with it. `textContainerInset`
    /// would inset symmetrically; overriding the origin insets only the leading edge.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: gutterWidth, y: super.textContainerOrigin.y)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let palette, let lm = layoutManager, let tc = textContainer, !lineStarts.isEmpty else { return }

        if gutterWidth > 0 {
            palette.gutterBg.setFill()
            NSRect(x: 0, y: rect.minY, width: gutterWidth, height: rect.height).fill()
        }

        let originY = textContainerOrigin.y
        let glyphRange = lm.glyphRange(forBoundingRect: rect, in: tc)
        // `fragment` is the FULL line fragment (including leading); `used` is only the glyph-tight
        // rect. Banding by `used` leaves an unpainted gap between consecutive tinted rows, so the
        // band — and the gutter row it shares a baseline with — must use the fragment.
        lm.enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, fragGlyphRange, _ in
            let charIndex = lm.characterIndexForGlyph(at: fragGlyphRange.location)
            guard let idx = self.lineIndex(forCharacter: charIndex) else { return }
            let line = self.lines[idx]
            let y = fragment.origin.y + originY

            // Full-bleed band: the whole view width, not just the glyphs.
            let band: NSColor? = if line.filler { palette.fillerTint } else {
                switch line.kind {
                case .add: palette.addTint
                case .remove: palette.removeTint
                case .hunk: palette.hunkBand
                case .context: nil
                }
            }
            if let band {
                band.setFill()
                NSRect(x: 0, y: y, width: self.bounds.width, height: fragment.height).fill()
            }

            guard self.gutterWidth > 0, line.kind != .hunk else { return }
            self.drawNumbers(line, y: y, height: fragment.height, palette: palette)
        }
    }

    /// Line numbers, right-aligned in their column(s). Drawn, never inserted into the text storage —
    /// that is what keeps them out of copied text and out of the selection.
    private func drawNumbers(_ line: DiffTextLine, y: CGFloat, height: CGFloat, palette: DiffTextPalette) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.numberFont, .foregroundColor: palette.gutterText]
        let columns = showsBothNumbers ? 2 : 1
        let columnWidth = (gutterWidth - 8) / CGFloat(columns)
        let values: [Int?] = showsBothNumbers ? [line.oldNum, line.newNum] : [line.oldNum ?? line.newNum]
        // Centre the number vertically in a line fragment taller than the number's own font.
        let dy = (height - Self.numberFont.boundingRectForFont.height) / 2

        for (col, value) in values.enumerated() {
            guard let value else { continue }
            let s = String(value) as NSString
            let size = s.size(withAttributes: attrs)
            let right = CGFloat(col + 1) * columnWidth
            s.draw(at: NSPoint(x: right - size.width, y: y + dy), withAttributes: attrs)
        }
    }

    /// Index of the line containing `character` — the last line whose start is <= it.
    private func lineIndex(forCharacter character: Int) -> Int? {
        var lo = 0, hi = lineStarts.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= character { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

extension DiffTextView {
    static func makeConfiguredTextView() -> DiffTextView {
        let text = DiffTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: DiffPreparedText.verticalInset)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        let unbounded = CGFloat.greatestFiniteMagnitude
        text.maxSize = NSSize(width: unbounded, height: unbounded)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.size = NSSize(width: unbounded, height: unbounded)
        text.textContainer?.lineFragmentPadding = DiffPreparedText.lineFragmentPadding
        return text
    }

    /// Returns whether string/metadata changed. Geometry and colours are deliberately independent:
    /// reconfiguring an unchanged file must keep both its selection and its already-computed layout.
    @discardableResult
    func apply(document: DiffPreparedText, palette: DiffTextPalette) -> Bool {
        let contentChanged = appliedKey != document.contentKey
        let paletteChanged = appliedPalette != palette
        let geometryChanged = gutterWidth != document.gutterWidth ||
            showsBothNumbers != document.showsBothNumbers

        if contentChanged {
            textStorage?.setAttributedString(document.attributedString(palette: palette))
            lines = document.lines
            lineStarts = document.lineStarts
            appliedKey = document.contentKey
            appliedPalette = palette
        } else if paletteChanged, let storage = textStorage {
            document.applyColors(to: storage, palette: palette)
            appliedPalette = palette
        }

        if geometryChanged {
            gutterWidth = document.gutterWidth
            showsBothNumbers = document.showsBothNumbers
        }
        if contentChanged, let layoutManager, let textContainer {
            // Short unified panes can otherwise paint their bands and gutter before code appears.
            // Materialize this mounted editor's glyphs before its first display.
            layoutManager.ensureLayout(for: textContainer)
        }
        if contentChanged || geometryChanged || paletteChanged {
            self.palette = palette
            needsDisplay = true
        }
        return contentChanged
    }
}

// MARK: - SwiftUI wrapper

/// Hosts a `DiffTextView` for one file (or one side of the split layout).
///
/// The text view is sized to its full content height and never scrolls vertically — the inspector's
/// outer `ScrollView` scrolls the whole file stack, exactly as it did with the row views. `scrollsHorizontally`
/// gives the unified layout its long-line scrolling back; the split layout clips instead, as it always has.
struct DiffTextRenderer: NSViewRepresentable {
    let pane: DiffTextPane
    let palette: DiffTextPalette
    let gutterWidth: CGFloat
    let scrollsHorizontally: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let text = DiffTextView.makeConfiguredTextView()

        let scroll = NSScrollView(frame: .zero)
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = scrollsHorizontally
        scroll.autohidesScrollers = true
        // Vertical wheel events belong to the inspector's outer scroll view, not to this one.
        scroll.verticalScrollElasticity = .none
        apply(to: text)
        return scroll
    }

    /// SwiftUI calls this on EVERY update of the observed model, not only when the diff changed, and
    /// rebuilding the text storage costs a full re-layout of the file and throws the user's selection
    /// away. So re-assert the cheap geometry, and touch the text only when its content or colours
    /// actually differ.
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? DiffTextView else { return }
        scroll.hasHorizontalScroller = scrollsHorizontally
        let document = DiffPreparedText(pane: pane, gutterWidth: gutterWidth)
        _ = text.apply(document: document, palette: palette)
    }

    @MainActor
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let text = nsView.documentView as? DiffTextView,
              let lm = text.layoutManager, let tc = text.textContainer else { return nil }
        lm.ensureLayout(for: tc)
        // Overlay scrollers float above the content, so the horizontal scroller needs no extra band.
        let height = lm.usedRect(for: tc).height + text.textContainerInset.height * 2
        return CGSize(width: proposal.width ?? 0, height: ceil(height))
    }

    private func apply(to text: DiffTextView) {
        text.palette = palette
        _ = text.apply(document: DiffPreparedText(pane: pane, gutterWidth: gutterWidth), palette: palette)
    }
}

extension DiffTextRenderer {
    /// A bitmap of this renderer, for the headless snapshot path (`ORCH_SNAPSHOT_DIFF`).
    ///
    /// `ImageRenderer` cannot lay out an `NSViewRepresentable` — it draws the "unsupported view"
    /// placeholder instead — so the snapshot renders the real `DiffTextView` offscreen and shows the
    /// resulting image. That keeps the screenshot faithful to the SHIPPING renderer, bands and gutter
    /// included, which is the whole point of the headless path.
    @MainActor
    func snapshotImage(width: CGFloat) -> NSImage {
        let text = DiffTextView.makeConfiguredTextView()
        text.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        apply(to: text)

        guard let lm = text.layoutManager, let tc = text.textContainer else { return NSImage(size: .zero) }
        lm.ensureLayout(for: tc)
        let height = ceil(lm.usedRect(for: tc).height) + text.textContainerInset.height * 2
        text.frame = NSRect(x: 0, y: 0, width: width, height: max(height, 1))

        guard let rep = text.bitmapImageRepForCachingDisplay(in: text.bounds) else {
            return NSImage(size: text.bounds.size)
        }
        text.cacheDisplay(in: text.bounds, to: rep)
        let image = NSImage(size: text.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
