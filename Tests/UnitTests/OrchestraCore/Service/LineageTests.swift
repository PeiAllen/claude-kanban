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

    // MARK: child-progress counters (slice 4)

    @Test("mergedCount defaults to 0; setPlanned/plannedCount round-trip; n<=0 clears")
    func plannedAndMergedBasics() async throws {
        let (_, lin, repo) = env()
        #expect(await lin.mergedCount(repo: repo, branch: "p") == 0)
        #expect(await lin.plannedCount(repo: repo, branch: "p") == nil)
        try await lin.setPlanned(repo: repo, branch: "p", n: 4)
        #expect(await lin.plannedCount(repo: repo, branch: "p") == 4)
        try await lin.setPlanned(repo: repo, branch: "p", n: 0)   // 0 clears
        #expect(await lin.plannedCount(repo: repo, branch: "p") == nil)
        try await lin.setPlanned(repo: repo, branch: "p", n: 7)
        try await lin.setPlanned(repo: repo, branch: "p", n: -1)  // negative also clears
        #expect(await lin.plannedCount(repo: repo, branch: "p") == nil)
    }

    @Test("recordMergedChild removes the child link and increments the parent's merged-count")
    func recordMergedChildCounts() async throws {
        let (_, lin, repo) = env()
        try await lin.set(repo: repo, branch: "c", link: ParentLink(parent: "p", base: "b"))
        #expect(await lin.recordMergedChild(repo: repo, child: "c", expectedParent: "p") == .counted)
        #expect(await lin.read(repo: repo, branch: "c") == nil)          // link removed
        #expect(await lin.mergedCount(repo: repo, branch: "p") == 1)
    }

    @Test("dual-observer / restart re-detection: a 2nd recordMergedChild finds no link → .absent, no double-count")
    func recordMergedChildIdempotent() async throws {
        let (_, lin, repo) = env()
        try await lin.set(repo: repo, branch: "c", link: ParentLink(parent: "p", base: "b"))
        #expect(await lin.recordMergedChild(repo: repo, child: "c", expectedParent: "p") == .counted)
        // The second observer (shipped + a future merge-watch, or a post-restart "is ancestor" re-detection):
        // the entry-existence guard trips — no link → .absent → the count is NOT bumped again.
        #expect(await lin.recordMergedChild(repo: repo, child: "c", expectedParent: "p") == .absent)
        #expect(await lin.mergedCount(repo: repo, branch: "p") == 1)
    }

    @Test("recordMergedChild against a re-parented child (parent mismatch) → .linkChanged, no count")
    func recordMergedChildLinkChanged() async throws {
        let (_, lin, repo) = env()
        try await lin.set(repo: repo, branch: "c", link: ParentLink(parent: "pNew", base: "b"))
        #expect(await lin.recordMergedChild(repo: repo, child: "c", expectedParent: "pOld") == .linkChanged)
        #expect(await lin.read(repo: repo, branch: "c")?.parent == "pNew")   // fresh link untouched
        #expect(await lin.mergedCount(repo: repo, branch: "pOld") == 0)
    }

    @Test("a NON-merge removal (plain clear — re-parent / abandoned-branch cleanup) never bumps the counter")
    func plainClearNeverCounts() async throws {
        let (_, lin, repo) = env()
        try await lin.set(repo: repo, branch: "c", link: ParentLink(parent: "p", base: "b"))
        try await lin.clear(repo: repo, branch: "c")   // the non-merge removal path
        #expect(await lin.mergedCount(repo: repo, branch: "p") == 0)
    }

    @Test("clear-first crash window: an increment failure after removal → bounded undercount, never a double-count")
    func crashWindowUndercountNeverDouble() async throws {
        let fake = FakeProc()
        // Fail ONLY the merged-count WRITE (argv[4] is the key, argv[5] the value) — a crash between the
        // clear and the bump. Registered BEFORE the emulator so it short-circuits that one write.
        fake.on(["git"]) { argv in
            if argv.count >= 6, argv[3] == "config",
               argv[4] == "branch.p.orchestra-merged-count", argv[5] != "--get" {
                return ProcResult(stdout: "", stderr: "fatal: could not lock config file", exitCode: 255)
            }
            return nil
        }
        GitConfigEmulator().install(on: fake)
        let lin = BranchLineage(proc: fake)
        try await lin.set(repo: "/repo", branch: "c", link: ParentLink(parent: "p", base: "b"))
        _ = await lin.recordMergedChild(repo: "/repo", child: "c", expectedParent: "p")
        #expect(await lin.read(repo: "/repo", branch: "c") == nil)   // clear-first: the removal DID land
        // Re-detection finds no entry → .absent → it CANNOT recount. The only crash outcome is a bounded
        // undercount (count stuck at 0), never the double-count an increment-first ordering would produce.
        #expect(await lin.recordMergedChild(repo: "/repo", child: "c", expectedParent: "p") == .absent)
        #expect(await lin.mergedCount(repo: "/repo", branch: "p") == 0)
    }

    @Test("counter keys are NOT lineage-link keys: clear leaves a parent's merged-count intact")
    func clearDoesNotWipeCounters() async throws {
        let (_, lin, repo) = env()
        // p has a merged child (count 1) AND its own parent link.
        try await lin.set(repo: repo, branch: "c", link: ParentLink(parent: "p", base: "b"))
        _ = await lin.recordMergedChild(repo: repo, child: "c", expectedParent: "p")
        try await lin.set(repo: repo, branch: "p", link: ParentLink(parent: "gp", base: "b"))
        try await lin.setPlanned(repo: repo, branch: "p", n: 3)
        // Clearing p's OWN lineage link must not touch its child-progress counters (they live on the same
        // branch config but are deliberately out of `allSuffixes`).
        try await lin.clear(repo: repo, branch: "p")
        #expect(await lin.read(repo: repo, branch: "p") == nil)
        #expect(await lin.mergedCount(repo: repo, branch: "p") == 1)
        #expect(await lin.plannedCount(repo: repo, branch: "p") == 3)
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
