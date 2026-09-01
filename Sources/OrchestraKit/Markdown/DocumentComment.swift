import Foundation

/// One reader comment, frozen at SELECTION time.
///
/// The excerpt and the heading path are captured from the source as it read when the user selected —
/// not re-derived at send time — because live refresh is paused while the compose field is open and the
/// file may move underneath. A quote stays a valid anchor even when line numbers shift, which is why it
/// is sent AS CAPTURED.
///
/// There is deliberately NO trailing instruction line. A review comment carries no meta-instruction:
/// the human writes the remark, and the author decides whether to answer, to edit, or both. An
/// instruction like "address this in the document" forces one response mode, and for a question comment
/// it makes the document messy.
public struct DocumentComment: Equatable, Sendable {
    /// Relative to the card's working directory, exactly as `DocRef.path` gives it.
    public let path: String
    /// 1-based and inclusive. `nil` omits the `:a-b` suffix.
    public let startLine: Int?
    public let endLine: Int?
    /// Ancestor headings, outermost first. Empty omits the whole `§ …` clause.
    public let headingPath: [String]
    /// Already `> `-prefixed and capped.
    public let excerpt: String

    public init(path: String, startLine: Int?, endLine: Int?,
                headingPath: [String], excerpt: String) {
        self.path = path; self.startLine = startLine; self.endLine = endLine
        self.headingPath = headingPath; self.excerpt = excerpt
    }

    /// Freeze a comment against `source`. `source` may be raw file text — it is normalized here, so no
    /// caller has to remember to do it.
    ///
    /// `selectedText` is the RENDERED text the reader page says the user dragged through, and it is
    /// untrusted. It is used only when `verifiedQuote` proves the same words occur in `source` at these
    /// lines. When it cannot be proved, the quote falls back to the whole source line range.
    public static func capture(path: String, source: String,
                               startLine: Int, endLine: Int,
                               selectedText: String? = nil) -> DocumentComment {
        let norm = MarkdownOutline.normalized(source)
        let exact = selectedText.flatMap {
            verifiedQuote($0, within: norm, startLine: startLine, endLine: endLine)
        }
        return DocumentComment(
            path: path,
            startLine: startLine,
            endLine: endLine,
            headingPath: MarkdownOutline.headingPath(in: norm, atLine: startLine),
            excerpt: exact
                ?? MarkdownOutline.excerpt(from: norm, startLine: startLine, endLine: endLine))
    }

    /// Accept the page's selected text as the quote, but only if the same words really are in the file.
    ///
    /// WHY A CHECK AT ALL. The page renders untrusted content, so the bridge's rule has always been that
    /// the worst a compromised page can do is misreport WHICH lines the user picked — never put words in
    /// the message. Quoting a string the page sent would break that rule outright. This restores it: the
    /// page may choose between quoting the exact selection and quoting the whole block, and nothing else.
    ///
    /// HOW. Compare the letter-and-digit runs of both, and require the selection's runs to appear as a
    /// CONTIGUOUS run of the source's. Rendered text and markdown source differ in punctuation and
    /// markers but not in words, so `**poll**, not` matches the rendered `poll, not`, and a link matches
    /// on its label. Anything that changes the WORDS — an HTML entity like `&#102;oo`, an attribute
    /// value, text the page invented — fails and costs a coarse quote, which is the old behaviour.
    static func verifiedQuote(_ selection: String, within normalized: String,
                              startLine: Int, endLine: Int) -> String? {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let all = MarkdownOutline.lines(normalized)
        guard !all.isEmpty else { return nil }
        let lo = max(1, min(startLine, all.count))
        let hi = max(lo, min(endLine, all.count))
        let slice = all[(lo - 1)...(hi - 1)].joined(separator: "\n")
        guard containsRun(words(of: slice), words(of: trimmed)) else { return nil }
        return MarkdownOutline.quote(trimmed)
    }

    /// The lowercased letter-and-digit runs of `s`, in order. Everything else is a separator.
    private static func words(of s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// True when `needle` appears in `haystack` as a contiguous run. An empty needle is never a match:
    /// a selection with no words at all proves nothing.
    private static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i ..< i + needle.count]) == needle {
            return true
        }
        return false
    }

    /// The inbox message body. Human-first: the user reads and can edit it in the inbox editor, and it
    /// must read the same way to every agent.
    ///
    ///     Comment on `<path>:<start>-<end>` § <heading › path>
    ///
    ///     > <excerpt>
    ///
    ///     <the user's note, verbatim>
    public func message(note: String) -> String {
        var head = "Comment on `\(path)"
        if let s = startLine, let e = endLine { head += ":\(s)-\(e)" }
        head += "`"
        if !headingPath.isEmpty { head += " § " + headingPath.joined(separator: " › ") }
        return "\(head)\n\n\(excerpt)\n\n\(note)"
    }

    /// A whole reading pass as ONE message: several comments, in document order.
    ///
    /// Each entry is byte-identical to what `message(note:)` produces on its own, and a pass of exactly
    /// one comment IS that message with nothing added. So the format an agent has to read never changes
    /// with the count — a batch is the single format repeated, plus a header that says how many.
    ///
    /// The path repeats in every entry even though the whole pass is about one document. That redundancy
    /// is the point: an entry stays a complete, quotable anchor when the agent works through them one at
    /// a time, or quotes one back in a reply.
    public static func batchMessage(_ items: [(comment: DocumentComment, note: String)]) -> String {
        guard let first = items.first else { return "" }
        guard items.count > 1 else { return first.comment.message(note: first.note) }
        let head = "\(items.count) comments on `\(first.comment.path)`"
        let body = items.map { $0.comment.message(note: $0.note) }.joined(separator: "\n\n---\n\n")
        return "\(head)\n\n\(body)"
    }
}
