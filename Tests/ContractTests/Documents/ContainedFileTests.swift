import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit

/// `ContainedFile` — the one reader every document and asset path goes through.
///
/// CONTRACT TIER because the whole point of this type is what a real file DESCRIPTOR proves. A fake
/// filesystem would let the assertions pass while the production code went back to checking pathnames,
/// which is precisely the bug it exists to prevent. Real symlinks, a real FIFO, and a real `fstat` are
/// the assertion.
@Suite("ContainedFile — containment, type, and size, all from one descriptor")
struct ContainedFileTests {

    /// A private root with one document in it, plus wherever the test wants to escape to.
    private func root() throws -> (root: String, outside: String) {
        let base = NSTemporaryDirectory() + "orch-contained-\(UUID().uuidString)"
        let root = base + "/tree"
        let outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "secret\n".write(toFile: outside + "/secret.md", atomically: true, encoding: .utf8)
        try "# In tree\n".write(toFile: root + "/docs/a.md", atomically: true, encoding: .utf8)
        return (PathResolver.canonical(root), outside)
    }

    @Test("reads a regular file inside the root")
    func readsAnInTreeFile() throws {
        let (root, _) = try root()
        let (data, size) = try ContainedFile.read(root + "/docs/a.md", containedIn: root, limit: 4096)
        #expect(String(decoding: data, as: UTF8.self) == "# In tree\n")
        #expect(size == 10)
    }

    @Test("refuses a symlink pointing OUT of the root")
    func refusesAnEscapingSymlink() throws {
        let (root, outside) = try root()
        try FileManager.default.createSymbolicLink(atPath: root + "/docs/escape.md",
                                                   withDestinationPath: outside + "/secret.md")
        #expect(throws: (any Error).self) {
            _ = try ContainedFile.read(root + "/docs/escape.md", containedIn: root, limit: 4096)
        }
    }

    @Test("refuses a symlinked DIRECTORY pointing out of the root")
    func refusesAnEscapingDirectorySymlink() throws {
        // The case a lexical `..`-collapsing check misses entirely: every component of the requested
        // path looks in-tree, and only the resolved location is not.
        let (root, outside) = try root()
        try FileManager.default.createSymbolicLink(atPath: root + "/docs/pics",
                                                   withDestinationPath: outside)
        #expect(throws: (any Error).self) {
            _ = try ContainedFile.read(root + "/docs/pics/secret.md", containedIn: root, limit: 4096)
        }
    }

    @Test("refuses a FIFO instead of blocking on it forever")
    func refusesAFifoWithoutHanging() throws {
        // `mkfifo docs/stall.md` with no writer makes a plain `open` wait forever. That would park the
        // caller — and, on the watch actor, every other workspace queued behind it. If this test ever
        // hangs rather than fails, the non-blocking open has been dropped.
        let (root, _) = try root()
        #expect(mkfifo(root + "/docs/stall.md", 0o644) == 0)
        #expect(throws: (any Error).self) {
            _ = try ContainedFile.read(root + "/docs/stall.md", containedIn: root, limit: 4096)
        }
    }

    @Test("refuses a directory")
    func refusesADirectory() throws {
        let (root, _) = try root()
        #expect(throws: (any Error).self) {
            _ = try ContainedFile.read(root + "/docs", containedIn: root, limit: 4096)
        }
    }

    @Test("reads at most `limit` bytes, and still reports the true size")
    func truncatesAtTheLimit() throws {
        // The caller needs both halves: the bytes are capped so a huge document cannot exhaust the
        // daemon, and the true size is what tells it the content was truncated.
        let (root, _) = try root()
        try String(repeating: "x", count: 10_000).write(toFile: root + "/docs/big.md",
                                                        atomically: true, encoding: .utf8)
        let (data, size) = try ContainedFile.read(root + "/docs/big.md", containedIn: root, limit: 100)
        #expect(data.count == 100)
        #expect(size == 10_000)
    }

    @Test("refuses a file over `maxSize` BEFORE reading it")
    func refusesOverMaxSize() throws {
        let (root, _) = try root()
        try String(repeating: "x", count: 10_000).write(toFile: root + "/docs/big.md",
                                                        atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            _ = try ContainedFile.read(root + "/docs/big.md", containedIn: root,
                                       limit: 10_000, maxSize: 4096)
        }
    }
}
