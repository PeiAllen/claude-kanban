import AppKit
import OrchestraCore

/// Renderer metadata for one visual diff line. Text storage holds only code and markers; the gutter
/// reads this side table, which keeps copied text free of line numbers.
struct DiffTextLine {
    let kind: DiffRow.Kind
    let oldNum: Int?
    let newNum: Int?
    let filler: Bool
}

private struct DiffTextColorRun {
    let range: NSRange
    let kind: DiffRow.Kind
}

/// Everything a native diff text view needs except its AppKit objects. Building this is proportional
/// to the file's rows, so it happens when a snapshot changes and is never charged to table scrolling.
@MainActor
struct DiffPreparedText {
    static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let verticalInset: CGFloat = 4
    static let lineFragmentPadding: CGFloat = 6

    let contentKey: String
    let string: String
    let lines: [DiffTextLine]
    let lineStarts: [Int]
    let gutterWidth: CGFloat
    let showsBothNumbers: Bool
    private let baseAttributedString: NSAttributedString
    private let colorRuns: [DiffTextColorRun]

    init(pane: DiffTextPane, gutterWidth: CGFloat) {
        contentKey = pane.contentKey
        self.gutterWidth = gutterWidth
        showsBothNumbers = pane.showsBothNumbers

        var pieces: [String] = []
        pieces.reserveCapacity(pane.rows.count)
        var lineMetadata: [DiffTextLine] = []
        var starts: [Int] = []
        var runs: [DiffTextColorRun] = []
        var location = 0

        for row in pane.rows {
            starts.append(location)
            lineMetadata.append(DiffTextLine(kind: row.kind, oldNum: row.oldNum,
                                             newNum: row.newNum, filler: row.filler))
            let body = row.kind == .hunk ? row.text : Self.marker(for: row.kind) + " " + row.text
            let piece = body + "\n"
            let range = NSRange(location: location, length: (piece as NSString).length)
            runs.append(DiffTextColorRun(range: range, kind: row.kind))
            pieces.append(piece)
            location += range.length
        }

        let rendered = pieces.joined()
        string = rendered
        lines = lineMetadata
        lineStarts = starts
        baseAttributedString = NSAttributedString(string: rendered, attributes: [.font: Self.font])
        colorRuns = runs
    }

    func attributedString(palette: DiffTextPalette) -> NSAttributedString {
        let storage = NSMutableAttributedString(attributedString: baseAttributedString)
        applyColors(to: storage, palette: palette)
        return storage
    }

    func unstyledAttributedString() -> NSAttributedString {
        baseAttributedString
    }

    /// Changing text colour does not alter glyph metrics. Keeping it separate from string replacement
    /// lets a palette update redraw visible editors without discarding their selections or remeasuring.
    func applyColors(to storage: NSMutableAttributedString, palette: DiffTextPalette) {
        for run in colorRuns {
            storage.addAttribute(.foregroundColor, value: Self.color(for: run.kind, palette: palette),
                                 range: run.range)
        }
    }

    func applyColors(to storage: NSTextStorage, palette: DiffTextPalette) {
        storage.beginEditing()
        for run in colorRuns {
            storage.addAttribute(.foregroundColor, value: Self.color(for: run.kind, palette: palette),
                                 range: run.range)
        }
        storage.endEditing()
    }

    private static func marker(for kind: DiffRow.Kind) -> String {
        switch kind {
        case .add: return "+"
        case .remove: return "−"
        case .context, .hunk: return " "
        }
    }

    private static func color(for kind: DiffRow.Kind, palette: DiffTextPalette) -> NSColor {
        switch kind {
        case .add: return palette.addText
        case .remove: return palette.removeText
        case .hunk: return palette.hunkText
        case .context: return palette.code
        }
    }
}

/// One temporary TextKit measurement stack for a snapshot rebuild. It uses the exact NSTextView
/// configuration mounted by a row, then the caller discards it after caching plain dimensions.
/// That avoids one layout manager or text view per off-screen file while keeping row heights tied to
/// the actual line fragments AppKit will draw.
@MainActor
final class DiffTextMeasurer {
    private let text = DiffTextView.makeConfiguredTextView()

    func measure(_ document: DiffPreparedText) -> DiffTextMetrics {
        text.textStorage?.setAttributedString(document.unstyledAttributedString())
        text.gutterWidth = document.gutterWidth
        text.showsBothNumbers = document.showsBothNumbers
        guard let layoutManager = text.layoutManager, let container = text.textContainer else {
            return DiffTextMetrics(textHeight: 0, contentWidth: 0)
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return DiffTextMetrics(
            textHeight: ceil(used.height + text.textContainerInset.height * 2),
            contentWidth: ceil(document.gutterWidth + used.maxX + 1)
        )
    }
}

struct DiffTextMetrics {
    let textHeight: CGFloat
    let contentWidth: CGFloat
}
