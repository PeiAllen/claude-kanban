import Foundation
import Testing
@testable import OrchestraCore

@Suite("PathResolver — the security boundary")
struct PathResolverTests {

    /// Make a temp dir tree: <root>/repos and <root>/outside, returning the realpath'd root.
    private func makeTree() throws -> (root: String, repos: String, outside: String) {
        let base = NSTemporaryDirectory() + "orch-pr-\(UUID().uuidString)"
        let repos = base + "/repos"
        let outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: repos + "/myrepo", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside + "/secret", withIntermediateDirectories: true)
        return (PathResolver.realpath(base), PathResolver.realpath(repos), PathResolver.realpath(outside))
    }

    @Test("allows a path inside an allowed root")
    func allowsInside() throws {
        let t = try makeTree()
        let r = PathResolver(allowedRoots: [t.repos])
        #expect(throws: Never.self) { try r.assertAllowed(t.repos + "/myrepo") }
    }

    @Test("rejects a sibling path outside the allowlist")
    func rejectsOutside() throws {
        let t = try makeTree()
        let r = PathResolver(allowedRoots: [t.repos])
        #expect(throws: OrchestraError.self) { try r.assertAllowed(t.outside + "/secret") }
    }

    @Test("rejects a ../ escape that climbs out of an allowed root")
    func rejectsDotDotEscape() throws {
        let t = try makeTree()
        let r = PathResolver(allowedRoots: [t.repos])
        #expect(throws: OrchestraError.self) { try r.assertAllowed(t.repos + "/../outside/secret") }
    }

    @Test("rejects a symlink that points outside the allowlist")
    func rejectsSymlinkEscape() throws {
        let t = try makeTree()
        // <repos>/link -> <outside>/secret  (a symlink that escapes the allowed root)
        let link = t.repos + "/link"
        try? FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: t.outside + "/secret")
        let r = PathResolver(allowedRoots: [t.repos])
        #expect(throws: OrchestraError.self) { try r.assertAllowed(link) }
    }

    @Test("a prefix-but-not-component sibling is not allowed")
    func rejectsPrefixSibling() throws {
        let t = try makeTree()
        // <repos> allowed; "<repos>-evil" shares a string prefix but is a different dir.
        let evil = t.repos + "-evil"
        try FileManager.default.createDirectory(atPath: evil, withIntermediateDirectories: true)
        let r = PathResolver(allowedRoots: [t.repos])
        #expect(throws: OrchestraError.self) { try r.assertAllowed(evil) }
    }

    @Test("allows a not-yet-existing worktree path under an allowed root")
    func allowsNonexistentUnderRoot() throws {
        let t = try makeTree()
        let r = PathResolver(allowedRoots: [t.root])
        #expect(throws: Never.self) { try r.assertAllowed(t.root + "/worktrees/myrepo/feature-x") }
    }
}
