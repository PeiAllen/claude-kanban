import Foundation
import Testing
@testable import OrchestraKit
import OrchestraCore

/// The image-path contract, checked on BOTH sides against ONE table.
///
/// `MarkdownAssets` decides which paths the daemon will serve. `docpath.js` decides which paths the page
/// will request. When they disagree the image simply does not appear — no error, no log line, nothing
/// that fails a build. They drifted twice while the rule lived in a comment asking future readers to
/// keep two copies identical:
///
///   - percent-encoding: WebKit decodes `url.path` before the scheme handler sees it, so an allowlist
///     holding `my%20image.png` could never match a request for `my image.png`.
///   - scheme detection: `1x:a.png` was a scheme to Swift and a relative path to the page.
///
/// The previous version of this test asserted only the Swift half, which is exactly half a contract —
/// either drift above would have recurred with a green suite. CONTRACT TIER because closing that gap
/// means running the real JavaScript in `node`, which is a fork.
@Suite("Image paths — Swift and the page must agree")
struct DocumentPathContractTests {

    private struct Vector: Decodable {
        let src: String
        let dir: String
        let expect: String?
        let why: String
    }
    private struct Table: Decodable { let vectors: [Vector] }

    private func table() throws -> [Vector] {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/document-path-vectors",
                                                 withExtension: "json"))
        return try JSONDecoder().decode(Table.self, from: Data(contentsOf: url)).vectors
    }

    /// `docpath.js` lives beside the page it ships with, so find it from the source tree rather than a
    /// built bundle — this test is about the file that will be vendored, not a copy of it.
    private func docPathJS() throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }        // …/Tests/ContractTests/Documents/<file>
        let js = dir.appendingPathComponent("Sources/OrchestraUI/Resources/DocumentReader/docpath.js")
        #expect(FileManager.default.fileExists(atPath: js.path), "docpath.js moved: \(js.path)")
        return js.path
    }

    @Test("the daemon serves exactly the paths the table names")
    func swiftSideMatchesTheTable() throws {
        for v in try table() {
            let got = MarkdownAssets.referencedImages(in: "![x](\(v.src))", documentDir: v.dir)
            if let want = v.expect {
                #expect(got == [want], "\(v.src) in \(v.dir) — \(v.why)")
            } else {
                #expect(got.isEmpty, "\(v.src) in \(v.dir) should not be served — \(v.why)")
            }
        }
    }

    @Test("the page requests exactly the paths the table names")
    func javaScriptSideMatchesTheTable() throws {
        let vectors = try table()
        // Hand the vectors to node as JSON and get its answers back the same way, so the comparison is
        // over data rather than over a printed format.
        let input = String(decoding: try JSONEncoder().encode(vectors.map { [$0.src, $0.dir] }),
                           as: UTF8.self)
        let script = """
        const { resolveOne } = require(process.argv[1]);
        const out = JSON.parse(process.argv[2]).map(([src, dir]) => resolveOne(src, dir));
        process.stdout.write(JSON.stringify(out));
        """
        let r = try Proc.run(["node", "-e", script, try docPathJS(), input])
        #expect(r.ok, "node failed: \(r.stderr)")
        let got = try JSONDecoder().decode([String?].self, from: Data(r.stdout.utf8))
        #expect(got.count == vectors.count)
        for (i, v) in vectors.enumerated() where i < got.count {
            #expect(got[i] == v.expect, "\(v.src) in \(v.dir) — \(v.why)")
        }
    }
}
