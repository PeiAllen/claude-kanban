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

public struct DiffSplitRow: Identifiable, Equatable, Sendable {
    public let id: Int
    public let old: String?
    public let new: String?
    public let full: String?
    public let tone: DiffTone
}

public enum DiffSplitRows {
    public static func make(_ lines: [String]) -> [DiffSplitRow] {
        var rows: [DiffSplitRow] = []
        var i = 0
        while i < lines.count {
            let plain = ANSIEscape.strip(lines[i])
            if isChange(plain) {
                var old: [String] = []
                var new: [String] = []
                while i < lines.count, isChange(ANSIEscape.strip(lines[i])) {
                    let visible = ANSIEscape.strip(lines[i])
                    if visible.hasPrefix("-") { old.append(lines[i]) } else { new.append(lines[i]) }
                    i += 1
                }
                let count = max(old.count, new.count)
                for j in 0..<count {
                    rows.append(DiffSplitRow(id: rows.count,
                                             old: j < old.count ? old[j] : nil,
                                             new: j < new.count ? new[j] : nil,
                                             full: nil, tone: .change))
                }
            } else {
                let tone = tone(for: plain)
                if tone == .context {
                    rows.append(DiffSplitRow(id: rows.count, old: lines[i], new: lines[i], full: nil, tone: tone))
                } else {
                    rows.append(DiffSplitRow(id: rows.count, old: nil, new: nil, full: lines[i], tone: tone))
                }
                i += 1
            }
        }
        return rows
    }

    private static func isChange(_ line: String) -> Bool {
        (line.hasPrefix("-") && !line.hasPrefix("---")) || (line.hasPrefix("+") && !line.hasPrefix("+++"))
    }

    private static func tone(for line: String) -> DiffTone {
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("diff --git") || line.hasPrefix("index ") ||
            line.hasPrefix("--- ") || line.hasPrefix("+++ ") { return .header }
        return .context
    }
}

public enum DiffTone: Equatable, Sendable {
    case blank, context, header, hunk, change
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
