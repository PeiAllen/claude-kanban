import Foundation

/// The block-level syntax understood by the mobile Notes renderer.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    case quote(String)
    case list(MarkdownList)
    case table(MarkdownTable)
    case math(expression: String, display: Bool)
    case thematicBreak
}

public struct MarkdownList: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let ordered: Bool
        public let marker: String
        public let text: String
        public let indent: Int
        /// `nil` is an ordinary list item, while `false` and `true` are unchecked and checked tasks.
        public let task: Bool?

        public init(ordered: Bool, marker: String, text: String, indent: Int, task: Bool? = nil) {
            self.ordered = ordered
            self.marker = marker
            self.text = text
            self.indent = indent
            self.task = task
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }
}

public enum MarkdownTableAlignment: Equatable, Sendable {
    case none
    case leading
    case center
    case trailing
}

public struct MarkdownTable: Equatable, Sendable {
    public let headers: [String]
    public let rows: [[String]]
    public let alignments: [MarkdownTableAlignment]

    public init(headers: [String], rows: [[String]], alignments: [MarkdownTableAlignment]) {
        self.headers = headers
        self.rows = rows
        self.alignments = alignments
    }
}

public enum MarkdownInlinePart: Equatable, Sendable {
    case text(String)
    case math(String)
    case image(alt: String, url: String)
}

/// A deliberately small, dependency-free GFM parser for the Notes surface.
///
/// It owns only value models and Foundation string processing so the same block/inline behavior can be
/// tested in the SwiftPM unit tier and consumed by the iOS renderer. Unsupported or malformed syntax is
/// retained as source text instead of being interpreted as HTML or silently discarded.
public enum MarkdownParser {
    public static func blocks(_ markdown: String) -> [MarkdownBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var result: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = openingFence(in: line) {
                flushParagraph()
                let openingLine = line
                var codeLines: [String] = []
                var closed = false
                index += 1
                while index < lines.count {
                    if isClosingFence(lines[index], for: fence) {
                        closed = true
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                if closed {
                    result.append(.code(language: fence.language,
                                        code: codeLines.joined(separator: "\n")))
                } else {
                    // An unterminated fence is ordinary source, so a malformed note remains readable.
                    paragraph.append(openingLine)
                    paragraph.append(contentsOf: codeLines)
                }
                continue
            }

            if let display = displayMath(at: index, in: lines) {
                flushParagraph()
                result.append(.math(expression: display.expression, display: true))
                index = display.nextIndex
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let table = table(at: index, in: lines) {
                flushParagraph()
                result.append(.table(table.value))
                index = table.nextIndex
                continue
            }

            if let heading = heading(at: index, in: lines) {
                flushParagraph()
                result.append(.heading(level: heading.level, text: heading.text))
                index = heading.nextIndex
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                result.append(.thematicBreak)
                index += 1
                continue
            }

            if quoteText(in: line) != nil {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count, let quote = quoteText(in: lines[index]) {
                    quoteLines.append(quote)
                    index += 1
                }
                result.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if let item = listItem(in: line) {
                flushParagraph()
                var items: [MarkdownList.Item] = [item]
                index += 1
                while index < lines.count, let nextItem = listItem(in: lines[index]) {
                    items.append(nextItem)
                    index += 1
                }
                result.append(.list(MarkdownList(items: items)))
                continue
            }

            // Keep two-space hard-break source and inline syntax intact. Leading indentation is not
            // meaningful once a line is inside a paragraph, so only leading spaces are removed.
            paragraph.append(line.drop(while: { $0 == " " || $0 == "\t" }).description)
            index += 1
        }

        flushParagraph()
        return result
    }

    public static func inlineParts(_ text: String) -> [MarkdownInlinePart] {
        var parts: [MarkdownInlinePart] = []
        var textStart = text.startIndex
        var index = text.startIndex

        func appendText(_ value: String) {
            guard !value.isEmpty else { return }
            if let last = parts.last, case .text(let previous) = last {
                parts[parts.count - 1] = .text(previous + value)
            } else {
                parts.append(.text(value))
            }
        }

        func flushText(before end: String.Index) {
            guard textStart < end else { return }
            appendText(String(text[textStart..<end]))
        }

        while index < text.endIndex {
            let character = text[index]

            // Backtick spans are opaque: dollars, image-looking text, and links inside code are all
            // ordinary source for the inline flow.
            if character == "`" {
                let runLength = backtickRun(at: index, in: text)
                let afterOpening = advance(index, by: runLength, in: text)
                if let closing = closingBacktickRun(in: text, from: afterOpening, length: runLength) {
                    let end = advance(closing, by: runLength, in: text)
                    flushText(before: index)
                    appendText(String(text[index..<end]))
                    index = end
                    textStart = index
                    continue
                }
            }

            if character == "!", let image = image(at: index, in: text) {
                flushText(before: index)
                parts.append(.image(alt: image.alt, url: image.url))
                index = image.nextIndex
                textStart = index
                continue
            }

            if character == "$", !isEscaped(at: index, in: text),
               text.index(after: index) < text.endIndex,
               text[text.index(after: index)] != "$",
               let closing = closingDollar(in: text, from: text.index(after: index)) {
                let expression = String(text[text.index(after: index)..<closing])
                if !expression.isEmpty, !expression.contains("\n"), !expression.trimmingCharacters(in: .whitespaces).isEmpty {
                    let end = text.index(after: closing)
                    flushText(before: index)
                    parts.append(.math(expression))
                    index = end
                    textStart = index
                    continue
                }
            }

            if character == "\\", let next = nextCharacter(after: index, in: text), next == "(" {
                let expressionStart = text.index(index, offsetBy: 2)
                if let closing = closingDelimiter("\\)", in: text, from: expressionStart) {
                    let expression = String(text[expressionStart..<closing])
                    if !expression.isEmpty, !expression.contains("\n") {
                        let end = text.index(closing, offsetBy: 2)
                        flushText(before: index)
                        parts.append(.math(expression))
                        index = end
                        textStart = index
                        continue
                    }
                }
            }

            index = text.index(after: index)
        }

        flushText(before: text.endIndex)
        return parts.isEmpty ? [.text(text)] : parts
    }

    private struct Fence {
        let marker: Character
        let length: Int
        let language: String?
    }

    private struct DisplayMath {
        let expression: String
        let nextIndex: Int
    }

    private struct ParsedTable {
        let value: MarkdownTable
        let nextIndex: Int
    }

    private struct ParsedHeading {
        let level: Int
        let text: String
        let nextIndex: Int
    }

    private struct ParsedImage {
        let alt: String
        let url: String
        let nextIndex: String.Index
    }

    private static func openingFence(in line: String) -> Fence? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }.count
        guard leading <= 3 else { return nil }
        let body = line.dropFirst(leading)
        guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let run = body.prefix(while: { $0 == marker }).count
        guard run >= 3 else { return nil }
        let info = body.dropFirst(run).trimmingCharacters(in: .whitespaces)
        guard marker != "`" || !info.contains("`") else { return nil }
        return Fence(marker: marker, length: run, language: info.isEmpty ? nil : info)
    }

    private static func isClosingFence(_ line: String, for fence: Fence) -> Bool {
        let leading = line.prefix { $0 == " " || $0 == "\t" }.count
        guard leading <= 3 else { return false }
        let body = line.dropFirst(leading)
        let run = body.prefix(while: { $0 == fence.marker }).count
        guard run >= fence.length else { return false }
        return body.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func displayMath(at index: Int, in lines: [String]) -> DisplayMath? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

        if trimmed == "$$" {
            var cursor = index + 1
            while cursor < lines.count {
                if lines[cursor].trimmingCharacters(in: .whitespaces) == "$$" {
                    let expression = lines[(index + 1)..<cursor].joined(separator: "\n")
                    guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return DisplayMath(expression: expression, nextIndex: cursor + 1)
                }
                cursor += 1
            }
            return nil
        }

        if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
            let expression = String(trimmed.dropFirst(2).dropLast(2))
            guard !expression.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return DisplayMath(expression: expression, nextIndex: index + 1)
        }

        if trimmed == "\\[" {
            var cursor = index + 1
            while cursor < lines.count {
                if lines[cursor].trimmingCharacters(in: .whitespaces) == "\\]" {
                    let expression = lines[(index + 1)..<cursor].joined(separator: "\n")
                    guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return DisplayMath(expression: expression, nextIndex: cursor + 1)
                }
                cursor += 1
            }
            return nil
        }

        if trimmed.hasPrefix("\\["), trimmed.hasSuffix("\\]"), trimmed.count > 4 {
            let expression = String(trimmed.dropFirst(2).dropLast(2))
            guard !expression.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return DisplayMath(expression: expression, nextIndex: index + 1)
        }

        return nil
    }

    private static func heading(at index: Int, in lines: [String]) -> ParsedHeading? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        if let atx = atxHeading(trimmed) {
            return ParsedHeading(level: atx.level, text: atx.text, nextIndex: index + 1)
        }

        guard index + 1 < lines.count,
              !trimmed.isEmpty,
              let level = setextLevel(lines[index + 1]) else { return nil }
        return ParsedHeading(level: level, text: trimmed, nextIndex: index + 2)
    }

    private static func atxHeading(_ trimmed: String) -> (level: Int, text: String)? {
        guard trimmed.first == "#" else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        var suffixStart = text.endIndex
        while suffixStart > text.startIndex, text[text.index(before: suffixStart)] == "#" {
            suffixStart = text.index(before: suffixStart)
        }
        if suffixStart < text.endIndex, suffixStart > text.startIndex,
           let separator = text.index(suffixStart, offsetBy: -1, limitedBy: text.startIndex),
           text[separator] == " " || text[separator] == "\t" {
            text = text[..<separator].trimmingCharacters(in: .whitespaces)
        }
        return (hashes.count, text)
    }

    private static func setextLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 1 else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func isThematicBreak(_ text: String) -> Bool {
        let stripped = text.filter { $0 != " " && $0 != "\t" }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    private static func quoteText(in line: String) -> String? {
        let leading = line.drop(while: { $0 == " " || $0 == "\t" })
        guard leading.first == ">" else { return nil }
        return leading.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    private static func listItem(in line: String) -> MarkdownList.Item? {
        let leadingCount = line.prefix { $0 == " " || $0 == "\t" }.reduce(into: 0) { count, character in
            count += character == "\t" ? 4 : 1
        }
        let body = line.dropFirst(line.prefix { $0 == " " || $0 == "\t" }.count)
        let indent = leadingCount / 2
        var ordered = false
        var marker = "•"
        var content: Substring

        if let first = body.first, "-*+".contains(first),
           let after = body.dropFirst().first, after == " " || after == "\t" {
            content = body.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        } else {
            let digits = body.prefix(while: { $0.isNumber })
            guard !digits.isEmpty else { return nil }
            let afterDigits = body.dropFirst(digits.count)
            guard let separator = afterDigits.first, separator == "." || separator == ")" else { return nil }
            let afterMarker = afterDigits.dropFirst()
            guard let whitespace = afterMarker.first, whitespace == " " || whitespace == "\t" else { return nil }
            ordered = true
            marker = "\(digits)."
            content = afterMarker.drop(while: { $0 == " " || $0 == "\t" })
        }

        var task: Bool?
        if content.hasPrefix("[ ]") || content.hasPrefix("[x]") || content.hasPrefix("[X]") {
            let checked = content.dropFirst(1).first == "x" || content.dropFirst(1).first == "X"
            let remainder = content.dropFirst(3)
            guard remainder.isEmpty || remainder.first == " " || remainder.first == "\t" else {
                task = nil
                return MarkdownList.Item(ordered: ordered, marker: marker,
                                         text: content.trimmingCharacters(in: .whitespaces), indent: indent, task: task)
            }
            task = checked
            content = remainder.drop(while: { $0 == " " || $0 == "\t" })
        } else {
            task = nil
        }

        return MarkdownList.Item(ordered: ordered, marker: marker,
                                 text: content.trimmingCharacters(in: .whitespaces), indent: indent, task: task)
    }

    private static func table(at index: Int, in lines: [String]) -> ParsedTable? {
        guard index + 1 < lines.count,
              let headers = tableCells(in: lines[index]),
              let delimiter = tableCells(in: lines[index + 1]),
              headers.count == delimiter.count,
              !headers.isEmpty,
              let alignments = delimiter.compactMap(tableAlignment).nilIfCountDiffers(from: delimiter.count)
        else { return nil }

        var rows: [[String]] = []
        var nextIndex = index + 2
        while nextIndex < lines.count,
              !lines[nextIndex].trimmingCharacters(in: .whitespaces).isEmpty,
              let row = tableCells(in: lines[nextIndex]),
              row.count > 0 {
            var normalized = Array(row.prefix(headers.count))
            if normalized.count < headers.count {
                normalized.append(contentsOf: repeatElement("", count: headers.count - normalized.count))
            }
            rows.append(normalized)
            nextIndex += 1
        }

        return ParsedTable(value: MarkdownTable(headers: headers, rows: rows, alignments: alignments),
                           nextIndex: nextIndex)
    }

    private static func tableCells(in line: String) -> [String]? {
        guard let rawCells = splitTableRow(line) else { return nil }
        var cells = rawCells.map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func tableAlignment(_ cell: String) -> MarkdownTableAlignment? {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let leading = trimmed.first == ":"
        let trailing = trimmed.last == ":"
        let start = leading ? trimmed.index(after: trimmed.startIndex) : trimmed.startIndex
        let end = trailing ? trimmed.index(before: trimmed.endIndex) : trimmed.endIndex
        let dashes = trimmed[start..<end]
        guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        if leading && trailing { return .center }
        if leading { return .leading }
        if trailing { return .trailing }
        return MarkdownTableAlignment.none
    }

    private static func splitTableRow(_ line: String) -> [String]? {
        var cells: [String] = []
        var current = ""
        var index = line.startIndex
        var codeTicks = 0
        var hasPipe = false

        while index < line.endIndex {
            let character = line[index]
            if character == "\\" {
                current.append(character)
                index = line.index(after: index)
                if index < line.endIndex {
                    current.append(line[index])
                    index = line.index(after: index)
                }
                continue
            }
            if character == "`" {
                let run = backtickRun(at: index, in: line)
                current.append(contentsOf: line[index..<advance(index, by: run, in: line)])
                if codeTicks == 0 {
                    codeTicks = run
                } else if codeTicks == run {
                    codeTicks = 0
                }
                index = advance(index, by: run, in: line)
                continue
            }
            if character == "|", codeTicks == 0 {
                hasPipe = true
                cells.append(current.replacingOccurrences(of: "\\|", with: "|"))
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }

        guard hasPipe else { return nil }
        cells.append(current.replacingOccurrences(of: "\\|", with: "|"))
        return cells
    }

    private static func image(at index: String.Index, in text: String) -> ParsedImage? {
        guard text[index] == "!",
              let openBracket = nextIndex(after: index, in: text), text[openBracket] == "[",
              let closeBracket = firstIndex(of: "]", in: text, from: text.index(after: openBracket)),
              let openParenthesis = nextIndex(after: closeBracket, in: text), text[openParenthesis] == "(",
              let closeParenthesis = closingParenthesis(in: text, from: text.index(after: openParenthesis))
        else { return nil }

        let alt = String(text[text.index(after: openBracket)..<closeBracket])
        let url = String(text[text.index(after: openParenthesis)..<closeParenthesis])
            .trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return nil }
        return ParsedImage(alt: alt, url: url, nextIndex: text.index(after: closeParenthesis))
    }

    private static func closingParenthesis(in text: String, from start: String.Index) -> String.Index? {
        var index = start
        var depth = 0
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                index = text.index(after: index)
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" {
                if depth == 0 { return index }
                depth -= 1
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func closingDollar(in text: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(after: index)
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            if text[index] == "$" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] != "$" { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func closingDelimiter(_ delimiter: String, in text: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < text.endIndex {
            if text[index...].hasPrefix(delimiter) { return index }
            index = text.index(after: index)
        }
        return nil
    }

    private static func closingBacktickRun(in text: String, from start: String.Index, length: Int) -> String.Index? {
        var index = start
        while index < text.endIndex {
            if text[index] == "`", backtickRun(at: index, in: text) == length { return index }
            index = text.index(after: index)
        }
        return nil
    }

    private static func backtickRun(at index: String.Index, in text: String) -> Int {
        var cursor = index
        var count = 0
        while cursor < text.endIndex, text[cursor] == "`" {
            count += 1
            cursor = text.index(after: cursor)
        }
        return count
    }

    private static func isEscaped(at index: String.Index, in text: String) -> Bool {
        var cursor = index
        var backslashes = 0
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            guard text[cursor] == "\\" else { break }
            backslashes += 1
        }
        return backslashes % 2 == 1
    }

    private static func advance(_ index: String.Index, by count: Int, in text: String) -> String.Index {
        var cursor = index
        for _ in 0..<count where cursor < text.endIndex {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private static func nextIndex(after index: String.Index, in text: String) -> String.Index? {
        let next = text.index(after: index)
        return next < text.endIndex ? next : nil
    }

    private static func nextCharacter(after index: String.Index, in text: String) -> Character? {
        nextIndex(after: index, in: text).map { text[$0] }
    }

    private static func firstIndex(of character: Character, in text: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < text.endIndex {
            if text[index] == character { return index }
            index = text.index(after: index)
        }
        return nil
    }
}

private extension Array {
    func nilIfCountDiffers(from count: Int) -> [Element]? {
        self.count == count ? self : nil
    }
}
