import Foundation

/// Pure source-text helpers behind the note reader's comment format.
///
/// Everything here works on the NORMALIZED source. `marked` collapses `\r\n` and lone `\r` to `\n`
/// before it tokenizes, so a line number is only meaningful against the same normalization: if Swift
/// counted lines on raw bytes while the page counted on normalized text, every CRLF note would report
/// shifted lines. Swift normalizes once, hands that exact string to the page, and slices excerpts from
/// it — so both sides agree by construction rather than by convention.
public enum MarkdownOutline {

    /// Cap on a quoted excerpt, in characters. A comment quotes an anchor, not a document.
    public static let excerptCap = 500

    public static func normalized(_ source: String) -> String {
        source.replacingOccurrences(of: "\r\n", with: "\n")
              .replacingOccurrences(of: "\r", with: "\n")
    }

    /// The normalized source split into lines. A trailing newline does NOT yield a final empty line,
    /// so line counts match what an editor shows. `Array(...)` is required: `dropLast` returns an
    /// `ArraySlice`, which does not satisfy the `[Substring]` return type.
    public static func lines(_ normalized: String) -> [Substring] {
        guard !normalized.isEmpty else { return [] }
        let parts = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        return Array(normalized.hasSuffix("\n") ? parts.dropLast() : parts[...])
    }

    /// The `> `-prefixed quote for a 1-based inclusive line range, capped. Out-of-range bounds clamp.
    ///
    /// A single markdown line is routinely longer than the cap — a whole paragraph is one line, and so
    /// is a wide table row. So this truncates WITHIN a line rather than only at line boundaries: a
    /// line-boundary-only cut returns a quote containing no quoted text at all for exactly those
    /// inputs, which is the common case rather than the edge.
    public static func excerpt(from normalized: String, startLine: Int, endLine: Int) -> String {
        let all = lines(normalized)
        guard !all.isEmpty else { return "" }
        let lo = max(1, min(startLine, all.count))
        let hi = max(lo, min(endLine, all.count))
        return quote(all[(lo - 1)...(hi - 1)].joined(separator: "\n"))
    }

    /// The `> `-prefixed quote for arbitrary text, capped the same way.
    ///
    /// Split out from `excerpt` so a comment can quote the exact passage the reader selected instead of
    /// the whole source line it fell on. Both paths must produce the same shape, or a comment would
    /// read differently depending on which anchor the page managed to prove.
    public static func quote(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let body = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
        guard body.count > excerptCap else { return body }

        // Budget for the two trailing markers BEFORE cutting, so the finished string honors the cap
        // rather than exceeding it by their length.
        let markers = ["> …", "(excerpt truncated)"]
        let budget = max(4, excerptCap - (markers.joined(separator: "\n").count + 1))
        var kept = String(body.prefix(budget))
        // A cut landing exactly on a newline would leave a blank line above the marker.
        while kept.hasSuffix("\n") { kept.removeLast() }
        // Every quoted line carries the `> ` prefix, including the continuation marker. The trailing
        // note is deliberately unquoted — it is commentary about the quote, not part of it.
        return ([kept] + markers).joined(separator: "\n")
    }

    /// The heading ancestors above `line` (1-based), outermost first.
    ///
    /// ATX only (`## X`). Setext (`X` underlined by `===`/`---`) is deliberately NOT recognized: no
    /// document in this repo uses it, agents write ATX, and supporting it made YAML front matter read as
    /// a heading — so the feature's only effect on real files was a bug plus the code to undo it.
    ///
    /// Fence-aware and indent-aware, following the renderer's rules rather than approximating them: ATX
    /// needs a space after the hashes, four-space indented content is code, and a closing fence must
    /// match the opener's character and be at least as long.
    public static func headingPath(in normalized: String, atLine line: Int) -> [String] {
        var stack: [(level: Int, text: String)] = []
        var inFence = false
        var fenceChar: Character = "`"
        var fenceLen = 0
        let all = lines(normalized)
        let limit = max(0, line - 1)
        var i = 0

        while i < all.count, i < limit {
            let raw = all[i]
            let indent = raw.prefix { $0 == " " }.count
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            defer { i += 1 }

            if inFence {
                // A closing fence must use the SAME character and be AT LEAST as long as the opener,
                // so three backticks do not close a four-backtick fence.
                let run = trimmed.prefix { $0 == fenceChar }.count
                if run >= fenceLen, trimmed.dropFirst(run).allSatisfy({ $0 == " " }) {
                    inFence = false; fenceLen = 0
                }
                continue
            }
            // An indented code block starts at four spaces; its contents are never headings.
            if indent >= 4 { continue }
            if let c = trimmed.first, c == "`" || c == "~" {
                let run = trimmed.prefix { $0 == c }.count
                if run >= 3 { inFence = true; fenceChar = c; fenceLen = run; continue }
            }

            guard trimmed.hasPrefix("#") else { continue }
            let level = trimmed.prefix { $0 == "#" }.count
            guard level <= 6 else { continue }
            let rest = trimmed.dropFirst(level)
            // ATX requires a SPACE after the hashes (or nothing at all). `#notHeading` is a paragraph,
            // and treating it as a heading would put stray text in a comment's `§` clause. Obsidian
            // `#tag` lines make this the common input, not an edge case.
            guard rest.isEmpty || rest.first == " " else { continue }
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }      // a bare `#` run is a rule, not a heading
            while let last = stack.last, last.level >= level { stack.removeLast() }
            stack.append((level, text))
        }
        return stack.map(\.text)
    }
}
