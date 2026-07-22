import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

// PR4b Task 1 — the four phase-keyed steppers driven DIRECTLY (no reconciler, no verb changes) via
// `env.svc.convergeContext()` + `stepper.step(card, ctx)`, plus the ConvergeContext extensions and the
// `spawnBase` carrier they depend on.
//
// Unit-converted (Task 10, card-lifecycle): the stepper/rollback/converge LOGIC runs over `FakeProc`
// carrying `GitConfigEmulator` (lineage CRUD, pinned to real git by ContractTests/Git/GitConfigContractTests)
// — no real git. The two REMOTE cases (real-worktree-HEAD / real-fetch effects a fake cannot carry) were
// extracted at the flip to ContractTests/Git/StepperConvergeRemoteContractTests; their worktree-add essence
// is also pinned by ContractTests/Git/WorktreeAddContractTests + RemoteFetchContractTests.

/// A FakeProc carrying just the git-config emulator — the seam the converted stepper tests hand to
/// `TestEnv.make(proc:)`. These cases exercise reconciler/rollback LOGIC (ensureError injection,
/// removedForce routing, cwd, epoch stamping, child nudges), not commit-graph reads, so no RepoGraph is
/// installed; a bad local `spawnBase`'s `recordSpawnBase` throw is faithfully produced by the emulator-only
/// fake yielding no `rev-parse` OID (exactly the "non-git repo → git fails → throw" the old real dir gave).
private func cfgFake() -> FakeProc {
    let f = FakeProc()
    GitConfigEmulator().install(on: f)
    return f
}

// MARK: - Step 0 · ConvergeContext + spawnBase carrier

@Suite("ConvergeContext extensions + spawnBase carrier (PR4b Task 1)")
struct ConvergeContextTests {

    @Test("test_convergeContextTransitionAppliesMutate")
    func test_convergeContextTransitionAppliesMutate() async throws {
        let env = TestEnv.make(proc: cfgFake())
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        _ = try await env.svc.store.update(card.id) { $0.phase = .creatingWorktree }
        let ctx = await env.svc.convergeContext()
        // The mutate form lands the phase AND the companion field-write in ONE store patch.
        _ = await ctx.transition(card.id, .launching, nil, .creatingWorktree) { $0.parentBranch = "main"; $0.spawnBase = nil }
        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.phase.kind == .launching)         // both assertions on a single read ⇒ atomic
        #expect(after.parentBranch == "main")
    }

    @Test("test_spawnBaseCarrierRoundTrips")
    func test_spawnBaseCarrierRoundTrips() throws {
        let t = Task(title: "x", repo: "/r", branch: "b", cwd: "/r/b", model: AgentModel(id: "m"),
                     startIn: .impl, column: .impl, order: 0, spawnBase: "origin/feature-x", initialPrompt: "")
        let back = try OrchestraJSON.decoder.decode(Task.self, from: OrchestraJSON.pretty.encode(t))
        #expect(back.spawnBase == "origin/feature-x")
        // Additive-optional: a nil carrier emits no key and decodes back to nil (legacy record safe).
        let t2 = Task(title: "y", repo: "/r", branch: "b2", cwd: "/r/b2", model: AgentModel(id: "m"),
                      startIn: .impl, column: .impl, order: 0, initialPrompt: "")
        let d2 = try OrchestraJSON.pretty.encode(t2)
        #expect(!(String(data: d2, encoding: .utf8) ?? "").contains("spawnBase"))
        #expect(try OrchestraJSON.decoder.decode(Task.self, from: d2).spawnBase == nil)
    }
}

// MARK: - MaterializeStepper (drives .creatingWorktree)

@Suite("MaterializeStepper (PR4b Task 1)")
struct MaterializeStepperTests {

    /// Spawn a live card, then force it back to `.creatingWorktree` (a direct store write — being-born
    /// phases aren't reachable by a legal verb edge), optionally mutating it.
    private func seedCreating(_ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
                              branch: String, prompt: String = "x",
                              _ mutate: @Sendable @escaping (inout Task) -> Void = { _ in }) async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: prompt, repo: repo, branch: branch))
        _ = try await env.svc.store.update(card.id) { $0.phase = .creatingWorktree; mutate(&$0) }
        // Remove the tree spawn already cut so `materialize` genuinely re-cuts via `manager.ensure`
        // (an existing dir+marker would be ADOPTED, skipping the manager call the tests observe).
        try? FileManager.default.removeItem(atPath: card.cwd)
        return try #require(await env.svc.store.get(card.id))
    }

    @Test("test_materializeStepAdvancesToLaunching")
    func test_materializeStepAdvancesToLaunching() async throws {
        let env = TestEnv.make(proc: cfgFake())
        let card = try await seedCreating(env, branch: "b")
        let before = env.worktrees.ensured.count
        let ctx = await env.svc.convergeContext()
        try await MaterializeStepper().step(card, ctx)
        #expect(env.worktrees.ensured.count == before + 1)   // ensure called once
        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.phase.kind == .launching)
        #expect(await MaterializeStepper().verify(after, ctx))
    }

    @Test("test_materializeFailureClassified")
    func test_materializeFailureClassified() async throws {
        // (a) an ensure that throws → dead(.spawnFailed), git stderr in deadDetail.
        let env = TestEnv.make(proc: cfgFake())
        let card = try await seedCreating(env, branch: "b")
        env.worktrees.ensureError = OrchestraError.io("fatal: bad object HEAD")
        let ctx = await env.svc.convergeContext()
        try await MaterializeStepper().step(card, ctx)
        let a = try #require(await env.svc.store.get(card.id))
        #expect(a.phase == .dead(.spawnFailed))
        #expect(a.deadDetail?.contains("bad object HEAD") == true)

        // (b) a timeout → the explicit "timed out after Ns" wording (no generic passthrough).
        let env2 = TestEnv.make(proc: cfgFake())
        let card2 = try await seedCreating(env2, branch: "b")
        env2.worktrees.ensureError = OrchestraError.io("git worktree add: operation timed out")
        try await MaterializeStepper().step(card2, await env2.svc.convergeContext())
        let b = try #require(await env2.svc.store.get(card2.id))
        let timeout = await env2.svc.config.worktreeAddTimeout
        #expect(b.phase == .dead(.spawnFailed))
        #expect(b.deadDetail == "worktree checkout timed out after \(timeout)s")
    }

    @Test("test_materializeLineageRecordFailureRollsBack")
    func test_materializeLineageRecordFailureRollsBack() async throws {
        // A local `spawnBase` that `recordSpawnBase` can't resolve makes it throw AFTER `ensure` — the
        // S2-3(iii) rollback runs. The emulator-only fake (no RepoGraph) answers `rev-parse` with the empty
        // default, so `recordSpawnBase` throws exactly as it did on the old non-git repo. (a) with no sibling
        // the just-cut tree is released (force:false).
        let env = TestEnv.make(proc: cfgFake())
        let card = try await seedCreating(env, branch: "child") { $0.spawnBase = "main" }
        let ctx = await env.svc.convergeContext()
        try await MaterializeStepper().step(card, ctx)
        let a = try #require(await env.svc.store.get(card.id))
        #expect(a.phase == .dead(.spawnFailed))
        // Routed through release (guards intact); the manager call is forced only because release's
        // unsaved-work predicate cleared first — the (b) sibling case below is the policy proof.
        #expect(env.worktrees.removedForce.contains { $0.path == card.cwd && $0.force == true })

        // (b) a SHARED sibling on the same tree is NEVER removed by the rollback.
        let env2 = TestEnv.make(proc: cfgFake())
        let repo = TestEnv.repo(env2.base)
        let c1 = try await env2.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "shared"))
        let c2 = try await env2.svc.spawn(SpawnInput(id: UUID(), prompt: "y", repo: repo, branch: "shared"))  // co-located sibling
        #expect(c1.cwd == c2.cwd)
        _ = try await env2.svc.store.update(c1.id) { $0.phase = .creatingWorktree; $0.spawnBase = "main" }
        try? FileManager.default.removeItem(atPath: c1.cwd)   // force a genuine re-cut so recordSpawnBase runs
        let fresh = try #require(await env2.svc.store.get(c1.id))
        try await MaterializeStepper().step(fresh, await env2.svc.convergeContext())
        #expect(try #require(await env2.svc.store.get(c1.id)).phase == .dead(.spawnFailed))
        #expect(!env2.worktrees.removedForce.contains { $0.path == c1.cwd })   // sibling kept the tree
    }

    @Test("test_materializeResourceEpilogueReleasesOnArchive")
    func test_materializeResourceEpilogueReleasesOnArchive() async throws {
        // A newer intent made the card terminal — the epilogue (which re-reads AFTER the ensure await)
        // must release the just-cut tree and NOT advance to `.launching`. Deterministic (no wall-clock
        // race): the terminal phase is set before the step, and materialize's epilogue re-read sees it.
        let env = TestEnv.make(proc: cfgFake())
        let card = try await seedCreating(env, branch: "b")
        _ = try await env.svc.store.update(card.id) { $0.phase = .dead(.sessionVanished) }
        let fresh = try #require(await env.svc.store.get(card.id))
        try await MaterializeStepper().step(fresh, await env.svc.convergeContext())
        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.phase.kind == .dead)                                   // NOT launching
        #expect(env.worktrees.removedForce.contains { $0.path == card.cwd && $0.force == true })   // release cleared ⇒ forced
    }
}

// MARK: - LaunchStepper (drives .launching)

@Suite("LaunchStepper (PR4b Task 1)")
struct LaunchStepperTests {

    private func seedLaunching(_ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
                               branch: String, prompt: String = "x",
                               _ mutate: @Sendable @escaping (inout Task) -> Void = { _ in }) async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: prompt, repo: repo, branch: branch))
        _ = try await env.svc.store.update(card.id) { $0.phase = .launching; mutate(&$0) }
        return try #require(await env.svc.store.get(card.id))
    }

    @Test("test_launchFlavorDerivedFromState")
    func test_launchFlavorDerivedFromState() async throws {
        let env = TestEnv.make(proc: cfgFake())
        let repo = TestEnv.repo(env.base)
        // Resumable: agentSessionId + a transcript on disk → .resume (pendingSeed folded).
        let resumable = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "hi", repo: repo, branch: "b"))
        env.adapter.writeTranscript(for: resumable.agentSessionId!)
        _ = try await env.svc.store.update(resumable.id) { $0.pendingSeed = "SEED" }
        let rc = try #require(await env.svc.store.get(resumable.id))
        guard case .resume(let seed) = deriveLaunchFlavor(rc, env.adapter) else {
            Issue.record("expected .resume"); return
        }
        #expect(seed == "SEED")

        // A real (non-provisional) card with NO transcript → blank, initialPrompt submitted, landing .running.
        let blankReal = try #require(await env.svc.store.get(
            try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "do it", repo: repo, branch: "c")).id))
        guard case .blank(let land, let prompt) = deriveLaunchFlavor(blankReal, env.adapter) else {
            Issue.record("expected .blank"); return
        }
        #expect(prompt == "do it")
        #expect(land == .running)

        // A never-prompted (provisional) card → blank with NO positional, landing .waiting.
        let provisional = try #require(await env.svc.store.get(
            try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "", repo: repo, branch: "d")).id))
        guard case .blank(let land2, let prompt2) = deriveLaunchFlavor(provisional, env.adapter) else {
            Issue.record("expected .blank"); return
        }
        #expect(prompt2 == nil)
        #expect(land2 == .waiting(.humanTurn))
    }

    @Test("test_launchStepReachesLiveOnReady_immediate")   // .relaunchLiveness (stub) lands on ensure
    func test_launchStepReachesLiveOnReady_immediate() async throws {
        let env = TestEnv.make(proc: cfgFake())
        let card = try await seedLaunching(env, branch: "b")
        let ctx = await env.svc.convergeContext()
        try await LaunchStepper().step(card, ctx)
        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.phase.kind == .live)
        #expect(env.sessions.ensureArgv[env.sessions.sessionName(card.id)] != nil)
        #expect(await LaunchStepper().verify(after, ctx))   // session alive AT the current epoch
    }

    /// Seed a launching card WITHOUT blocking spawn on an awaited-cap readiness: bring it live via
    /// `spawnAwaited` (delivers the signal), then force it back to `.launching`.
    private func seedLaunchingAwaited(_ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
                                      branch: String) async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let live = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: branch))
        _ = try await env.svc.store.update(live.id) { $0.phase = .launching }
        return try #require(await env.svc.store.get(live.id))
    }

    @Test("test_launchStepReachesLiveOnReady_claude")   // .sessionStartHook awaits the signal
    func test_launchStepReachesLiveOnReady_claude() async throws {
        let env = TestEnv.make(grace: 10, capabilities: .claudeCode, proc: cfgFake())
        let card = try await seedLaunchingAwaited(env, branch: "b")
        let ctx = await env.svc.convergeContext()
        async let stepping: Void = LaunchStepper().step(card, ctx)
        // Wait until the step has REGISTERED its readiness waiter (past finishLaunch's "start clean"
        // pendingReadiness.remove) BEFORE delivering the signal — a fixed sleep races that clear under
        // parallel-suite contention and drops the signal (→ grace timeout). Deterministic seam, not wall-clock.
        try await pollUntil { await env.svc.hasReadinessWaiter(card.id) }
        try await env.svc.report(card.id, StatusReport(sessionSource: "startup"))   // the ready signal
        try await stepping
        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .live)
    }

    @Test("test_launchStepReachesLiveOnReady_codex")   // .rolloutMeta awaits; the ready signal resolves it
    func test_launchStepReachesLiveOnReady_codex() async throws {
        let env = TestEnv.make(grace: 10, capabilities: ReadinessSignalTests.codexStubCaps, proc: cfgFake())
        let card = try await seedLaunchingAwaited(env, branch: "b")
        let ctx = await env.svc.convergeContext()
        async let stepping: Void = LaunchStepper().step(card, ctx)
        try await pollUntil { await env.svc.hasReadinessWaiter(card.id) }   // waiter registered → signal can't be dropped
        try await env.svc.report(card.id, StatusReport(sessionSource: "startup"))
        try await stepping
        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .live)
    }

    @Test("test_launchConsumesPendingSeed")
    func test_launchConsumesPendingSeed() async throws {
        let env = TestEnv.make(proc: cfgFake())
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "hi", repo: repo, branch: "b"))
        env.adapter.writeTranscript(for: card.agentSessionId!)   // resumable ⇒ the seed folds into resume
        _ = try await env.svc.store.update(card.id) { $0.phase = .launching; $0.pendingSeed = "PAYLOAD-42" }
        let fresh = try #require(await env.svc.store.get(card.id))
        let ctx = await env.svc.convergeContext()
        try await LaunchStepper().step(fresh, ctx)
        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.phase.kind == .live)
        let argv = env.sessions.ensureArgv[env.sessions.sessionName(card.id)] ?? []
        #expect(argv.contains("PAYLOAD-42"))   // delivered via the resume seed
        #expect(after.pendingSeed == nil)       // cleared on readiness-at-current-epoch
    }
}

// MARK: - RelaunchStepper (drives .relaunching)

@Suite("RelaunchStepper (PR4b Task 1)")
struct RelaunchStepperTests {

    private func seedRelaunching(_ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
                                 branch: String,
                                 _ mutate: @Sendable @escaping (inout Task) -> Void = { _ in }) async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: branch))
        env.adapter.writeTranscript(for: card.agentSessionId!)   // resumable by default
        _ = try await env.svc.store.update(card.id) { $0.phase = .relaunching; $0.sessionEpoch = 7; mutate(&$0) }
        return try #require(await env.svc.store.get(card.id))
    }

    @Test("test_relaunchStepKillsThenEnsures")
    func test_relaunchStepKillsThenEnsures() async throws {
        let env = TestEnv.make(proc: cfgFake())
        let card = try await seedRelaunching(env, branch: "b")
        env.sessions.setAlive(card.id, true)   // an old session exists to be killed
        let ctx = await env.svc.convergeContext()
        try await RelaunchStepper().step(card, ctx)
        let name = env.sessions.sessionName(card.id)
        #expect(env.sessions.killed.contains(name))            // killed the predecessor
        #expect(env.sessions.ensureArgv[name] != nil)          // then ensured a fresh one
        #expect(env.sessions.ensureEnv[name]?["ORCH_EPOCH"] == "7")   // identity: current epoch stamped
        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .live)
    }

    @Test("test_relaunchReMaterializesMissingWorktree")
    func test_relaunchReMaterializesMissingWorktree() async throws {
        let env = TestEnv.make(proc: cfgFake())
        let card = try await seedRelaunching(env, branch: "b")
        try? FileManager.default.removeItem(atPath: card.cwd)   // the tree vanished under a live card
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        let before = env.worktrees.ensured.count
        try await RelaunchStepper().step(card, await env.svc.convergeContext())
        #expect(env.worktrees.ensured.count == before + 1)     // re-materialized
        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .live)
        #expect(await collector.activities.contains { $0.text.contains("re-materialized") })
    }

    @Test("test_relaunchBranchGoneFailsSafe")
    func test_relaunchBranchGoneFailsSafe() async throws {
        let env = TestEnv.make(proc: cfgFake())
        let card = try await seedRelaunching(env, branch: "b")
        try? FileManager.default.removeItem(atPath: card.cwd)   // tree gone → ensure must re-cut
        env.worktrees.ensureError = OrchestraError.io("fatal: branch 'b' not found")   // branch also gone → throws
        try await RelaunchStepper().step(card, await env.svc.convergeContext())
        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.phase == .dead(.resumeFailed))
    }
}

// MARK: - TeardownStepper (drives .archivedPending)

@Suite("TeardownStepper (PR4b Task 1)")
struct TeardownStepperTests {

    @Test("test_teardownFullDutyList_worktree")
    func test_teardownFullDutyList_worktree() async throws {
        let env = TestEnv.make(proc: cfgFake())
        let repo = TestEnv.repo(env.base)   // lineage lives in GitConfigEmulator (the fake) — no real git repo
        // Non-blocking spawn: drive to live so the worktree is genuinely materialized (marker recorded) —
        // teardown's release then has a real tree to reclaim.
        let parent = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await env.svc.lineage.set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: "deadbeef"))
        _ = try await env.svc.store.update(parent.id) { $0.phase = .archived(teardownComplete: false) }
        let fresh = try #require(await env.svc.store.get(parent.id))
        let ctx = await env.svc.convergeContext()
        try await TeardownStepper().step(fresh, ctx)

        let after = try #require(await env.svc.store.get(parent.id))
        #expect(after.phase.kind == .archivedComplete)                       // final flip
        #expect(after.archived)                                              // companion Bool mirror
        #expect(env.sessions.killed.contains(env.sessions.sessionName(parent.id)))   // session killed
        #expect(env.worktrees.removedForce.contains { $0.path == parent.cwd && $0.force == true })  // reclaim (release cleared ⇒ forced)
        let nudges = await ctx.inbox.peek(child.id)                          // deterministic child nudged
        #expect(nudges.count == 1)
        #expect(nudges.first?.text.contains("parent") == true)
    }

    @Test("test_teardownFullDutyList_scratch")
    func test_teardownFullDutyList_scratch() async throws {
        let env = TestEnv.make(proc: cfgFake())
        let card = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", scratch: true))
        #expect(FileManager.default.fileExists(atPath: card.cwd))
        let cfg = await env.svc.getConfig()
        #expect(card.cwd.hasPrefix(cfg.scratchRoot + "/"))
        _ = try await env.svc.store.update(card.id) { $0.phase = .archived(teardownComplete: false) }
        let fresh = try #require(await env.svc.store.get(card.id))
        try await TeardownStepper().step(fresh, await env.svc.convergeContext())
        #expect(!FileManager.default.fileExists(atPath: card.cwd))       // scratch rm -rf (path-guarded)
        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .archivedComplete)
    }

    @Test("test_teardownFullDutyList_borrowed")
    func test_teardownFullDutyList_borrowed() async throws {
        let env = TestEnv.make(proc: cfgFake())
        let dir = env.base + "/borrowed-work"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let card = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", cwd: dir))
        #expect(card.origin == .borrowed)
        _ = try await env.svc.store.update(card.id) { $0.phase = .archived(teardownComplete: false) }
        let fresh = try #require(await env.svc.store.get(card.id))
        try await TeardownStepper().step(fresh, await env.svc.convergeContext())
        #expect(FileManager.default.fileExists(atPath: dir))                 // borrowed dir NEVER removed
        #expect(env.worktrees.removed.isEmpty)
        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .archivedComplete)
    }

    @Test("test_teardownRedriveNoDuplicateNudges")
    func test_teardownRedriveNoDuplicateNudges() async throws {
        let env = TestEnv.make(proc: cfgFake())
        let repo = TestEnv.repo(env.base)   // lineage lives in GitConfigEmulator (the fake) — no real git repo
        let parent = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await env.svc.lineage.set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: "deadbeef"))
        _ = try await env.svc.store.update(parent.id) { $0.phase = .archived(teardownComplete: false) }
        let ctx = await env.svc.convergeContext()

        // Crash-then-redrive: run the SAME step twice from archivedPending.
        let fresh1 = try #require(await env.svc.store.get(parent.id))
        try await TeardownStepper().step(fresh1, ctx)
        // Re-seed archivedPending to simulate a redrive of the same phase (the flip is idempotent anyway).
        _ = try await env.svc.store.update(parent.id) { $0.phase = .archived(teardownComplete: false) }
        let fresh2 = try #require(await env.svc.store.get(parent.id))
        try await TeardownStepper().step(fresh2, ctx)

        #expect(await ctx.inbox.peek(child.id).count == 1)   // dedupKey ⇒ nudged only once
        #expect(try #require(await env.svc.store.get(parent.id)).phase.kind == .archivedComplete)
    }
}
