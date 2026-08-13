import Foundation
import Testing
@testable import OrchestraKit

/// The source-text helpers behind the note reader's comment format, as pure functions. No webview, no
/// daemon, no I/O — everything here works on a normalized markdown string.
///
/// The normalization matters more than it looks: `marked` collapses `\r\n` and lone `\r` to `\n`
/// BEFORE it tokenizes, so a line number is only meaningful against the same normalization. Swift
/// normalizes once and hands that exact string to the page, so both sides always agree.
@Suite struct MarkdownOutlineTests {

    // MARK: - normalization + line splitting

    @Test("CRLF and lone CR both collapse to LF")
    func normalizesCRLFAndLoneCR() {
        #expect(MarkdownOutline.normalized("a\r\nb\rc\n") == "a\nb\nc\n")
    }

    @Test("a trailing newline does not produce a phantom final line")
    func trailingNewlineDoesNotAddALine() {
        #expect(MarkdownOutline.lines("a\nb\n").count == 2)
        #expect(MarkdownOutline.lines("a\nb").count == 2)
    }

    @Test("an empty source has no lines")
    func emptySourceHasNoLines() {
        #expect(MarkdownOutline.lines("").isEmpty)
        #expect(MarkdownOutline.excerpt(from: "", startLine: 1, endLine: 1) == "")
    }

    // MARK: - excerpt

    @Test("every quoted line carries the marker")
    func excerptPrefixesEveryLine() {
        let src = "alpha\nbravo\ncharlie\n"
        #expect(MarkdownOutline.excerpt(from: src, startLine: 1, endLine: 2) == "> alpha\n> bravo")
    }

    @Test("an out-of-range span clamps instead of trapping")
    func excerptClampsOutOfRange() {
        #expect(MarkdownOutline.excerpt(from: "only\n", startLine: 0, endLine: 99) == "> only")
    }

    @Test("an over-long single line is truncated, never dropped")
    func excerptCapsAt500CharsWithSentinel() {
        let long = String(repeating: "x", count: 700)
        let out = MarkdownOutline.excerpt(from: long, startLine: 1, endLine: 1)
        #expect(out.hasSuffix("> …\n(excerpt truncated)"))
        #expect(out.count <= MarkdownOutline.excerptCap)
        // A single markdown line can exceed the cap on its own (a paragraph, a wide table row). Assert
        // the quote still CONTAINS quoted text: a line-boundary-only truncation returns just the
        // sentinel here, and the two assertions above pass on that empty result.
        #expect(out.hasPrefix("> xxx"))
        #expect(out.contains(String(repeating: "x", count: 400)))
    }

    // MARK: - heading path

    @Test("ancestors only, outermost first")
    func headingPathCollectsAncestorsOnly() {
        let src = """
        # Design
        ## Level contract
        body here
        ## Other
        """
        #expect(MarkdownOutline.headingPath(in: src, atLine: 3) == ["Design", "Level contract"])
    }

    @Test("a hash inside a fence is not a heading")
    func headingPathIgnoresHashesInsideFences() {
        let src = """
        # Real
        ```
        # not a heading
        ```
        body
        """
        #expect(MarkdownOutline.headingPath(in: src, atLine: 5) == ["Real"])
    }

    @Test("no headings above the line means no clause")
    func headingPathIsEmptyBeforeAnyHeading() {
        #expect(MarkdownOutline.headingPath(in: "intro text\n", atLine: 1).isEmpty)
    }

    @Test("a deeper-or-equal heading pops siblings")
    func deeperHeadingPopsSiblingsAndDeeperLevels() {
        let src = "# A\n## B\n### C\n## D\nbody\n"
        #expect(MarkdownOutline.headingPath(in: src, atLine: 5) == ["A", "D"])
    }

    @Test("ATX requires a space after the hashes")
    func atxRequiresASpaceAfterTheHashes() {
        #expect(MarkdownOutline.headingPath(in: "# Real\n\n#notHeading\n\nbody\n", atLine: 5) == ["Real"])
    }

    @Test("four-space indented code is not scanned for headings")
    func indentedCodeIsNotAHeading() {
        let src = "# Real\n\n    # indented code\n\nbody\n"
        #expect(MarkdownOutline.headingPath(in: src, atLine: 5) == ["Real"])
    }

    @Test("three backticks do not close a four-backtick fence")
    func threeBackticksDoNotCloseAFourBacktickFence() {
        // The inner ``` is CONTENT, so `# fake` stays fenced and never becomes a heading.
        let src = "# Real\n\n````\n```\n# fake\n````\n\nbody\n"
        #expect(MarkdownOutline.headingPath(in: src, atLine: 8) == ["Real"])
    }
}
