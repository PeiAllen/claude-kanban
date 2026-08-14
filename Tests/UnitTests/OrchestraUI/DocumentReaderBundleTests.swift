import Foundation
import Testing
@testable import OrchestraUI
import OrchestraKit

/// The reader's page must actually SHIP. These assertions exist because the failure they catch is
/// otherwise invisible until runtime, and on iOS specifically until a Release device build: a resource
/// that stopped being bundled renders as a blank pane, not an error.
@Suite struct DocumentReaderBundleTests {

    @Test("every file the page needs offline is present")
    func everyRequiredFileIsPresent() throws {
        let root = try #require(DocumentReaderBundle.root)
        for rel in DocumentReaderBundle.requiredFiles {
            let url = root.appendingPathComponent(rel)
            #expect(FileManager.default.fileExists(atPath: url.path), "missing bundled asset: \(rel)")
        }
    }

    @Test("every vendored file matches its recorded checksum")
    func vendoredBytesMatchTheirChecksums() throws {
        // The one guarantee a vendor tree lacks by default. Versions are pinned by
        // scripts/vendor-document-reader-assets.sh, but nothing otherwise notices a committed file that
        // was corrupted, hand-edited, or swapped — the failure would be a subtly wrong renderer rather
        // than a build error. This is what a lockfile's `integrity` field does for a package manager.
        let root = try #require(DocumentReaderBundle.root)
        let sums = try String(contentsOf: root.appendingPathComponent("vendor/SHA256SUMS"),
                              encoding: .utf8)
        var checked = 0
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let name = parts[1].hasPrefix("./") ? String(parts[1].dropFirst(2)) : String(parts[1])
            let data = try Data(contentsOf: root.appendingPathComponent("vendor/\(name)"))
            #expect(DocumentContentHash.hex(data) == String(parts[0]), "\(name) does not match SHA256SUMS")
            checked += 1
        }
        #expect(checked == 4, "expected 4 vendored scripts, checked \(checked)")
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
