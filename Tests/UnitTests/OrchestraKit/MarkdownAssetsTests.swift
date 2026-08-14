import Foundation
import Testing
@testable import OrchestraKit

/// The allowlist behind `documentAsset`. It turns "any image-extension file in the worktree" into "the
/// images THIS document points at", which scopes what a CLIENT may name.
///
/// It is NOT a defense against the document's author — they can reference anything in the tree for real,
/// so a near-miss the regex matches costs nothing. These tests are therefore about the SHAPE of the set:
/// images and not links, and paths that resolve exactly the way the page will request them.
@Suite struct MarkdownAssetsTests {
    private func refs(_ s: String, _ dir: String = "docs") -> Set<String> {
        MarkdownAssets.referencedImages(in: s, documentDir: dir)
    }

    // MARK: - forms that must be found

    @Test("titles and angle brackets are both handled")
    func titleAndAngleBracketFormsAreFound() {
        #expect(refs("![a](img/a.png \"Cap\")\n\n![b](<img/b c.png>)")
                == ["docs/img/a.png", "docs/img/b c.png"])
    }

    @Test("reference-style images resolve through their definition")
    func referenceStyleImagesResolveThroughTheirDefinition() {
        #expect(refs("![board][b]\n\n[b]: images/board.png") == ["docs/images/board.png"])
    }

    @Test("raw img tags are found, since the format keeps formatting HTML")
    func rawImgTagsAreFound() {
        #expect(refs("<img src=\"images/x.png\" width=\"40\">") == ["docs/images/x.png"])
        #expect(refs("<img src='images/y.png'>") == ["docs/images/y.png"])
    }

    @Test("several images in one note are all collected")
    func multipleImagesAreCollected() {
        let src = "![a](i/a.png)\n\ntext\n\n![b](i/b.png)\n\n<img src=\"i/c.png\">"
        #expect(refs(src) == ["docs/i/a.png", "docs/i/b.png", "docs/i/c.png"])
    }

    // MARK: - things that must NOT widen the allowlist

    @Test("a LINK is not an image")
    func aLinkIsNotAnImage() {
        // `[text](file.png)` is a link. Allowlisting it would let any linked path be fetched, which is
        // exactly the widening this type exists to prevent.
        #expect(refs("[not an image](secret.png)").isEmpty)
        #expect(refs("see [the key](../../.ssh/id_rsa.png)").isEmpty)
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
