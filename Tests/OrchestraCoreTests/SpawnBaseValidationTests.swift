import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// S2-3: spawn lineage failures fire AFTER the worktree is cut. (i) a user-supplied `refs/`-prefixed
/// local base double-prefixes in recordSpawnBase; (ii) a dangling `orchestra-parent` value (deleted
/// parent, name reused) trips a false cycle; both leave an orphan worktree + branch that a retry
/// silently adopts with no base.
///
/// Unit-converted (Task 10, card-lifecycle): the normalization / prune / cycle-guard LOGIC runs over
/// FakeProc (RepoGraph pinned by GitRevContractTests; lineage in GitConfigEmulator pinned by
/// GitConfigContractTests). Two real-worktree effects are split out, never dropped:
///   - the bad-base rejection's on-disk half (no `refs/heads/child` created) → moved to
///     ContractTests/Git/WorktreeAddContractTests.addBadBaseRejected;
///   - `rollbackOnLineageFailure`'s real `.git/config.lock` write-failure + real-branch rollback stays
///     real git in place as a MOVER (the unit analogue — a lineage-record failure → dead + tree released
///     force:false — is StepperConvergeTests.test_materializeLineageRecordFailureRollsBack).
@Suite("Spawn base validation + rollback + dangling cycle guard (S2-3)")
struct SpawnBaseValidationTests {

    /// A service whose git seam is a FakeProc carrying the config emulator. Callers install their own
    /// RepoGraph on `fake` for the branch shape they need. Returns (svc, fake, an allowlisted repo dir).
    static func fakeSvc() -> (svc: OrchestraService, fake: FakeProc, repo: String) {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let (svc, _, _, _, _, base) = TestEnv.make(proc: fake)
        return (svc, fake, TestEnv.repo(base))
    }

    /// LEGACY real-git fixture — consumed only by `rollbackOnLineageFailure` (the kept-real mover). A real
    /// repo (real worktree manager, via the registry) on `main` with a `foo` branch. Returns (svc, repo).
    static func repo() throws -> (svc: OrchestraService, repo: String) {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func g(_ a: String...) throws { #expect(try Proc.run(["git", "-C", repo] + a).ok) }
        try g("init", "-q", "-b", "main"); try g("config", "user.email", "t@t"); try g("config", "user.name", "t")
        try "0\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try g("add", "-A"); try g("commit", "-q", "-m", "base"); try g("branch", "foo")
        return (svc, repo)
    }

    @Test("S2-3(i): a refs/heads/-prefixed local base is normalized to the bare branch name")
    func normalizesRefsHeadsBase() async throws {
        let (svc, fake, repo) = Self.fakeSvc()
        let g = RepoGraph(); g.commit(on: "main"); g.branch("foo", at: "main"); g.install(on: fake)
        // Normalization is a SYNCHRONOUS spawn-time step: the carrier is the bare name.
        let card = try await svc.spawn(SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child", base: "refs/heads/foo"))
        #expect(card.spawnBase == "foo")
        // The reconciler-driven materialize records the lineage from that carrier.
        try await pollUntil {
            await svc.reconcile()
            return await svc.list().first { $0.id == card.id }?.phase.kind == .live
        }
        #expect(await svc.list().first { $0.id == card.id }?.parentBranch == "foo")
        let link = try #require(await svc.lineage.read(repo: repo, branch: "child"))
        #expect(link.parent == "foo")
    }

    @Test("S2-3(i): a non-branch refs/ base (e.g. a tag ref) is rejected before anything is created")
    func rejectsNonBranchRefsBase() async throws {
        let (svc, _, repo) = Self.fakeSvc()
        // The throw is service-observable (validated synchronously in spawn, before any git or ensure).
        await #expect(throws: OrchestraError.self) {
            _ = try await svc.spawn(SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child", base: "refs/tags/v1"))
        }
        // The on-disk half — a rejected bad base leaves NO `refs/heads/child` for a retry to adopt — is a
        // real-worktree effect (the stub cuts no real branch), pinned by
        // ContractTests/Git/WorktreeAddContractTests.addBadBaseRejected.
    }

    @Test("S2-3(ii): a dangling orchestra-parent value (deleted parent, name reused) is not a false cycle")
    func danglingParentValueNoFalseCycle() async throws {
        let (svc, fake, repo) = Self.fakeSvc()
        // feat-x with a child feat-x-fix that records feat-x as its parent.
        let g = RepoGraph(); g.commit(on: "main"); g.branch("feat-x", at: "main")
        g.branch("feat-x-fix", at: "feat-x"); g.install(on: fake)
        let fxTip = g.tip("feat-x")!
        try await BranchLineage(proc: fake).set(repo: repo, branch: "feat-x-fix",
                                      link: ParentLink(parent: "feat-x", base: fxTip))
        // Delete feat-x — its branch ref goes, but feat-x-fix.orchestra-parent = feat-x now dangles.
        g.deleteBranch("feat-x")

        // Reuse the name: spawn a NEW feat-x on top of feat-x-fix. Materialize's prune must clear the
        // dangling link so no false cycle is tripped (else recordSpawnBase's cycle guard rejects → dead).
        let card = try await svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "feat-x", base: "feat-x-fix"))
        try await pollUntil {
            await svc.reconcile()
            return await svc.list(includeArchived: true).first { $0.id == card.id }?.phase.kind == .live
        }
        #expect(await svc.list().first { $0.id == card.id }?.parentBranch == "feat-x-fix")
    }

    // MOVER (kept real git, Task 10 card-lifecycle): the rollback is driven by a real `.git/config.lock`
    // held during `recordSpawnBase`'s `git config` write, and its teeth is a REAL on-disk branch rollback
    // (`rev-parse --verify refs/heads/nb` → false). Both are real-git integration effects; left real in
    // place. The service-level analogue (a lineage-record failure → dead + tree released force:false) is
    // StepperConvergeTests.test_materializeLineageRecordFailureRollsBack.
    @Test("S2-3(iii): a lineage-record failure rolls back the just-created worktree + branch")
    func rollbackOnLineageFailure() async throws {
        let (svc, repo) = try Self.repo()
        // Force the `git config` write in recordSpawnBase to fail by holding the config lock — the
        // failure fires AFTER `ensure` cut the worktree + branch, exercising the rollback path.
        let lock = repo + "/.git/config.lock"
        FileManager.default.createFile(atPath: lock, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: lock) }

        // Non-blocking spawn: the lineage-record failure + rollback now fire inside the reconciler-driven
        // MaterializeStepper (the card goes .dead(.spawnFailed)), not as a synchronous throw from spawn.
        let card = try await svc.spawn(SpawnInput(id: UUID(), prompt: "n", repo: repo, branch: "nb", base: "foo"))
        try await pollUntil {
            await svc.reconcile()
            return await svc.list(includeArchived: true).first { $0.id == card.id }?.phase.kind == .dead
        }
        try? FileManager.default.removeItem(atPath: lock)   // release before asserting (rev-parse is a read)
        // Rolled back: the just-created nb branch is gone (no orphan for a retry to silently adopt).
        #expect(try Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/nb"]).ok == false)
    }
}
