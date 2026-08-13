import Foundation
import Testing
@testable import OrchestraKit

/// The SHARED vector table for image-path handling.
///
/// Two implementations must agree exactly: `MarkdownAssets.add` in Swift decides which paths the
/// daemon will serve, and `resolveAssets` in reader.js decides which paths the page will request. A
/// disagreement is a silent broken image, never an error.
///
/// They drifted twice before this file existed — both carried a "MUST stay identical" comment and
/// nothing checked it:
///   - percent-encoding: WebKit decodes `url.path`, so an allowlist holding `my%20image.png` could
///     never match a request for `my image.png`. `%20` is the CommonMark-canonical space.
///   - scheme detection: `1x:a.png` was a scheme to Swift and a path to the page.
///
/// `VECTORS` below is the contract. The JS side is checked against this same table by
/// `.scratch`-run harnesses during development; keeping the cases here in one literal list is what
/// makes that possible.
@Suite struct DocumentPathVectorTests {

    /// `(markdown src, document directory, expected worktree-relative path or nil to mean "not served")`
    static let VECTORS: [(src: String, dir: String, expect: String?)] = [
        // plain
        ("images/board.png",        "docs",      "docs/images/board.png"),
        ("a.png",                   "",          "a.png"),
        ("./b.png",                 "docs",      "docs/b.png"),
        ("../shared/x.png",         "docs/sub",  "docs/shared/x.png"),
        ("/top.png",                "docs",      "top.png"),
        // percent-encoding — the case that broke
        ("images/my%20image.png",   "docs",      "docs/images/my image.png"),
        ("images/a%2Bb.png",        "docs",      "docs/images/a+b.png"),
        ("caf%C3%A9/x.png",         "docs",      "docs/café/x.png"),
        // query and fragment are not part of the path
        ("images/a.png?v=2",        "docs",      "docs/images/a.png"),
        ("images/a.png#frag",       "docs",      "docs/images/a.png"),
        // schemes and protocol-relative are never ours to serve
        ("https://x.test/a.png",    "docs",      nil),
        ("data:image/png;base64,A", "docs",      nil),
        ("//cdn.test/c.png",        "docs",      nil),
        // NOT a scheme: RFC 3986 requires a scheme to begin with a LETTER, and both sides now agree
        // on that, so this is an oddly-named relative file. It previously differed between them —
        // Swift excluded it, the page requested it — which is the drift this table exists to catch.
        ("1x:a.png",                "docs",      "docs/1x:a.png"),
        // degenerate
        ("",                        "docs",      nil),
        ("   ",                     "docs",      nil),
    ]

    @Test("every vector resolves the way the page will request it")
    func vectorsAgree() {
        for v in Self.VECTORS {
            let got = MarkdownAssets.referencedImages(in: "![x](\(v.src))", documentDir: v.dir)
            if let want = v.expect {
                #expect(got == [want], "src \(v.src) in \(v.dir): got \(got), want [\(want)]")
            } else {
                #expect(got.isEmpty, "src \(v.src) in \(v.dir) should not be served, got \(got)")
            }
        }
    }

    @Test("normalize collapses the same way reader.js normalizePath does")
    func normalizeMatches() {
        #expect(MarkdownAssets.normalize("a/./b") == "a/b")
        #expect(MarkdownAssets.normalize("a/../b") == "b")
        #expect(MarkdownAssets.normalize("a//b") == "a/b")
        #expect(MarkdownAssets.normalize("../../x") == "x")     // cannot climb out of the root
        #expect(MarkdownAssets.normalize("") == "")
    }
}
