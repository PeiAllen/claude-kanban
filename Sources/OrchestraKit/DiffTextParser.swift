import Foundation

public struct DiffFileSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let lines: [String]
    public let additions: Int
    public let deletions: Int
    public let hunks: Int

    public var text: String { lines.joined(separator: "\n") }
}

public enum DiffFileParser {
    public static func parse(_ text: String) -> [DiffFileSection] {
        guard !text.isEmpty else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sections: [DiffFileSection] = []
        var currentTitle = "Diff"
        var currentLines: [String] = []
        var seenBoundary = false

        func finish() {
            let trimmed = currentLines.drop(while: { ANSIEscape.strip($0).isEmpty })
            guard !trimmed.isEmpty else { currentLines = []; return }
            sections.append(section(title: currentTitle, lines: Array(trimmed), index: sections.count))
            currentLines = []
        }

        for line in lines {
            let plain = ANSIEscape.strip(line)
            if plain.hasPrefix("diff --git ") {
                if seenBoundary { finish() }
                seenBoundary = true
                currentTitle = title(from: plain)
            }
            currentLines.append(line)
        }
        finish()
        return sections.isEmpty ? [section(title: "Diff", lines: lines, index: 0)] : sections
    }

    private static func section(title: String, lines: [String], index: Int) -> DiffFileSection {
        let plain = lines.map(ANSIEscape.strip)
        let additions = plain.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
        let deletions = plain.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        let hunks = plain.filter { $0.hasPrefix("@@") }.count
        return DiffFileSection(id: "\(index)-\(title)", title: title, lines: lines,
                               additions: additions, deletions: deletions, hunks: hunks)
    }

    private static func title(from line: String) -> String {
        if let range = line.range(of: " b/") { return String(line[range.upperBound...]) }
        return line.replacingOccurrences(of: "diff --git ", with: "")
    }
}

// MARK: - Structured line model

/// One rendered line of a diff, resolved to a semantic `kind` with the git `+`/`-`/space prefix
/// stripped off and old/new line numbers computed from the enclosing hunk header. This is what turns
/// raw git patch text into a real diff view: the UI draws its own gutter + marker + row tint instead
/// of echoing terminal output. Redundant metadata (`diff --git`, `index`, `---`, `+++`, mode/rename
/// lines) is dropped — the file header already names the file.
public struct DiffRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, add, remove, hunk }
    public let id: Int
    public let kind: Kind
    /// Line number in the old file (nil for additions and hunk dividers).
    public let oldNum: Int?
    /// Line number in the new file (nil for removals and hunk dividers).
    public let newNum: Int?
    /// Code text with the leading `+`/`-`/space removed. For `.hunk`, the section heading (the text
    /// after the second `@@`, e.g. the enclosing function) — empty when git emits none.
    public let text: String
}

public enum DiffRows {
    public static func make(_ lines: [String]) -> [DiffRow] {
        var rows: [DiffRow] = []
        var oldNum = 0, newNum = 0
        for raw in lines {
            let plain = ANSIEscape.strip(raw)
            if plain.hasPrefix("@@") {
                let hunk = parseHunk(plain)
                oldNum = hunk.oldStart
                newNum = hunk.newStart
                rows.append(DiffRow(id: rows.count, kind: .hunk, oldNum: nil, newNum: nil, text: hunk.heading))
            } else if plain.hasPrefix("+"), !plain.hasPrefix("+++") {
                rows.append(DiffRow(id: rows.count, kind: .add, oldNum: nil, newNum: newNum, text: String(plain.dropFirst())))
                newNum += 1
            } else if plain.hasPrefix("-"), !plain.hasPrefix("---") {
                rows.append(DiffRow(id: rows.count, kind: .remove, oldNum: oldNum, newNum: nil, text: String(plain.dropFirst())))
                oldNum += 1
            } else if isMeta(plain) || plain.isEmpty {
                continue   // git metadata + file-separator blanks: never rendered
            } else {
                // Context line — git prefixes these with a single space (a blank context line is " ").
                let text = plain.hasPrefix(" ") ? String(plain.dropFirst()) : plain
                rows.append(DiffRow(id: rows.count, kind: .context, oldNum: oldNum, newNum: newNum, text: text))
                oldNum += 1
                newNum += 1
            }
        }
        return rows
    }

    private static func isMeta(_ p: String) -> Bool {
        p.hasPrefix("diff --git") || p.hasPrefix("index ") || p.hasPrefix("--- ") || p.hasPrefix("+++ ") ||
        p.hasPrefix("new file") || p.hasPrefix("deleted file") || p.hasPrefix("old mode") ||
        p.hasPrefix("new mode") || p.hasPrefix("similarity") || p.hasPrefix("rename ") ||
        p.hasPrefix("copy ") || p.hasPrefix("\\ ")
    }

    /// Parse `@@ -oldStart,oldLen +newStart,newLen @@ heading` → the two starting line numbers and the
    /// trailing section heading (kept verbatim; empty when absent).
    static func parseHunk(_ p: String) -> (oldStart: Int, newStart: Int, heading: String) {
        let parts = p.components(separatedBy: "@@")
        let spec = parts.count > 1 ? parts[1] : ""
        let heading = parts.count > 2 ? parts[2...].joined(separator: "@@").trimmingCharacters(in: .whitespaces) : ""
        var oldStart = 0, newStart = 0
        for tok in spec.split(separator: " ") {
            if tok.hasPrefix("-") { oldStart = firstInt(tok) }
            if tok.hasPrefix("+") { newStart = firstInt(tok) }
        }
        return (oldStart, newStart, heading)
    }

    /// First run of digits after a leading sign, e.g. `-14,9` → 14.
    private static func firstInt(_ s: Substring) -> Int {
        Int(s.dropFirst().prefix { $0.isNumber }) ?? 0
    }
}

// MARK: - Split (side-by-side) rows

/// A single row of the side-by-side layout: a paired old/new cell (`context`/`change`) or a full-width
/// hunk divider. A `nil` cell text on a `change` row means that side has no counterpart (pure add or
/// pure remove). Derived from `DiffRows` so both layouts share one parse of line numbers + kinds.
public struct DiffSplitRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, change, hunk }
    public let id: Int
    public let kind: Kind
    public let oldNum: Int?
    public let newNum: Int?
    public let oldText: String?
    public let newText: String?
    public let heading: String
}

public enum DiffSplitRows {
    public static func make(_ lines: [String]) -> [DiffSplitRow] {
        make(from: DiffRows.make(lines))
    }

    public static func make(from rows: [DiffRow]) -> [DiffSplitRow] {
        var out: [DiffSplitRow] = []
        var i = 0
        func emit(_ kind: DiffSplitRow.Kind, oldNum: Int? = nil, oldText: String? = nil,
                  newNum: Int? = nil, newText: String? = nil, heading: String = "") {
            out.append(DiffSplitRow(id: out.count, kind: kind, oldNum: oldNum, newNum: newNum,
                                    oldText: oldText, newText: newText, heading: heading))
        }
        while i < rows.count {
            let r = rows[i]
            switch r.kind {
            case .hunk:
                emit(.hunk, heading: r.text)
                i += 1
            case .context:
                emit(.context, oldNum: r.oldNum, oldText: r.text, newNum: r.newNum, newText: r.text)
                i += 1
            case .remove, .add:
                // Gather the run of removals then the run of additions and zip them side by side.
                var rem: [DiffRow] = [], add: [DiffRow] = []
                while i < rows.count, rows[i].kind == .remove { rem.append(rows[i]); i += 1 }
                while i < rows.count, rows[i].kind == .add { add.append(rows[i]); i += 1 }
                for j in 0..<max(rem.count, add.count) {
                    let o = j < rem.count ? rem[j] : nil
                    let n = j < add.count ? add[j] : nil
                    emit(.change, oldNum: o?.oldNum, oldText: o?.text, newNum: n?.newNum, newText: n?.text)
                }
            }
        }
        return out
    }
}

// MARK: - Prepared render model

/// The inspector's two diff layouts. Public because the prepared rows differ per layout.
public enum DiffTextLayout: String, Sendable, CaseIterable { case unified, split }

/// One line as the text renderer needs it — the common shape of a `DiffRow` (unified) and of one side
/// of a `DiffSplitRow` (split), so both layouts drive the same text view.
public struct DiffTextRow: Equatable, Sendable {
    public let kind: DiffRow.Kind
    public let oldNum: Int?
    public let newNum: Int?
    public let text: String
    /// Split layout only: this side of a change has no counterpart (a pure add or pure remove), so it
    /// gets the "nothing here" wash rather than reading as an ordinary context line.
    public let filler: Bool

    public init(kind: DiffRow.Kind, oldNum: Int?, newNum: Int?, text: String, filler: Bool = false) {
        self.kind = kind
        self.oldNum = oldNum
        self.newNum = newNum
        self.text = text
        self.filler = filler
    }

    public init(_ row: DiffRow) {
        self.init(kind: row.kind, oldNum: row.oldNum, newNum: row.newNum, text: row.text)
    }
}

/// The rows for ONE text view — a whole file in the unified layout, one side of it in split.
///
/// `contentKey` is the point of this type. The renderer rebuilds an `NSTextView`'s entire text storage
/// to apply rows, which discards the user's selection and invalidates the file's layout, so it must do
/// that only when the rows actually changed. Comparing the arrays would be O(rows) on every SwiftUI
/// update; comparing the key is O(1), and the key is unique per (load, layout, side, file).
public struct DiffTextPane: Equatable, Sendable {
    public let contentKey: String
    public let rows: [DiffTextRow]
    /// Unified shows old AND new numbers; split shows one per side.
    public let showsBothNumbers: Bool
    /// The widest line number the gutter must fit. Data, not geometry — the view sizes the column.
    public let maxLineNumber: Int
}

/// One file's rows, built for the CURRENT layout.
public struct DiffPreparedFile: Identifiable, Equatable, Sendable {
    public let section: DiffFileSection
    public let body: Body
    public var id: String { section.id }

    public enum Body: Equatable, Sendable {
        case unified(DiffTextPane)
        case split(remove: DiffTextPane, add: DiffTextPane)
    }
}

/// Turns parsed diff sections into renderer-ready rows.
///
/// This runs ONCE per load, and again on a layout change — never inside a SwiftUI `body`. Building
/// rows in `body` re-parses the whole diff on every update pass, so any unrelated republish on the
/// observed model charges the full cost of the diff again.
public enum DiffPrepared {
    /// `generation` distinguishes successive loads of the same file, so reloading changed content
    /// yields a different `contentKey` even though the file id and layout are identical.
    public static func make(_ sections: [DiffFileSection],
                            layout: DiffTextLayout,
                            generation: Int) -> [DiffPreparedFile] {
        sections.map { section in
            let rows = DiffRows.make(section.lines)
            switch layout {
            case .unified:
                let cells = rows.map(DiffTextRow.init)
                return DiffPreparedFile(section: section, body: .unified(
                    pane(cells, key: key(generation, section.id, layout, "u"), showsBothNumbers: true)))
            case .split:
                let split = DiffSplitRows.make(from: rows)
                return DiffPreparedFile(section: section, body: .split(
                    remove: pane(side(split, .remove), key: key(generation, section.id, layout, "l"),
                                 showsBothNumbers: false),
                    add: pane(side(split, .add), key: key(generation, section.id, layout, "r"),
                              showsBothNumbers: false)))
            }
        }
    }

    /// One column of the split layout. A `nil` cell on a `change` row means that side has no
    /// counterpart (a pure add or pure remove), and renders as a blank filler line.
    private static func side(_ rows: [DiffSplitRow], _ side: DiffRow.Kind) -> [DiffTextRow] {
        rows.map { row in
            if row.kind == .hunk {
                return DiffTextRow(kind: .hunk, oldNum: nil, newNum: nil, text: row.heading)
            }
            let text = side == .remove ? row.oldText : row.newText
            let num = side == .remove ? row.oldNum : row.newNum
            let kind: DiffRow.Kind = (row.kind == .change && text != nil) ? side : .context
            return DiffTextRow(kind: kind, oldNum: num, newNum: nil, text: text ?? "",
                               filler: row.kind == .change && text == nil)
        }
    }

    private static func pane(_ rows: [DiffTextRow], key: String, showsBothNumbers: Bool) -> DiffTextPane {
        let widest = rows.reduce(0) { max($0, max($1.oldNum ?? 0, $1.newNum ?? 0)) }
        return DiffTextPane(contentKey: key, rows: rows,
                            showsBothNumbers: showsBothNumbers, maxLineNumber: widest)
    }

    private static func key(_ generation: Int, _ fileId: String,
                            _ layout: DiffTextLayout, _ pane: String) -> String {
        "\(generation)#\(layout.rawValue)#\(pane)#\(fileId)"
    }
}

public enum ANSIEscape {
    public static func strip(_ raw: String) -> String {
        let chars = Array(raw)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
                i += 2
                while i < chars.count, !("@"..."~").contains(chars[i]) { i += 1 }
                i += 1
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }
}
