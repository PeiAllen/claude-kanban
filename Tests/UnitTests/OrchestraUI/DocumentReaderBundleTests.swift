import Foundation
import Testing
@testable import OrchestraUI

/// The reader's page must actually SHIP. These assertions exist because the failure they catch is
/// otherwise invisible until runtime, and on iOS specifically until a Release device build: a resource
/// that stopped being bundled renders as a blank pane, not an error.
@Suite struct DocumentReaderBundleTests {

    @Test("the bundled page resolves through Bundle.module")
    func resourcesAreBundled() throws {
        let root = try #require(DocumentReaderBundle.root,
                                "DocumentReader resources missing — check Package.swift's resources: [.copy(…)]")
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("every file the page needs offline is present")
    func everyRequiredFileIsPresent() throws {
        let root = try #require(DocumentReaderBundle.root)
        for rel in DocumentReaderBundle.requiredFiles {
            let url = root.appendingPathComponent(rel)
            #expect(FileManager.default.fileExists(atPath: url.path), "missing bundled asset: \(rel)")
        }
    }

    @Test("the KaTeX webfonts ship, or math renders as tofu")
    func katexFontsAreBundled() throws {
        let root = try #require(DocumentReaderBundle.root)
        let fonts = (try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("vendor/fonts").path)) ?? []
        // woff2 only: every @font-face in katex.min.css lists woff2 first, so the browser never asks
        // for the woff/ttf siblings. Shipping all three formats would cost ~1.1 MB instead of ~254 KB.
        #expect(fonts.count == 20, "expected 20 woff2 faces, found \(fonts.count)")
        #expect(fonts.allSatisfy { $0.hasSuffix(".woff2") })
    }

    @Test("the page declares a no-remote-loads CSP")
    func pageDeclaresAStrictCSP() throws {
        let index = try #require(DocumentReaderBundle.indexHTML)
        let html = try String(contentsOf: index, encoding: .utf8)
        // A note is untrusted content, so these are load-bearing rather than stylistic.
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("connect-src 'none'"))
        #expect(html.contains("base-uri 'none'"))
        // Script must NOT carry an inline or eval grant: the CSP is the second layer behind DOMPurify.
        #expect(html.contains("script-src 'self'"))
        #expect(!html.contains("'unsafe-eval'"))
        #expect(html.range(of: #"script-src[^;]*unsafe-inline"#, options: .regularExpression) == nil)
    }

    @Test("the page loads no remote origins")
    func pageReferencesNothingRemote() throws {
        let index = try #require(DocumentReaderBundle.indexHTML)
        let html = try String(contentsOf: index, encoding: .utf8)
        // Offline rendering on a phone is a requirement, and a CDN cannot be trusted to stay put.
        #expect(!html.contains("https://"))
        #expect(!html.contains("http://"))
    }
}
