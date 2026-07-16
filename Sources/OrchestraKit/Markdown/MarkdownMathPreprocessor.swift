import Foundation

/// Adds the one Markdown extension the shared renderer does not provide: LaTeX math.
///
/// Ordinary Markdown is deliberately left to the GFM renderer used by the clients. Math is
/// represented as an image with a private URL scheme so the renderer can use its normal image
/// loading hook without having to reimplement paragraphs, lists, tables, or inline formatting.
public enum MarkdownMathPreprocessor {
    public static func replacingMath(in markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var output: [String] = []
        var fence: Fence?
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let content = line.hasSuffix("\r") ? String(line.dropLast()) : line

            if let activeFence = fence {
                output.append(line)
                if isFenceClose(content, for: activeFence) {
                    fence = nil
                }
                index += 1
                continue
            }

            if isIndentedCodeLine(content) || isLinkReferenceDefinition(content) {
                output.append(line)
                index += 1
                continue
            }

            if let openedFence = fenceOpen(in: content) {
                output.append(line)
                fence = openedFence
                index += 1
                continue
            }

            if let display = displayMathOnSingleLine(in: content) {
                output.append(mathImage(display.expression, display: true, prefix: leadingWhitespace(of: content)))
                index += 1
                continue
            }

            if let delimiter = displayDelimiter(for: content),
               let end = lines[index...].dropFirst().firstIndex(where: {
                   normalizedLine($0).trimmingCharacters(in: .whitespacesAndNewlines) == delimiter.close
               }) {
                let expression = lines[(index + 1)..<end]
                    .map(normalizedLine)
                    .joined(separator: "\n")
                output.append(mathImage(expression, display: true, prefix: leadingWhitespace(of: content)))
                index = end + 1
                continue
            }

            output.append(transformInlineMath(in: line))
            index += 1
        }

        return output.joined(separator: "\n")
    }

    /// Decodes the private URL emitted by `replacingMath(in:)` for a custom image provider.
    public static func formula(from url: URL) -> (expression: String, display: Bool)? {
        guard url.scheme == "math",
              let host = url.host,
              host == "inline" || host == "display" else {
            return nil
        }

        let encoded = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !encoded.isEmpty else { return nil }
        let base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let expression = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (expression, host == "display")
    }

    private struct Fence {
        let marker: Character
        let length: Int
    }

    private struct DisplayDelimiter {
        let close: String
    }

    private static func normalizedLine(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    private static func fenceOpen(in line: String) -> Fence? {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        guard indentation.count <= 3 else { return nil }
        let rest = line.dropFirst(indentation.count)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        return length >= 3 ? Fence(marker: marker, length: length) : nil
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        line.first == "\t" || line.prefix(while: { $0 == " " }).count >= 4
    }

    private static func isLinkReferenceDefinition(_ line: String) -> Bool {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        guard indentation.count <= 3 else { return false }
        let rest = line.dropFirst(indentation.count)
        guard rest.first == "[",
              let labelEnd = rest.firstIndex(of: "]") else { return false }
        let destination = rest.index(after: labelEnd)
        return destination < rest.endIndex && rest[destination] == ":"
    }

    private static func isFenceClose(_ line: String, for fence: Fence) -> Bool {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        guard indentation.count <= 3 else { return false }
        let rest = line.dropFirst(indentation.count)
        let run = rest.prefix { $0 == fence.marker }
        guard run.count >= fence.length else { return false }
        return rest.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func displayDelimiter(for line: String) -> DisplayDelimiter? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "$$": return .init(close: "$$")
        case "\\[": return .init(close: "\\]")
        default: return nil
        }
    }

    private static func displayMathOnSingleLine(in line: String) -> (expression: String, display: Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
            return (String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces), true)
        }
        if trimmed.hasPrefix("\\["), trimmed.hasSuffix("\\]"), trimmed.count > 4 {
            return (String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces), true)
        }
        return nil
    }

    private static func mathImage(_ expression: String, display: Bool, prefix: String) -> String {
        "\(prefix)![math](\(url(for: expression, display: display)))"
    }

    private static func url(for expression: String, display: Bool) -> String {
        let base64 = Data(expression.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "math://\(display ? "display" : "inline")/\(base64)"
    }

    private static func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private static func transformInlineMath(in line: String) -> String {
        var result = ""
        var index = line.startIndex

        while index < line.endIndex {
            if let linkEnd = markdownLinkEnd(in: line, from: index) {
                result += line[index..<linkEnd]
                index = linkEnd
                continue
            }

            if line[index] == "<", let angleEnd = autolinkEnd(in: line, from: index) {
                result += line[index..<angleEnd]
                index = angleEnd
                continue
            }

            if line[index] == "`" {
                let start = index
                let length = line[index...].prefix { $0 == "`" }.count
                index = line.index(start, offsetBy: length)
                if let close = line.range(of: String(repeating: "`", count: length), range: index..<line.endIndex) {
                    result += line[start..<close.upperBound]
                    index = close.upperBound
                } else {
                    result += line[start...]
                    break
                }
                continue
            }

            if line[index] == "\\", let next = line.index(index, offsetBy: 1, limitedBy: line.index(before: line.endIndex)), line[next] == "(" {
                let expressionStart = line.index(after: next)
                if let close = closingMathDelimiter("\\)", in: line, from: expressionStart) {
                    let expression = String(line[expressionStart..<close.lowerBound])
                    result += "![math](\(url(for: expression, display: false)))"
                    index = close.upperBound
                    continue
                }
            }

            if line[index] == "$",
               !isEscaped(line, at: index),
               line.index(after: index) < line.endIndex,
               line[line.index(after: index)] != "$" {
                let expressionStart = line.index(after: index)
                if let close = closingMathDelimiter("$", in: line, from: expressionStart) {
                    let expression = String(line[expressionStart..<close.lowerBound])
                    if !expression.isEmpty, !expression.contains("\n") {
                        result += "![math](\(url(for: expression, display: false)))"
                        index = close.upperBound
                        continue
                    }
                }
            }

            result.append(line[index])
            index = line.index(after: index)
        }

        return result
    }

    private static func autolinkEnd(in line: String, from start: String.Index) -> String.Index? {
        guard let close = line.range(of: ">", range: start..<line.endIndex) else { return nil }
        let value = line[line.index(after: start)..<close.lowerBound]
        let text = String(value)
        let isURL = text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("ftp://")
        let isEmail = text.hasPrefix("mailto:") ||
            (text.contains("@") && !text.contains(where: { $0.isWhitespace }))
        let isWWW = text.hasPrefix("www.")
        return isURL || isEmail || isWWW ? close.upperBound : nil
    }

    private static func markdownLinkEnd(in line: String, from start: String.Index) -> String.Index? {
        var labelStart = start
        if line[start] == "!" {
            guard line.index(after: start) < line.endIndex,
                  line[line.index(after: start)] == "[" else { return nil }
            labelStart = line.index(after: start)
        }
        guard line[labelStart] == "[",
              let labelEnd = line.range(of: "]", range: labelStart..<line.endIndex)?.lowerBound else {
            return nil
        }

        let destinationStart = line.index(after: labelEnd)
        guard destinationStart < line.endIndex else { return nil }

        if line[destinationStart] == "[" {
            return line.range(of: "]", range: destinationStart..<line.endIndex)?.upperBound
        }

        guard line[destinationStart] == "(" else { return nil }

        var depth = 0
        var cursor = destinationStart
        while cursor < line.endIndex {
            if isEscaped(line, at: cursor) {
                cursor = line.index(after: cursor)
                continue
            }
            switch line[cursor] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return line.index(after: cursor) }
            default: break
            }
            cursor = line.index(after: cursor)
        }
        return nil
    }

    private static func closingMathDelimiter(
        _ delimiter: String,
        in line: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var search = start
        while search < line.endIndex {
            guard let range = line.range(of: delimiter, range: search..<line.endIndex) else { return nil }
            if !isEscaped(line, at: range.lowerBound) {
                return range
            }
            search = range.upperBound
        }
        return nil
    }

    private static func isEscaped(_ line: String, at index: String.Index) -> Bool {
        var count = 0
        var cursor = index
        while cursor > line.startIndex {
            cursor = line.index(before: cursor)
            guard line[cursor] == "\\" else { break }
            count += 1
        }
        return count % 2 == 1
    }
}
