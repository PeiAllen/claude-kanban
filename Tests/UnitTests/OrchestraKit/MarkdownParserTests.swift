import Testing
@testable import OrchestraKit

@Suite("Mobile notes Markdown parser")
struct MarkdownParserTests {
    @Test("parses GFM tables, alignment, and escaped pipes")
    func parsesTables() {
        let input = #"""
        | Name | Value | Notes |
        | :--- | :---: | ---: |
        | A\|B | `x|y` | [docs](https://example.com) |
        """#
        #expect(MarkdownParser.blocks(input) == [
            .table(MarkdownTable(
                headers: ["Name", "Value", "Notes"],
                rows: [["A|B", "`x|y`", "[docs](https://example.com)"]],
                alignments: [.leading, .center, .trailing]))
        ])
    }

    @Test("parses task-list state and keeps indentation")
    func parsesTasks() {
        #expect(MarkdownParser.blocks("- [x] Done\n  - [ ] Child\n- Plain") == [
            .list(MarkdownList(items: [
                .init(ordered: false, marker: "•", text: "Done", indent: 0, task: true),
                .init(ordered: false, marker: "•", text: "Child", indent: 1, task: false),
                .init(ordered: false, marker: "•", text: "Plain", indent: 0, task: nil)
            ]))
        ])
    }

    @Test("splits inline math but leaves math-looking code untouched")
    func parsesInlineMath() {
        #expect(MarkdownParser.inlineParts("Energy $E=mc^2$ and `cost $5`.") == [
            .text("Energy "), .math("E=mc^2"), .text(" and `cost $5`.")
        ])
    }

    @Test("parses display math delimiters")
    func parsesDisplayMath() {
        #expect(MarkdownParser.blocks("Before\n\n$$\nE = mc^2\n$$\n\nAfter") == [
            .paragraph("Before"), .math(expression: "E = mc^2", display: true), .paragraph("After")
        ])
        #expect(MarkdownParser.blocks("\\[x^2\\]") == [.math(expression: "x^2", display: true)])
    }

    @Test("preserves malformed tables and unmatched inline math")
    func preservesMalformedSource() {
        #expect(MarkdownParser.blocks("a | b\nnot a delimiter") == [.paragraph("a | b\nnot a delimiter")])
        #expect(MarkdownParser.inlineParts("price $5 and unfinished") == [.text("price $5 and unfinished")])
    }

    @Test("parses images as standalone inline parts")
    func parsesImages() {
        #expect(MarkdownParser.inlineParts("Before ![diagram](https://example.com/a.png) after") == [
            .text("Before "), .image(alt: "diagram", url: "https://example.com/a.png"), .text(" after")
        ])
    }

    @Test("regresses existing headings, fences, quotes, lists, and thematic breaks")
    func preservesExistingBlocks() {
        let blocks = MarkdownParser.blocks("""
        # Heading

        > Quote

        1. First
        2. Second

        ```swift
        let value = 1
        ```

        ---
        """)
        #expect(blocks[0] == .heading(level: 1, text: "Heading"))
        #expect(blocks[1] == .quote("Quote"))
        #expect(blocks[2] == .list(MarkdownList(items: [
            .init(ordered: true, marker: "1.", text: "First", indent: 0, task: nil),
            .init(ordered: true, marker: "2.", text: "Second", indent: 0, task: nil)
        ])))
        #expect(blocks[3] == .code(language: "swift", code: "let value = 1"))
        #expect(blocks[4] == .thematicBreak)
    }
}
