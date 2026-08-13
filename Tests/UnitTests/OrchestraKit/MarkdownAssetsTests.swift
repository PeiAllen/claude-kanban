import Foundation
import Testing
@testable import OrchestraKit

/// The allowlist behind `documentAsset`. This is what turns "any image-extension file in the worktree"
/// into "the images THIS note points at", so the tests here are a security boundary, not a nicety.
///
/// A reference form that is MISSED degrades to a broken image. A form that is wrongly INCLUDED widens
/// the daemon's file-read surface — so the negative cases matter more than the positive ones.
@Suite struct MarkdownAssetsTests {
    private func refs(_ s: String, _ dir: String = "docs") -> Set<String> {
        MarkdownAssets.referencedImages(in: s, documentDir: dir)
    }

    // MARK: - forms that must be found

    @Test("an inline image resolves against the document's directory")
    func inlineImageResolvesAgainstTheDocumentDirectory() {
        #expect(refs("![board](images/board.png)") == ["docs/images/board.png"])
    }

    @Test("titles and angle brackets are both handled")
    func titleAndAngleBracketFormsAreFound() {
        #expect(refs("![a](img/a.png \"Cap\")\n\n![b](<img/b c.png>)")
                == ["docs/img/a.png", "docs/img/b c.png"])
    }

    @Test("reference-style images resolve through their definition")
    func referenceStyleImagesResolveThroughTheirDefinition() {
        #expect(refs("![board][b]\n\n[b]: images/board.png") == ["docs/images/board.png"])
    }

    @Test("a definition placed before its use still resolves")
    func definitionOrderDoesNotMatter() {
        #expect(refs("[b]: images/board.png\n\n![board][b]") == ["docs/images/board.png"])
    }

    @Test("raw img tags are found, since the format keeps formatting HTML")
    func rawImgTagsAreFound() {
        #expect(refs("<img src=\"images/x.png\" width=\"40\">") == ["docs/images/x.png"])
        #expect(refs("<img src='images/y.png'>") == ["docs/images/y.png"])
    }

    @Test("parent traversal collapses to a worktree-relative path")
    func parentTraversalCollapses() {
        #expect(refs("![x](../shared/x.png)", "docs/sub") == ["docs/shared/x.png"])
    }

    @Test("a note at the worktree root needs no prefix")
    func noteAtTheWorktreeRootNeedsNoPrefix() {
        #expect(refs("![a](a.png)", "") == ["a.png"])
    }

    @Test("several images in one note are all collected")
    func multipleImagesAreCollected() {
        let src = "![a](i/a.png)\n\ntext\n\n![b](i/b.png)\n\n<img src=\"i/c.png\">"
        #expect(refs(src) == ["docs/i/a.png", "docs/i/b.png", "docs/i/c.png"])
    }

    // MARK: - things that must NOT widen the allowlist

    @Test("remote and data sources are excluded")
    func remoteAndDataSourcesAreExcluded() {
        // The CSP blocks remote loads and `data:` never reaches the daemon, so neither belongs in the
        // allowlist. Including them would widen it for nothing.
        #expect(refs("![a](https://x.test/a.png)\n![b](data:image/png;base64,AAAA)").isEmpty)
        #expect(refs("![c](//cdn.test/c.png)").isEmpty)
    }

    @Test("a LINK is not an image")
    func aLinkIsNotAnImage() {
        // `[text](file.png)` is a link. Allowlisting it would let any linked path be fetched, which is
        // exactly the widening this type exists to prevent.
        #expect(refs("[not an image](secret.png)").isEmpty)
        #expect(refs("see [the key](../../.ssh/id_rsa.png)").isEmpty)
    }

    @Test("a fenced code block is not scanned")
    func fencedCodeIsNotScanned() {
        // Otherwise a note that DOCUMENTS markdown syntax would silently widen its own allowlist.
        #expect(refs("```\n![x](secret.png)\n```\n").isEmpty)
    }

    @Test("an ESCAPED bang is a link, not an image")
    func escapedBangIsNotAnImage() {
        // `\![alt](x)` renders as a literal `!` followed by a link. The page never requests it, so
        // allowlisting it widened the daemon's read surface for a file nothing on screen points at.
        #expect(refs(#"\![literal](secret.png)"#).isEmpty)
        #expect(refs("\\![literal][b]\n\n[b]: secret.png").isEmpty)
    }

    @Test("an INLINE code span is not scanned")
    func inlineCodeIsNotScanned() {
        // Same rule as a fenced block, one scale down: a document explaining the syntax renders a
        // literal string, not an image.
        #expect(refs("write `![x](secret.png)` to embed one").isEmpty)
        #expect(refs("``a ` tick and ![x](secret.png)``").isEmpty)
        // An UNTERMINATED span is kept verbatim rather than swallowing the rest of the document.
        #expect(refs("` stray tick\n\n![a](i/a.png)") == ["docs/i/a.png"])
    }

    @Test("a commented-out reference is not scanned")
    func htmlCommentsAreNotScanned() {
        #expect(refs("<!-- ![x](secret.png) -->").isEmpty)
        #expect(refs("<!--\n![x](secret.png)\n-->\n\n![a](i/a.png)") == ["docs/i/a.png"])
    }

    @Test("an UNQUOTED img src is found")
    func unquotedImgSrcIsFound() {
        // Valid HTML that the page renders and rewrites. Missing it here made a legitimate image 404;
        // it keeps nothing out, because the `<img>` is exactly the reference form this scans for.
        #expect(refs("<img src=images/x.png width=40>") == ["docs/images/x.png"])
    }

    @Test("an empty or malformed reference yields nothing")
    func emptyAndMalformedReferencesAreIgnored() {
        #expect(refs("![alt]()").isEmpty)
        #expect(refs("![unresolved][nope]").isEmpty)
        #expect(refs("![](   )").isEmpty)
    }
}
