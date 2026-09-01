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
    let addTint, removeTint, hunkBand, gutterBg, fillerTint: NSColor

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
    }
}

/// One rendered line: what to draw in the gutter, and how to tint the row.
struct DiffTextLine {
    let kind: DiffRow.Kind
    let oldNum: Int?
    let newNum: Int?
    /// Split layout only: this side of a change has no counterpart (a pure add or pure remove), so it
    /// gets the "nothing here" wash rather than reading as an ordinary context line.
    let filler: Bool
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

// MARK: - SwiftUI wrapper

/// Hosts a `DiffTextView` for one file (or one side of the split layout).
///
/// The text view is sized to its full content height and never scrolls vertically — the inspector's
/// outer `ScrollView` scrolls the whole file stack, exactly as it did with the row views. `scrollsHorizontally`
/// gives the unified layout its long-line scrolling back; the split layout clips instead, as it always has.
struct DiffTextRenderer: NSViewRepresentable {
    let rows: [DiffTextRow]
    let palette: DiffTextPalette
    let gutterWidth: CGFloat
    let showsBothNumbers: Bool
    let scrollsHorizontally: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let text = DiffTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        let unbounded = CGFloat.greatestFiniteMagnitude
        text.maxSize = NSSize(width: unbounded, height: unbounded)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.size = NSSize(width: unbounded, height: unbounded)
        text.textContainer?.lineFragmentPadding = 6

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

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? DiffTextView else { return }
        scroll.hasHorizontalScroller = scrollsHorizontally
        apply(to: text)
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
        text.gutterWidth = gutterWidth
        text.showsBothNumbers = showsBothNumbers

        let storage = NSMutableAttributedString()
        var lines: [DiffTextLine] = []
        var starts: [Int] = []
        var offset = 0
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

        for row in rows {
            starts.append(offset)
            lines.append(DiffTextLine(kind: row.kind, oldNum: row.oldNum,
                                      newNum: row.newNum, filler: row.filler))
            let body = row.kind == .hunk ? row.text : marker(row.kind) + " " + row.text
            let piece = (body as NSString).length + 1
            storage.append(NSAttributedString(string: body + "\n", attributes: [
                .font: font,
                .foregroundColor: color(for: row.kind, palette: palette),
            ]))
            offset += piece
        }

        text.textStorage?.setAttributedString(storage)
        text.lines = lines
        text.lineStarts = starts
        text.needsDisplay = true
    }

    private func marker(_ kind: DiffRow.Kind) -> String {
        switch kind {
        case .add: "+"
        case .remove: "\u{2212}"
        default: " "
        }
    }

    private func color(for kind: DiffRow.Kind, palette: DiffTextPalette) -> NSColor {
        switch kind {
        case .add: palette.addText
        case .remove: palette.removeText
        case .hunk: palette.hunkText
        case .context: palette.code
        }
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
        let text = DiffTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.textContainer?.lineFragmentPadding = 6
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                          height: CGFloat.greatestFiniteMagnitude)
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

/// The renderer's input row — the common shape of `DiffRow` (unified) and one side of a
/// `DiffSplitRow` (split), so both layouts drive the same text view.
struct DiffTextRow {
    let kind: DiffRow.Kind
    let oldNum: Int?
    let newNum: Int?
    let text: String
    /// See `DiffTextLine.filler`. Always false in the unified layout, which has no empty cells.
    let filler: Bool

    init(kind: DiffRow.Kind, oldNum: Int?, newNum: Int?, text: String, filler: Bool = false) {
        self.kind = kind
        self.oldNum = oldNum
        self.newNum = newNum
        self.text = text
        self.filler = filler
    }

    init(_ row: DiffRow) {
        self.init(kind: row.kind, oldNum: row.oldNum, newNum: row.newNum, text: row.text)
    }
}
