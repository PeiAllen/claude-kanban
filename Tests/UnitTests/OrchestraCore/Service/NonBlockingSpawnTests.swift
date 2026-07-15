import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// A FakeProc carrying the git-config emulator — the seam the converted non-blocking-spawn tests hand to
/// `TestEnv.make(proc:)`. Cases that record a base install their own `RepoGraph` on it (main + parent).
private func cfgFake() -> FakeProc {
    let f = FakeProc()
    GitConfigEmulator().install(on: f)
    return f
}

/// PR4b Task 3 — the FLAG-DAY: `spawn` is now NON-BLOCKING. Its synchronous part shrinks to persist a
/// `.creatingWorktree` card (+ the security allowlist / base-validation fail-fasts) and RETURN; the
/// reconciler's steppers (Materialize → Launch) drive it to `.live`. These tests pin that contract.
///
/// Unit-converted (Task 10, card-lifecycle): the whole suite runs over FakeProc — no real git.
/// `RepoGraph`/`GitConfigEmulator` (pinned by GitRevContractTests / GitConfigContractTests) stand in for
/// the base branch + lineage config; the real-worktree HEAD effects live in
/// ContractTests/Git/WorktreeAddContractTests.
@Suite("Non-blocking spawn (reconciler-driven) — PR4b Task 3")
struct NonBlockingSpawnTests {

    /// Drive `reconcile()` until `id` is `.live`, hand-delivering the launch-ready signal each tick the card
    /// is `.launching` (harmless for immediate caps; required for the awaited caps' own-signal path).
    private func driveToLive(_ svc: OrchestraService, _ id: UUID, inject: Bool) async throws {
        try await pollUntil {
            await svc.reconcile()
            let card = await svc.list(includeArchived: true).first { $0.id == id }
            if inject, card?.phase.kind == .launching {
                try? await svc.report(id, StatusReport(sessionSource: "startup"))
            }
            return card?.phase.kind == .live
        }
    }

    @Test("test_spawnReturnsBeforeProvisioned")
    func test_spawnReturnsBeforeProvisioned() async throws {
        let env = TestEnv.make(proc: cfgFake())
        let repo = TestEnv.repo(env.base)
        env.worktrees.blockEnsure()   // the NEXT ensure (materialize's) parks on a gate

        // spawn does NO checkout — it returns a `.creatingWorktree` card with a PURE cwd immediately.
        let created = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        #expect(created.phase.kind == .creatingWorktree)
        #expect(created.cwd.contains("/b"))                         // cwd computed (no ensure)
        #expect(env.worktrees.ensured.isEmpty)                      // spawn never called ensure

        // Kick reconcile so the MaterializeStepper dispatches off-actor and PARKS inside `ensure`.
        await env.svc.reconcile()

        // The actor is NOT frozen: a concurrent `list()` answers promptly while `ensure` is blocked.
        let listed = await env.svc.list(includeArchived: true)
        #expect(listed.contains { $0.id == created.id })

        // Release the gate and let the reconciler drive it the rest of the way to live.
        env.worktrees.releaseEnsure()
        try await driveToLive(env.svc, created.id, inject: false)
        let live = try #require(await env.svc.list().first { $0.id == created.id })
        #expect(live.phase.kind == .live)
        #expect(env.worktrees.ensured.contains("\(repo)#b"))        // materialize cut the tree
    }

    @Test("test_spawnStepperCrashRestart", arguments: [AgentCapabilities.claudeCode,
                                                        ReadinessSignalTests.codexStubCaps])
    func test_spawnStepperCrashRestart(caps: AgentCapabilities) async throws {
        let env = TestEnv.make(grace: 30, capabilities: caps, proc: cfgFake())
        let repo = TestEnv.repo(env.base)

        // spawn persists `.creatingWorktree`; drive ONE materialize step so it lands `.launching`, then
        // simulate a daemon crash BEFORE the launch confirmed — `remake` reloads the persisted card only.
        let created = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list().first { $0.id == created.id }?.phase.kind == .launching
        }
        let env2 = TestEnv.remake(base: env.base, capabilities: caps, proc: cfgFake())

        // The fresh daemon's reconciler must converge the stranded `.launching` card to `.live` — no
        // duplicate card, exactly one session.
        try await driveToLive(env2.svc, created.id, inject: true)
        let all = await env2.svc.list(includeArchived: true)
        #expect(all.filter { $0.id == created.id }.count == 1)
        #expect(all.filter { $0.branch == "b" }.count == 1)         // no duplicate card
        let live = try #require(all.first { $0.id == created.id })
        #expect(live.phase.kind == .live)
        let names = try env2.sessions.list().map(\.name)
        #expect(names.filter { $0 == env2.sessions.sessionName(created.id) }.count == 1)
    }

    @Test("test_spawnFailureClassified")
    func test_spawnFailureClassified() async throws {
        // (a) a checkout failure → dead(.spawnFailed) with the git stderr in deadDetail.
        let env = TestEnv.make(proc: cfgFake())
        let repo = TestEnv.repo(env.base)
        let created = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        env.worktrees.ensureError = OrchestraError.io("fatal: could not checkout branch")
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list(includeArchived: true).first { $0.id == created.id }?.phase.kind == .dead
        }
        let a = try #require(await env.svc.list(includeArchived: true).first { $0.id == created.id })
        #expect(a.phase == .dead(.spawnFailed))
        #expect(a.deadDetail?.contains("could not checkout branch") == true)

        // (b) a timeout → the explicit "timed out after Ns" wording (no generic git passthrough).
        let env2 = TestEnv.make(proc: cfgFake())
        let repo2 = TestEnv.repo(env2.base)
        let c2 = try await env2.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo2, branch: "b"))
        env2.worktrees.ensureError = OrchestraError.io("git worktree add: operation timed out")
        try await pollUntil {
            await env2.svc.reconcile()
            return await env2.svc.list(includeArchived: true).first { $0.id == c2.id }?.phase.kind == .dead
        }
        let b = try #require(await env2.svc.list(includeArchived: true).first { $0.id == c2.id })
        let timeout = await env2.svc.config.worktreeAddTimeout
        #expect(b.phase == .dead(.spawnFailed))
        #expect(b.deadDetail == "worktree checkout timed out after \(timeout)s")
    }

    /// Task-1 Minor #2: a crash cut the branch but `recordSpawnBase` never ran — a re-run sees
    /// `branchExisted == true` yet no lineage link, and must RE-RECORD the carried base (idempotent) rather
    /// than fall through the "existing branch → derive from config" path (which would lose the parent link).
    @Test("test_materializeReRecordsBaseAfterCrashWindow")
    func test_materializeReRecordsBaseAfterCrashWindow() async throws {
        let fake = cfgFake()
        RepoScripts.withParent(on: fake)                               // main + a `parent` branch (modelled)
        let env = TestEnv.make(proc: fake)
        let repo = TestEnv.repo(env.base)
        let created = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child", base: "parent"))
        #expect(created.spawnBase == "parent")                          // base carried, not yet recorded

        // Simulate the crash window: the branch already exists (a prior run cut it) but NO lineage link was
        // recorded. `markBranchExists` makes the stub report branchExisted == true.
        env.worktrees.markBranchExists("child")
        #expect(await env.svc.lineage.read(repo: repo, branch: "child") == nil)   // no link yet

        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list().first { $0.id == created.id }?.phase.kind == .live
        }
        // The re-run re-recorded the base: parent link present, parentBranch set, carrier consumed.
        let link = try #require(await env.svc.lineage.read(repo: repo, branch: "child"))
        #expect(link.parent == "parent")
        let after = try #require(await env.svc.list().first { $0.id == created.id })
        #expect(after.parentBranch == "parent")
        #expect(after.spawnBase == nil)
    }

    /// Deferred from Task 1: `materialize`'s stale-child prune (S2-3(ii)). A brand-new branch cannot have had
    /// children, so a dangling `orchestra-parent == <this branch>` (a deleted same-named branch's leftover)
    /// is cleared before recording, so the cycle guard doesn't reject a legitimate name reuse.
    @Test("test_materializeStaleChildPrune")
    func test_materializeStaleChildPrune() async throws {
        let fake = cfgFake()
        let graph = RepoGraph(); graph.commit(on: "main"); graph.branch("feat-x", at: "main")
        graph.branch("feat-x-fix", at: "feat-x"); graph.install(on: fake)
        let (svc, _, _, _, _, base) = TestEnv.make(proc: fake)
        let repo = TestEnv.repo(base)
        // feat-x with a child feat-x-fix recording feat-x as parent; then delete feat-x (its branch ref
        // goes, but feat-x-fix.orchestra-parent = feat-x now dangles).
        let fxTip = graph.tip("feat-x")!
        try await svc.lineage.set(repo: repo, branch: "feat-x-fix", link: ParentLink(parent: "feat-x", base: fxTip))
        graph.deleteBranch("feat-x")

        // Reuse the name: spawn a NEW feat-x on top of feat-x-fix. Materialize's prune must clear the dangling
        // link so no false cycle is tripped; the card reaches launching with parentBranch = feat-x-fix.
        let card = try await svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "feat-x", base: "feat-x-fix"))
        try await pollUntil {
            await svc.reconcile()
            let p = await svc.list(includeArchived: true).first { $0.id == card.id }?.phase.kind
            return p == .live || p == .launching || p == .dead
        }
        let after = try #require(await svc.list(includeArchived: true).first { $0.id == card.id })
        #expect(after.phase.kind != .dead)                              // no false cycle
        #expect(after.parentBranch == "feat-x-fix")
    }
}
