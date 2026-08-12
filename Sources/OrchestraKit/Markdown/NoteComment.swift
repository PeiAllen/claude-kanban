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
public struct NoteComment: Equatable, Sendable {
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
    public static func capture(path: String, source: String,
                               startLine: Int, endLine: Int) -> NoteComment {
        let norm = MarkdownOutline.normalized(source)
        return NoteComment(
            path: path,
            startLine: startLine,
            endLine: endLine,
            headingPath: MarkdownOutline.headingPath(in: norm, atLine: startLine),
            excerpt: MarkdownOutline.excerpt(from: norm, startLine: startLine, endLine: endLine))
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
}
