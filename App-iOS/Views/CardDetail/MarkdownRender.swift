import SwiftUI
import OrchestraUI

// A small, dependency-free markdown renderer for the phone's **Notes page** (M6). The notes a branch
// touches are ordinary markdown; there's no Obsidian on the phone, so we render them in-app. SwiftUI's
// `AttributedString(markdown:)` only handles *inline* syntax (bold/italic/code/links) — it flattens block
// structure — so we parse blocks ourselves (headings, lists, fenced code, blockquotes, thematic breaks,
// paragraphs) and delegate inline spans within each block to `AttributedString`. Deliberately not a full
// CommonMark engine: it covers what design §3 calls for (headings, lists, inline + fenced code,
// blockquotes) and degrades gracefully — anything it doesn't recognise renders as plain paragraph text.

// MARK: - Block model

enum MarkdownBlock: Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    case quote(String)
    case list(ListBlock)
    case thematicBreak

    // Stable-enough id for ForEach: index is prepended by the renderer.
    var id: String {
        switch self {
        case .heading(let l, let t): return "h\(l):\(t)"
        case .paragraph(let t):      return "p:\(t)"
        case .code(_, let c):        return "c:\(c.prefix(24))"
        case .quote(let t):          return "q:\(t)"
        case .list(let b):           return "l:\(b.items.count):\(b.items.first?.text ?? "")"
        case .thematicBreak:         return "hr"
        }
    }
}

struct ListBlock {
    struct Item { let ordered: Bool; let marker: String; let text: String; let indent: Int }
    let items: [Item]
}

// MARK: - Parser

enum MarkdownParser {
    static func blocks(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var para: [String] = []
        func flushPara() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block: ``` or ~~~, optional language, until the matching fence (or EOF).
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushPara()
                let fence = String(trimmed.prefix(3))
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { i += 1; break }
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { flushPara(); i += 1; continue }

            if let h = heading(trimmed) { flushPara(); blocks.append(.heading(level: h.0, text: h.1)); i += 1; continue }

            if isThematicBreak(trimmed) { flushPara(); blocks.append(.thematicBreak); i += 1; continue }

            // Blockquote: gather consecutive `>`-prefixed lines.
            if trimmed.hasPrefix(">") {
                flushPara()
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            // List: gather consecutive list-marker lines.
            if listMarker(line) != nil {
                flushPara()
                var items: [ListBlock.Item] = []
                while i < lines.count, let m = listMarker(lines[i]) {
                    items.append(m); i += 1
                }
                blocks.append(.list(ListBlock(items: items)))
                continue
            }

            para.append(trimmed)
            i += 1
        }
        flushPara()
        return blocks
    }

    private static func heading(_ trimmed: String) -> (Int, String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" })
        let level = hashes.count
        guard level >= 1, level <= 6 else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " || rest.isEmpty else { return nil }  // `#foo` is not a heading
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isThematicBreak(_ t: String) -> Bool {
        let stripped = t.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    /// Recognises `- `, `* `, `+ ` (unordered) and `1. ` / `1) ` (ordered), with leading-space indent.
    private static func listMarker(_ line: String) -> ListBlock.Item? {
        let leading = line.prefix { $0 == " " }.count
        let body = line.dropFirst(leading)
        let indent = leading / 2

        if let first = body.first, "-*+".contains(first) {
            let after = body.dropFirst()
            guard after.first == " " else { return nil }
            return ListBlock.Item(ordered: false, marker: "•",
                                  text: after.trimmingCharacters(in: .whitespaces), indent: indent)
        }
        // Ordered: digits then `.` or `)` then a space.
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty {
            let after = body.dropFirst(digits.count)
            if let sep = after.first, sep == "." || sep == ")" {
                let rest = after.dropFirst()
                guard rest.first == " " else { return nil }
                return ListBlock.Item(ordered: true, marker: "\(digits).",
                                      text: rest.trimmingCharacters(in: .whitespaces), indent: indent)
            }
        }
        return nil
    }
}

// MARK: - Inline rendering

enum MarkdownInline {
    /// Parse a string's *inline* markdown (bold/italic/code/links) into an `AttributedString`, tinting
    /// inline code so it reads as code. Block syntax is preserved as literal text by the inline-only option.
    static func attributed(_ s: String, base: Color, code: Color) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attr = try? AttributedString(markdown: s, options: opts) else {
            return AttributedString(s)
        }
        attr.foregroundColor = base
        for run in attr.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attr[run.range].foregroundColor = code
        }
        return attr
    }
}

// MARK: - View

/// Renders parsed markdown blocks with the app theme. Used by the Notes page (M6); kept generic so it can
/// render any markdown string.
struct MarkdownView: View {
    let markdown: String
    @Environment(\.theme) private var theme: Theme

    private var blocks: [MarkdownBlock] { MarkdownParser.blocks(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text): heading(level, text)
        case .paragraph(let text):          inline(text).font(.callout)
        case .code(let lang, let code):     codeBlock(lang, code)
        case .quote(let text):              quote(text)
        case .list(let list):               listView(list)
        case .thematicBreak:                Divider().overlay(theme.hair).padding(.vertical, 2)
        }
    }

    private func inline(_ s: String) -> Text {
        Text(MarkdownInline.attributed(s, base: theme.text2, code: theme.accent))
    }

    private func heading(_ level: Int, _ text: String) -> some View {
        let size: CGFloat = [0, 24, 20, 17, 15, 14, 13][min(level, 6)]
        return Text(MarkdownInline.attributed(text, base: theme.text, code: theme.accent))
            .font(.system(size: size, weight: level <= 2 ? .bold : .semibold))
            .padding(.top, level <= 2 ? 6 : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codeBlock(_ language: String?, _ code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                Text(language)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text3)
                    .padding(.horizontal, 12).padding(.top, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(theme.term)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.termPrompt)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
    }

    private func quote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(theme.accent.opacity(0.5)).frame(width: 3)
            Text(MarkdownInline.attributed(text, base: theme.text3, code: theme.accent))
                .font(.callout.italic())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func listView(_ list: ListBlock) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text(item.marker)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(item.ordered ? theme.text3 : theme.accent)
                        .frame(minWidth: item.ordered ? 20 : 12, alignment: .trailing)
                    inline(item.text).font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.indent) * 16)
            }
        }
    }
}
