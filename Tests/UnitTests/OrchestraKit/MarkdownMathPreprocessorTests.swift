import Foundation
import Testing
@testable import OrchestraKit

@Suite("Mobile notes Markdown math adapter")
struct MarkdownMathPreprocessorTests {
    @Test("replaces inline and display formulas with decodable image URLs")
    func replacesMath() throws {
        let value = MarkdownMathPreprocessor.replacingMath(in: "Energy $E=mc^2$\n\n$$\nx^2\n$$")
        let urls = value
            .split(separator: "(")
            .compactMap { part -> URL? in
                guard let end = part.firstIndex(of: ")") else { return nil }
                return URL(string: String(part[..<end]))
            }

        #expect(urls.count == 2)
        #expect(MarkdownMathPreprocessor.formula(from: urls[0])?.expression == "E=mc^2")
        #expect(MarkdownMathPreprocessor.formula(from: urls[0])?.display == false)
        #expect(MarkdownMathPreprocessor.formula(from: urls[1])?.expression == "x^2")
        #expect(MarkdownMathPreprocessor.formula(from: urls[1])?.display == true)
    }

    @Test("supports KaTeX inline and display delimiters")
    func replacesKaTeXDelimiters() {
        let output = MarkdownMathPreprocessor.replacingMath(in: "Inline \\(a+b\\)\n\n\\[\nx^2\n\\]")
        #expect(output.contains("math://inline/"))
        #expect(output.contains("math://display/"))
    }

    @Test("does not rewrite formulas inside fenced or inline code")
    func protectsCode() {
        let input = "```swift\nlet formula = \"$x$\"\n```\n\n`$y$` and $z$"
        let output = MarkdownMathPreprocessor.replacingMath(in: input)
        #expect(output.contains("let formula = \"$x$\""))
        #expect(output.contains("`$y$`"))
        #expect(output.contains("![math](math://inline/"))
    }

    @Test("leaves links and unmatched delimiters alone")
    func preservesLinksAndMalformedInput() {
        let input = "[price](https://example.com/$5) and $unfinished"
        #expect(MarkdownMathPreprocessor.replacingMath(in: input) == input)
    }

    @Test("preserves indented code, autolinks, and reference destinations")
    func preservesOtherMarkdownDestinations() {
        let input = "    $code$\n\t$tabbed$\n<https://example.com/$url$>\n[Docs][reference]\n[reference]: https://example.com/$destination$\n$render$"
        let output = MarkdownMathPreprocessor.replacingMath(in: input)

        #expect(output.contains("    $code$"))
        #expect(output.contains("\t$tabbed$"))
        #expect(output.contains("<https://example.com/$url$>"))
        #expect(output.contains("https://example.com/$destination$"))
        #expect(output.contains("![math](math://inline/"))
    }

    @Test("normalizes CRLF without changing the rendered structure")
    func handlesCRLF() {
        let output = MarkdownMathPreprocessor.replacingMath(in: "# Heading\r\n\r\n$x$")
        #expect(output.hasPrefix("# Heading\r\n\r\n![math](math://inline/"))
    }
}
