import Foundation
import Testing
@testable import OrchestraKit

/// The exact inbox-message format a reader comment becomes. This is a CONTRACT, not a preference: the
/// user reads and can edit the result in the inbox editor, and it must read the same way to every
/// agent — so the assertions here are literal, not structural.
@Suite struct DocumentCommentTests {
    private let src = """
    # Design
    ## Level contract
    | L1 containers | What actually runs? | processes / artifacts |
    """

    @Test("the settled format, character for character")
    func matchesTheSettledFormatExactly() {
        let c = DocumentComment.capture(path: "notes/designs/x.md", source: src, startLine: 3, endLine: 3)
        #expect(c.message(note: "Should this say \"processes only\"?") == """
        Comment on `notes/designs/x.md:3-3` § Design › Level contract

        > | L1 containers | What actually runs? | processes / artifacts |

        Should this say "processes only"?
        """)
    }

    @Test("no headings means no § clause")
    func omitsHeadingClauseWhenThereAreNoHeadings() {
        let c = DocumentComment.capture(path: "a.md", source: "just prose\n", startLine: 1, endLine: 1)
        #expect(c.message(note: "hi").hasPrefix("Comment on `a.md:1-1`\n\n"))
    }

    @Test("no line range means no :a-b suffix")
    func omitsLineSuffixWhenRangeIsUnavailable() {
        let c = DocumentComment(path: "a.md", startLine: nil, endLine: nil, headingPath: [], excerpt: "> q")
        #expect(c.message(note: "hi").hasPrefix("Comment on `a.md`\n\n"))
    }

    @Test("the user's note is verbatim — never reflowed, never wrapped")
    func keepsTheUserNoteVerbatim() {
        let note = "line one\n\n   indented   \nline three"
        let c = DocumentComment.capture(path: "a.md", source: src, startLine: 1, endLine: 1)
        #expect(c.message(note: note).hasSuffix(note))
    }

    @Test("there is no trailing instruction line")
    func hasNoTrailingInstructionLine() {
        // Argued explicitly: a review comment carries no meta-instruction. The human writes the
        // remark; the author decides whether to answer, to edit, or both.
        let msg = DocumentComment.capture(path: "a.md", source: src, startLine: 1, endLine: 1)
            .message(note: "why?")
        #expect(msg.hasSuffix("why?"))
        #expect(!msg.lowercased().contains("address this"))
    }

    @Test("a range takes the heading of its START line")
    func rangeUsesTheHeadingOfTheRangeStart() {
        let multi = "# A\nbody a\n## B\nbody b\n"
        let c = DocumentComment.capture(path: "a.md", source: multi, startLine: 2, endLine: 4)
        #expect(c.headingPath == ["A"])
    }

    @Test("capture normalizes CRLF for the caller")
    func captureNormalizesLineEndings() {
        // The caller should never have to remember to normalize; a CRLF note must quote the same text
        // and report the same lines as an LF one.
        let crlf = "# H\r\nalpha\r\nbravo\r\n"
        let c = DocumentComment.capture(path: "a.md", source: crlf, startLine: 2, endLine: 3)
        #expect(c.excerpt == "> alpha\n> bravo")
        #expect(c.headingPath == ["H"])
    }
}
