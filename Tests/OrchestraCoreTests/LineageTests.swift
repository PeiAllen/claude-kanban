import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

/// Unit-converted (Task 10, branch-tree). BranchLineage is pure `git config` CRUD; every case runs
/// over `FakeProc` + `GitConfigEmulator` — no real git, no filesystem. The emulator's fidelity to real
/// `git config` (the license for this whole suite) is pinned by ContractTests/Git/GitConfigContractTests.
@Suite("BranchLineage — git-config lineage CRUD + tree queries")
struct LineageTests {

    /// A fresh FakeProc with the config emulator installed, and a BranchLineage over it. `repo` is an
    /// opaque label (the emulator keys its in-memory store by it — no directory is created).
    private func env() -> (fake: FakeProc, lin: BranchLineage, repo: String) {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        return (fake, BranchLineage(proc: fake), "/repo")
    }

    // S4: a `set` that fails part-way must leave the PRIOR link intact — never a torn old-parent/new-base
    // state. Original drove this with a real `.git/config.lock`; here the fake fails the final parent-key
    // write of the re-point (the real config.lock write-failure shape is pinned by GitConfigContractTests).
    @Test("S4: a failed re-point leaves the prior link intact")
    func setPartialWriteKeepsPrior() async throws {
        let fake = FakeProc()
        // Fail ONLY the second re-point's parent-key write (the last write of `set`), so the base write
        // already landed and the rollback path must restore the prior link.
        fake.on(["git"]) { argv in
            if argv.count >= 6, argv[3] == "config",
               argv[4] == "branch.child.orchestra-parent", argv[5] == "p2" {
                return ProcResult(stdout: "", stderr: "fatal: could not lock config file .git/config", exitCode: 255)
            }
            return nil
        }
        GitConfigEmulator().install(on: fake)
        let lin = BranchLineage(proc: fake)
        try await lin.set(repo: "/repo", branch: "child", link: ParentLink(parent: "p1", base: "aaa"))
        await #expect(throws: (any Error).self) {
            try await lin.set(repo: "/repo", branch: "child", link: ParentLink(parent: "p2", base: "bbb"))
        }
        let link = try #require(await lin.read(repo: "/repo", branch: "child"))
        #expect(link.parent == "p1")   // prior parent, NOT a torn p1+bbb or p2
        #expect(link.base == "aaa")
    }

    // MARK: CRUD round-trips

    @Test("set/read round-trip — local parent")
    func roundTripLocal() async throws {
        let (_, lin, repo) = env()
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
        let (_, lin, repo) = env()
        try await lin.set(repo: repo, branch: "child",
                          link: ParentLink(parent: "origin/feature-b", base: "cafe", prNumber: 12, watch: true))
        let got = try #require(await lin.read(repo: repo, branch: "child"))
        #expect(got.parent == "origin/feature-b")
        #expect(got.prNumber == 12)
        #expect(got.watch == true)
    }

    @Test("clear removes all orchestra-* keys")
    func clearAll() async throws {
        let (_, lin, repo) = env()
        try await lin.set(repo: repo, branch: "child",
                          link: ParentLink(parent: "p", base: "b", prNumber: 3, watch: true))
        try await lin.clear(repo: repo, branch: "child")
        #expect(await lin.read(repo: repo, branch: "child") == nil)
    }

    @Test("updateBase rewrites only the base OID")
    func updateBaseOnly() async throws {
        let (_, lin, repo) = env()
        try await lin.set(repo: repo, branch: "child", link: ParentLink(parent: "p", base: "old"))
        try await lin.updateBase(repo: repo, branch: "child", oid: "new")
        let got = try #require(await lin.read(repo: repo, branch: "child"))
        #expect(got.parent == "p")
        #expect(got.base == "new")
    }

    @Test("read of an unlinked branch → nil")
    func readUnlinked() async throws {
        let (_, lin, repo) = env()
        #expect(await lin.read(repo: repo, branch: "nope") == nil)
    }

    // MARK: cycle guard

    @Test("self-parent rejected")
    func selfParentRejected() async throws {
        let (_, lin, repo) = env()
        await #expect(throws: OrchestraError.self) {
            try await lin.set(repo: repo, branch: "x", link: ParentLink(parent: "x", base: "b"))
        }
    }

    @Test("a cycle is rejected — root adopting its own descendant")
    func cycleRejected() async throws {
        // a → b → c  (a.parent=b, b.parent=c). Now try c.parent=a, which closes a→b→c→a.
        let (_, lin, repo) = env()
        try await lin.set(repo: repo, branch: "a", link: ParentLink(parent: "b", base: "1"))
        try await lin.set(repo: repo, branch: "b", link: ParentLink(parent: "c", base: "1"))
        await #expect(throws: OrchestraError.self) {
            try await lin.set(repo: repo, branch: "c", link: ParentLink(parent: "a", base: "1"))
        }
    }

    // MARK: children / ancestors

    @Test("children finds every branch whose parent is the target (fan-out)")
    func childrenFanOut() async throws {
        let (_, lin, repo) = env()
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
        let (_, lin, repo) = env()
        try await lin.set(repo: repo, branch: "c1", link: ParentLink(parent: "target", base: "target"))
        #expect(await lin.children(repo: repo, of: "target") == ["c1"])   // once, from the parent key only
    }

    @Test("ancestors walks the parent chain nearest-first")
    func ancestorsChain() async throws {
        let (_, lin, repo) = env()
        try await lin.set(repo: repo, branch: "a", link: ParentLink(parent: "b", base: "1"))
        try await lin.set(repo: repo, branch: "b", link: ParentLink(parent: "c", base: "1"))
        #expect(await lin.ancestors(repo: repo, of: "a") == ["b", "c"])
    }

    @Test("foreign git-config keys are untouched by clear + ignored by children")
    func foreignKeysUntouched() async throws {
        let (fake, lin, repo) = env()
        // A non-orchestra key set through the same emulator store.
        _ = try await fake.run(["git", "-C", repo, "config", "branch.child.description", "hello"],
                               cwd: nil, env: [:], timeout: nil)
        try await lin.set(repo: repo, branch: "child", link: ParentLink(parent: "p", base: "b"))
        try await lin.clear(repo: repo, branch: "child")
        // The non-orchestra key survives.
        let desc = try await fake.run(["git", "-C", repo, "config", "--get", "branch.child.description"],
                                      cwd: nil, env: [:], timeout: nil)
        #expect(desc.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        // A branch with only a description (no orchestra-parent) is not a child.
        #expect(await lin.children(repo: repo, of: "p").isEmpty)
    }

    // MARK: canonical parse

    // O4/S4: `BranchLineage.classify` was deleted (dead + disagreed with RemoteParentRef.parse).
    // Remote-vs-local classification now runs through `RemoteParentRef.parse(_:remotes:)` — see
    // RemoteParentRefTests. This case is retained (renamed) to prove the seam classifies the same way.
    @Test("RemoteParentRef.parse — local vs remote (replaces the deleted classify)")
    func parseClassifies() async throws {
        let remotes = ["origin"]
        #expect(RemoteParentRef.parse("feature-a", remotes: remotes) == nil)             // local
        #expect(RemoteParentRef.parse("origin/feature-b", remotes: remotes)
                == .branch(remote: "origin", name: "feature-b"))                          // remote
        #expect(RemoteParentRef.parse("feature/foo", remotes: remotes) == nil)           // local slashed
    }

    // MARK: proc seam

    @Test("lineage round-trips through the proc seam — no filesystem, no git")
    func lineageOverFakeProc() async throws {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        fake.on(["git", "rev-parse"]) { _ in ProcResult(stdout: "abc123\n", stderr: "", exitCode: 0) }  // fall-through composition
        let lineage = BranchLineage(proc: fake)
        try await lineage.set(repo: "/nonexistent/repo", branch: "child",
                              link: ParentLink(parent: "main", base: "abc123"))
        let rec = await lineage.read(repo: "/nonexistent/repo", branch: "child")
        #expect(rec?.parent == "main")
        #expect(rec?.base == "abc123")
        // Fall-through composition: the emulator's broad ["git"] rule returned nil for this shape,
        // so the later ["git", "rev-parse"] rule answered.
        let rp = try await fake.run(["git", "rev-parse", "HEAD"], cwd: nil, env: [:], timeout: nil)
        #expect(rp.stdout == "abc123\n")
        #expect(fake.calls.contains { $0.argv.starts(with: ["git", "-C", "/nonexistent/repo", "config"]) })
    }
}
