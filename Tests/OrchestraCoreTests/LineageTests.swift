import Foundation
import Testing
@testable import OrchestraCore

@Suite("BranchLineage — git-config lineage CRUD + tree queries")
struct LineageTests {

    // MARK: fixtures

    /// A throwaway git repo (empty is fine — lineage is pure config, no branches needed).
    static func makeRepo(withOrigin: Bool = false) throws -> String {
        let dir = NSTemporaryDirectory() + "orch-lineage-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try git(dir, "init", "-q", "-b", "main")
        try git(dir, "config", "user.email", "t@t")
        try git(dir, "config", "user.name", "t")
        if withOrigin { try git(dir, "remote", "add", "origin", "file:///dev/null") }
        return dir
    }
    @discardableResult
    static func git(_ dir: String, _ args: String...) throws -> ProcResult {
        let r = try Proc.run(["git", "-C", dir] + args)
        #expect(r.ok, "git \(args.joined(separator: " ")) failed: \(r.stderr)")
        return r
    }

    // MARK: CRUD round-trips

    @Test("set/read round-trip — local parent")
    func roundTripLocal() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "child",
                          link: ParentLink(parent: "feature-a", base: "deadbeef"))
        let got = try #require(await lin.read(repo: repo, branch: "child"))
        #expect(got.parent == "feature-a")
        #expect(got.base == "deadbeef")
        #expect(got.prNumber == nil)
        #expect(got.watch == false)
    }

    @Test("set/read round-trip — remote parent with PR + watch keys")
    func roundTripRemote() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "child",
                          link: ParentLink(parent: "origin/feature-b", base: "cafe", prNumber: 12, watch: true))
        let got = try #require(await lin.read(repo: repo, branch: "child"))
        #expect(got.parent == "origin/feature-b")
        #expect(got.prNumber == 12)
        #expect(got.watch == true)
    }

    @Test("clear removes all orchestra-* keys")
    func clearAll() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "child",
                          link: ParentLink(parent: "p", base: "b", prNumber: 3, watch: true))
        try await lin.clear(repo: repo, branch: "child")
        #expect(await lin.read(repo: repo, branch: "child") == nil)
    }

    @Test("updateBase rewrites only the base OID")
    func updateBaseOnly() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "child", link: ParentLink(parent: "p", base: "old"))
        try await lin.updateBase(repo: repo, branch: "child", oid: "new")
        let got = try #require(await lin.read(repo: repo, branch: "child"))
        #expect(got.parent == "p")
        #expect(got.base == "new")
    }

    @Test("read of an unlinked branch → nil")
    func readUnlinked() async throws {
        let repo = try Self.makeRepo()
        #expect(await BranchLineage().read(repo: repo, branch: "nope") == nil)
    }

    // MARK: cycle guard

    @Test("self-parent rejected")
    func selfParentRejected() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        await #expect(throws: OrchestraError.self) {
            try await lin.set(repo: repo, branch: "x", link: ParentLink(parent: "x", base: "b"))
        }
    }

    @Test("a cycle is rejected — root adopting its own descendant")
    func cycleRejected() async throws {
        // a → b → c  (a.parent=b, b.parent=c). Now try c.parent=a, which closes a→b→c→a.
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "a", link: ParentLink(parent: "b", base: "1"))
        try await lin.set(repo: repo, branch: "b", link: ParentLink(parent: "c", base: "1"))
        await #expect(throws: OrchestraError.self) {
            try await lin.set(repo: repo, branch: "c", link: ParentLink(parent: "a", base: "1"))
        }
    }

    // MARK: children / ancestors

    @Test("children finds every branch whose parent is the target (fan-out)")
    func childrenFanOut() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        for c in ["c1", "c2", "c3"] {
            try await lin.set(repo: repo, branch: c, link: ParentLink(parent: "p", base: "b"))
        }
        try await lin.set(repo: repo, branch: "other", link: ParentLink(parent: "q", base: "b"))
        #expect(Set(await lin.children(repo: repo, of: "p")) == ["c1", "c2", "c3"])
        #expect(await lin.children(repo: repo, of: "q") == ["other"])
    }

    @Test("children matches only the orchestra-parent key, never orchestra-parent-base of equal value")
    func childrenAnchorExcludesSiblingKeys() async throws {
        // A child whose recorded base OID string coincidentally equals the parent name would double-
        // count if `children`'s key match leaked past the `orchestra-parent` anchor onto `-base`.
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "c1", link: ParentLink(parent: "target", base: "target"))
        #expect(await lin.children(repo: repo, of: "target") == ["c1"])   // once, from the parent key only
    }

    @Test("ancestors walks the parent chain nearest-first")
    func ancestorsChain() async throws {
        let repo = try Self.makeRepo()
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "a", link: ParentLink(parent: "b", base: "1"))
        try await lin.set(repo: repo, branch: "b", link: ParentLink(parent: "c", base: "1"))
        #expect(await lin.ancestors(repo: repo, of: "a") == ["b", "c"])
    }

    @Test("foreign git-config keys are untouched by clear + ignored by children")
    func foreignKeysUntouched() async throws {
        let repo = try Self.makeRepo()
        try Self.git(repo, "config", "branch.child.description", "hello")
        let lin = BranchLineage()
        try await lin.set(repo: repo, branch: "child", link: ParentLink(parent: "p", base: "b"))
        try await lin.clear(repo: repo, branch: "child")
        // The non-orchestra key survives.
        let desc = try Self.git(repo, "config", "--get", "branch.child.description").stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(desc == "hello")
        // A branch with only a description (no orchestra-parent) is not a child.
        #expect(await lin.children(repo: repo, of: "p").isEmpty)
    }

    // MARK: canonical parse

    @Test("classify — local vs origin/ remote")
    func classifyRefs() async throws {
        let repo = try Self.makeRepo(withOrigin: true)
        let lin = BranchLineage()
        let local = await lin.classify(repo: repo, ref: "feature-a")
        #expect(local.isRemote == false)
        #expect(local.shortName == "feature-a")
        let remote = await lin.classify(repo: repo, ref: "origin/feature-b")
        #expect(remote.isRemote == true)
        #expect(remote.shortName == "feature-b")
        // A local branch name that merely contains a slash (no remote named `feature`) stays local.
        let slashed = await lin.classify(repo: repo, ref: "feature/foo")
        #expect(slashed.isRemote == false)
        #expect(slashed.shortName == "feature/foo")
    }
}
