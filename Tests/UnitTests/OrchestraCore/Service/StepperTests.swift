import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

// ============================================================================
// PR4b Task 5 — the matrix + crash-recovery battery (Tests B–E). Test A
// (`test_gatePolicyConformance`) lives in VerbContractTests; Test D's inequality
// is also proven in ReconcilerTests — this file adds the BOTH-AGENT crash framings
// the doctrine wants ("deterministic stubs are the guard; a `remake` IS the crash").
//
// The battery reuses the settled seams: `remake` = a fresh service over the same
// on-disk store (the stateless-stepper re-derives from disk), `reconcile()` /
// `reconcilePhasesAtBoot()` drive convergence, `PhaseSteppers.byKind[kind].verify`
// is the per-cell transitional oracle, and every session/worktree side effect is
// stub-observable. Both backends run through the capability seam (`.claudeCode`
// sessionStartHook / codex `.rolloutMeta`) — never an `if agentId ==`.
// ============================================================================

/// A per-backend env tuple: a genuine `codex` card is a DIFFERENT adapter id (not
/// Claude-with-different-caps), so the capability branches are exercised for real.
private typealias BEnv = (svc: OrchestraService, sessions: StubSessions,
                          worktrees: StubWorktrees, adapter: StubAdapter, base: String)

/// The both-agent matrix parameter — the readiness axis is what differs (Claude
/// `.sessionStartHook` vs Codex `.rolloutMeta`), which is exactly the launch/relaunch
/// path the crash tests exercise, so BA is REQUIRED here (not a courtesy).
private let batteryAgents: [(id: String, caps: AgentCapabilities)] =
    [("claude-code", .claudeCode), ("codex", ReadinessSignalTests.codexStubCaps)]

/// A stub-backed service whose sole adapter carries `id` + `caps`. Mirrors the wiring
/// `TestEnv.make` uses, but lets a `codex` card actually be codex (the readiness seam).
private func batteryEnv(_ caps: AgentCapabilities, id: String) -> BEnv {
    let base = PathResolver.canonical(NSTemporaryDirectory() + "orch-battery-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: base + "/repos", withIntermediateDirectories: true)
    let config = Config(reposRoot: base + "/repos", worktreesRoot: base + "/worktrees", allowlist: [base], sessionLaunchTimeout: 3600,
                        scratchRoot: base + "/scratch", runtimeStateDir: base + "/state")
    let sessions = StubSessions()
    let worktrees = StubWorktrees(root: config.worktreesRoot)
    let wtReg = WorktreeRegistry(config: config, manager: worktrees,
                                 borrowsPath: base + "/borrows.json", markersDir: base + "/wm")
    let adapter = StubAdapter(transcriptDir: base + "/transcripts", capabilities: caps, id: id)
    let store = TaskStore(path: base + "/tasks.json")
    let trust = TrustLedger(path: base + "/trust.json")
    let inbox = Inbox(path: base + "/inbox.json")
    let svc = OrchestraService(config: config, store: store, registry: AgentRegistry(adapters: [adapter]),
                               worktrees: wtReg, sessions: sessions, trust: trust, inbox: inbox,
                               watchStore: WatchRegistryStore(path: base + "/watch.json"),
                               proc: TestEnv.defaultFakeProc(), gitRemotesProbe: { _ in [] })
    return (svc, sessions, worktrees, adapter, base)
}

/// Rebuild a fresh service over the SAME on-disk store as `batteryEnv` — the deterministic
/// "crash": in-memory timers/loops/sessions are gone, so the steppers re-derive from the
/// persisted phase. The adapter id/caps MUST match (the persisted card carries the agentId,
/// so a bare `TestEnv.remake` — always "claude-code" — would fail `registry.get("codex")`).
private func batteryRemake(base: String, caps: AgentCapabilities, id: String) -> BEnv {
    let config = Config(reposRoot: base + "/repos", worktreesRoot: base + "/worktrees", allowlist: [base], sessionLaunchTimeout: 3600,
                        scratchRoot: base + "/scratch", runtimeStateDir: base + "/state")
    let sessions = StubSessions()
    let worktrees = StubWorktrees(root: config.worktreesRoot)
    let wtReg = WorktreeRegistry(config: config, manager: worktrees,
                                 borrowsPath: base + "/borrows.json", markersDir: base + "/wm")
    let adapter = StubAdapter(transcriptDir: base + "/transcripts", capabilities: caps, id: id)
    let store = TaskStore(path: base + "/tasks.json")
    let trust = TrustLedger(path: base + "/trust.json")
    let inbox = Inbox(path: base + "/inbox.json")
    let svc = OrchestraService(config: config, store: store, registry: AgentRegistry(adapters: [adapter]),
                               worktrees: wtReg, sessions: sessions, trust: trust, inbox: inbox,
                               watchStore: WatchRegistryStore(path: base + "/watch.json"),
                               proc: TestEnv.defaultFakeProc(), gitRemotesProbe: { _ in [] })
    return (svc, sessions, worktrees, adapter, base)
}

/// Spawn a worktree card and drive it to `.live` (materialized tree + up session), delivering
/// the readiness signal each launching tick so an AWAITING cap (`.sessionStartHook`/`.rolloutMeta`)
/// confirms deterministically. The common starting point for the crash framings.
private func batterySpawnLive(_ e: BEnv, branch: String) async throws -> Task {
    let created = try await e.svc.spawn(
        SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(e.base), branch: branch, agentId: e.adapter.id))
    try await pollUntil {
        await e.svc.reconcile()
        let card = await e.svc.list(includeArchived: true).first { $0.id == created.id }
        if card?.phase.kind == .launching { try? await e.svc.report(created.id, StatusReport(sessionSource: "startup")) }
        return card?.phase.kind == .live
    }
    return try #require(await e.svc.list(includeArchived: true).first { $0.id == created.id })
}

/// Archive a card and drive the reconciler's TeardownStepper to `.archivedComplete`.
private func batteryArchiveAndTeardown(_ e: BEnv, _ id: UUID) async throws {
    try await e.svc.archive(id)
    try await pollUntil {
        await e.svc.reconcile()
        return await e.svc.list(includeArchived: true).first { $0.id == id }?.phase.kind == .archivedComplete
    }
}

// MARK: - Test B · stepper crash-convergence matrix (agent × boundary)

/// Every stepper converges from ANY persisted boundary after a crash. Explicitly enumerated as
/// `agent × boundary` (2 × 7 = 14 named cells). Per-cell oracle (only 4 kinds have a stepper):
///  • the 4 transitional kinds assert `PhaseSteppers.byKind[kind].verify == true`;
///  • `live` → adopted at the matching epoch (no relaunch, no duplicate session/card);
///  • `dead` → stays `dead`; a `dead(.agentExited)` session is NOT swept (revival stays possible);
///  • `archivedComplete` → terminal; no re-drive, no duplicate teardown.
@Suite("PR4b Task 5 · Test B — stepper crash-convergence matrix")
struct StepperCrashMatrixTests {

    enum Boundary: String, CaseIterable, Sendable {
        case creatingWorktree, launching, live, relaunching, dead, archivedPending, archivedComplete
    }

    @Test("test_everyStepperConvergesFromAnyBoundary", arguments: batteryAgents, Boundary.allCases)
    func test_everyStepperConvergesFromAnyBoundary(
        agent: (id: String, caps: AgentCapabilities), boundary: Boundary) async throws {
        let e = batteryEnv(agent.caps, id: agent.id)
        let live = try await batterySpawnLive(e, branch: "b")
        let epoch = live.sessionEpoch

        // Drive the card TO the boundary phase, then persist it — this is the state a crash strands.
        switch boundary {
        case .creatingWorktree:  await e.svc.seedPhase(live.id, .creatingWorktree)
        case .launching:         await e.svc.seedPhase(live.id, .launching, sessionEpoch: epoch)
        case .live:              break                                  // already live
        case .relaunching:
            e.adapter.writeTranscript(for: live.agentSessionId!)        // resumable so the relaunch resumes
            await e.svc.seedPhase(live.id, .relaunching)
        // Use a DeadReason that survives a crash-reload unchanged, so this cell keeps testing what it's
        // meant to — a dead session isn't swept. (`.dead(.completed)` is gone: `DeadReason.completed` was
        // removed as a clean break, so a persisted such record would no longer decode at all.)
        case .dead:              await e.svc.markDead(live.id, reason: .agentExited, detail: nil, source: .daemon)
        case .archivedPending:   await e.svc.seedPhase(live.id, .archived(teardownComplete: false))
        case .archivedComplete:  try await batteryArchiveAndTeardown(e, live.id)
        }

        // The crash: a fresh service over the same on-disk store (steppers re-derive from disk).
        let e2 = batteryRemake(base: e.base, caps: agent.caps, id: agent.id)
        // Seed the session state a real crash would leave for the ADOPTION boundaries: a daemon-only
        // crash leaves the tmux session alive at the matching epoch; a `dead(.agentExited)` session lingers.
        switch boundary {
        case .live, .dead: e2.sessions.setStampedEpoch(live.id, epoch)
        default: break
        }

        // Boot pass (adopts/reboot-routes `.live` cards) then steady-state ticks to convergence. We do NOT
        // hand-deliver a readiness signal: the steppers' `finishLaunch` brings the session up for REAL and the
        // reconciler's N=3 liveness fallback confirms it — the missed-hook path both agents must survive. (A
        // hand-delivered `SessionStart(resume)` would finalize a `.relaunching` card to `.live` WITHOUT the
        // stepper's ensure — masking the very relaunch work this cell exists to verify.)
        await e2.svc.reconcilePhasesAtBoot()
        try await pollUntil {
            await e2.svc.reconcile()
            return await Self.oracleReached(e2, live.id, boundary)
        }

        // Per-cell oracle assertions.
        let ctx = await e2.svc.convergeContext()
        let final = try #require(await e2.svc.list(includeArchived: true).first { $0.id == live.id })
        let name = e2.sessions.sessionName(live.id)
        switch boundary {
        case .creatingWorktree: #expect(await MaterializeStepper().verify(final, ctx))
        case .launching, .live: #expect(await LaunchStepper().verify(final, ctx))   // live: adopted at epoch
        case .relaunching:      #expect(await RelaunchStepper().verify(final, ctx))
        case .archivedPending:  #expect(await TeardownStepper().verify(final, ctx))
        case .archivedComplete: #expect(await TeardownStepper().verify(final, ctx))  // stays complete
        case .dead:             break
        }
        switch boundary {
        case .live:
            #expect(final.phase.kind == .live)                          // adopted, not relaunched
            #expect(final.sessionEpoch == epoch)                        // identity preserved
            #expect(e2.sessions.killed.isEmpty)                         // no relaunch kill
            #expect(e2.sessions.ensureArgv[name] == nil)                // no duplicate session
            #expect(await e2.svc.list(includeArchived: true).filter { $0.id == live.id }.count == 1)  // no duplicate card
        case .dead:
            #expect(final.phase == .dead(.agentExited))                 // stays dead
            #expect(e2.sessions.isAliveTest(live.id))                   // dead(.agentExited) session NOT swept
            #expect(!e2.sessions.killed.contains(name))
        case .archivedComplete:
            #expect(final.phase.kind == .archivedComplete)              // terminal
            #expect(e2.sessions.killed.isEmpty)                         // no duplicate teardown kill
            #expect(e2.worktrees.removed.isEmpty)                       // no duplicate run-dir reclaim
        default:
            break
        }
    }

    /// The loop's convergence predicate (the phase the boundary settles at).
    private static func oracleReached(_ e: BEnv, _ id: UUID, _ boundary: Boundary) async -> Bool {
        guard let f = await e.svc.list(includeArchived: true).first(where: { $0.id == id }) else { return false }
        switch boundary {
        case .creatingWorktree, .launching, .relaunching, .live: return f.phase.kind == .live
        case .archivedPending, .archivedComplete:                return f.phase.kind == .archivedComplete
        case .dead:                                              return f.phase.kind == .dead
        }
    }
}

// MARK: - Test C · adopt-don't-relaunch + reboot crash scenarios

@Suite("PR4b Task 5 · Test C — adopt / reboot crash scenarios")
struct AdoptRebootCrashTests {

    /// A daemon-only crash whose tmux session survives at the MATCHING epoch is ADOPTED (never relaunched).
    @Test("test_daemonCrashAdoptsLiveSession", arguments: batteryAgents)
    func test_daemonCrashAdoptsLiveSession(agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = batteryEnv(agent.caps, id: agent.id)
        let live = try await batterySpawnLive(e, branch: "b")
        let epoch = live.sessionEpoch

        let e2 = batteryRemake(base: e.base, caps: agent.caps, id: agent.id)
        e2.sessions.setStampedEpoch(live.id, epoch)          // session survived the daemon at the same epoch
        await e2.svc.reconcilePhasesAtBoot()

        let after = try #require(await e2.svc.list().first { $0.id == live.id })
        #expect(after.phase.kind == .live)                                          // adopted
        #expect(after.sessionEpoch == epoch)                                        // identity unchanged
        #expect(e2.sessions.killed.isEmpty)                                         // never killed
        #expect(e2.sessions.ensureArgv[e2.sessions.sessionName(live.id)] == nil)    // never relaunched
        #expect(try e2.sessions.stampedEpoch(name: e2.sessions.sessionName(live.id)) == epoch)
    }

    /// A `.launching` card whose session came up before the crash cut the phase write is adopted on the
    /// next tick at the matching epoch — no duplicate session, no duplicate card.
    @Test("test_launchingAdoptsSurvivingSession", arguments: batteryAgents)
    func test_launchingAdoptsSurvivingSession(agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = batteryEnv(agent.caps, id: agent.id)
        let live = try await batterySpawnLive(e, branch: "b")
        let epoch = live.sessionEpoch
        await e.svc.seedPhase(live.id, .launching, sessionEpoch: epoch)   // session up, phase-write lost

        let e2 = batteryRemake(base: e.base, caps: agent.caps, id: agent.id)
        e2.sessions.setStampedEpoch(live.id, epoch)                       // surviving session at matching epoch
        let countBefore = await e2.svc.list(includeArchived: true).count
        try await pollUntil {
            await e2.svc.reconcile()
            return await e2.svc.list().first { $0.id == live.id }?.phase.kind == .live
        }

        let after = try #require(await e2.svc.list().first { $0.id == live.id })
        #expect(after.phase.kind == .live)                                          // adopted
        #expect(after.sessionEpoch == epoch)
        #expect(e2.sessions.killed.isEmpty)                                         // no relaunch kill
        #expect(e2.sessions.ensureArgv[e2.sessions.sessionName(live.id)] == nil)    // no duplicate session
        #expect(await e2.svc.list(includeArchived: true).count == countBefore)      // no duplicate card
    }

    /// A machine reboot wipes tmux: a resumable card resumes per capability (`--resume`); a non-resumable,
    /// already-prompted card is `dead(.rebootUnrevived)` (fail-safe, never a blank relaunch of real work).
    @Test("test_machineRebootPath", arguments: batteryAgents)
    func test_machineRebootPath(agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = batteryEnv(agent.caps, id: agent.id)
        let resumable = try await batterySpawnLive(e, branch: "r")
        e.adapter.writeTranscript(for: resumable.agentSessionId!)         // resumable: transcript on disk
        let orphaned = try await batterySpawnLive(e, branch: "n")         // no transcript, prompted ⇒ unrecoverable

        // Reboot: fresh process AND fresh (empty) tmux — no session survives. The RelaunchStepper's
        // `finishLaunch` resumes for real and the N=3 liveness fallback confirms it (no injected hook — a
        // hand-delivered `resume` signal would finalize the card to `.live` without the actual `--resume`).
        let e2 = batteryRemake(base: e.base, caps: agent.caps, id: agent.id)
        await e2.svc.reconcilePhasesAtBoot()
        try await pollUntil {
            await e2.svc.reconcile()
            return await e2.svc.list().first { $0.id == resumable.id }?.phase.kind == .live
        }

        let ra = try #require(await e2.svc.list().first { $0.id == resumable.id })
        #expect(ra.phase.kind == .live)                                             // revived
        #expect(ra.agentSessionId == resumable.agentSessionId)                      // resumed the same session id
        let argv = try #require(e2.sessions.ensureArgv[e2.sessions.sessionName(resumable.id)])
        #expect(argv.contains("--resume"))                                          // resume per capability

        let na = try #require(await e2.svc.list(includeArchived: true).first { $0.id == orphaned.id })
        #expect(na.phase == .dead(.rebootUnrevived))                                // unrecoverable ⇒ fail-safe dead
    }
}

// MARK: - Test D+E · missed readiness + conclusion idempotency

@Suite("PR4b Task 5 · Test D+E — missed readiness + conclusion idempotency")
struct MissedReadinessConclusionTests {

    /// A `.launching` card whose readiness hook was LOST still reaches `.live` via the universal N=3
    /// liveness-tick fallback — with NO signal injected. Asserts the inequality the fallback depends on:
    /// `launchReadyTickThreshold × pollInterval(2s) < config.sessionLaunchTimeout(30s)`. Both agents
    /// (the fallback is the ONLY resolver for Codex `codex resume` / any missed hook).
    @Test("test_launchingMissedHookConvergesViaLiveness", arguments: batteryAgents)
    func test_launchingMissedHookConvergesViaLiveness(agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = batteryEnv(agent.caps, id: agent.id)

        let thr = await e.svc.launchReadyTickThreshold
        let interval = e.svc.reconcilePollInterval
        let timeout = await e.svc.config.sessionLaunchTimeout
        #expect(Double(thr) * interval < Double(timeout))   // the fallback fires well inside the timeout

        // Non-blocking spawn → the reconciler drives it to `.launching`, where its readiness waiter blocks.
        // We DELIVER NO signal — only the N=3 launch-readiness fallback carries it the rest of the way to live.
        let created = try await e.svc.spawn(
            SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(e.base), branch: "b", agentId: e.adapter.id))
        try await pollUntil {
            await e.svc.reconcile()
            return await e.svc.list().first { $0.id == created.id }?.phase.kind == .live
        }
        #expect(await e.svc.list().first { $0.id == created.id }?.phase.kind == .live)
    }

    /// `wait` on a child that is ALREADY persisted-terminal short-circuits inline AND unregisters the watch
    /// entry (write-through), so a later archive of the same child produces NO duplicate conclusion.
    @Test("test_waitShortCircuitsOnPersistedTerminalPhase")
    func test_waitShortCircuitsOnPersistedTerminalPhase() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let watcher = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "w", repo: repo, branch: "w"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))

        // Child concludes (persisted-terminal) BEFORE any watch is registered — no notice is owed yet.
        await env.svc.markDead(child.id, reason: .agentExited, detail: nil, source: .daemon)   // dead(.agentExited) ⇒ .exited
        #expect(try #require(await env.svc.list(includeArchived: true).first { $0.id == child.id }).phase == .dead(.agentExited))

        // The inline conclusion: `wait` reads REAL card state, returns immediately, and unregisters.
        let conc = await env.svc.wait(watcher: watcher.id, refs: [child.id])
        #expect(conc?.kind == .exited)                                      // short-circuit conclusion
        #expect(await env.svc.watchRegistry[watcher.id] == nil)             // watch entry unregistered (in-memory)
        let persisted = WatchRegistryStore(path: env.base + "/watch-registry.json").load()
        #expect(persisted.map[watcher.id] == nil)                           // …and the removal PERSISTED (write-through)

        // A LATER archive of the same child must not re-notify the (now-unregistered) watcher.
        try await TestEnv.archiveAndTeardown(env.svc, child.id)
        let inbox = try await env.svc.inboxPeek(watcher.id)
        #expect(!inbox.contains { $0.text.contains("concluded") })          // no duplicate conclusion
    }

    /// Batch-spawn's per-item idempotency contract that exists TODAY (full server-side dedup is PR6a): each
    /// item spawns independently with its own id, a failure carries its slot `index`, so a partially-acked
    /// batch is retried by the failed indices alone — producing no duplicate of the already-acked cards.
    @Test("test_batchSpawnRetryIsIdempotent")
    func test_batchSpawnRetryIsIdempotent() async throws {
        let env = TestEnv.make()
        let goodRepo = TestEnv.repo(env.base)
        let badRepo = "/nonexistent-outside-allowlist-\(UUID().uuidString)"   // non-allowlisted ⇒ deterministic fail
        let batch = [
            SpawnInput(id: UUID(), prompt: "a", repo: goodRepo, branch: "a"),
            SpawnInput(id: UUID(), prompt: "b", repo: badRepo,  branch: "b"),
            SpawnInput(id: UUID(), prompt: "c", repo: goodRepo, branch: "c"),
        ]
        let r1 = await env.svc.batchSpawn(batch)
        #expect(r1.spawned.count == 2)
        #expect(r1.failed.count == 1)
        #expect(r1.failed.first?.index == 1)                     // per-item identity: the failure carries its slot
        #expect(Set(r1.spawned.map(\.id)).count == 2)            // distinct per-item ids
        let ackedIds = Set(r1.spawned.map(\.id))

        // Retry ONLY the failed slot (now with a valid repo) — the acked two are NOT re-submitted.
        let r2 = await env.svc.batchSpawn([SpawnInput(id: UUID(), prompt: "b", repo: goodRepo, branch: "b")])
        #expect(r2.spawned.count == 1)
        #expect(r2.failed.isEmpty)

        // No duplicate cards: the two originally-acked persist untouched + the one retried = 3 distinct.
        let all = await env.svc.list(includeArchived: true)
        #expect(all.count == 3)
        #expect(ackedIds.isSubset(of: Set(all.map(\.id))))       // acked cards are stable (retry didn't duplicate)
    }
}

@Suite("PhaseStepper — protocol contract (skeleton, PR4a)")
struct StepperTests {

    /// A trivial conforming stepper used ONLY to exercise the protocol's idempotency contract.
    /// (The four real steppers — Materialize/Launch/Relaunch/Teardown — are PR4b.) It advances a
    /// card creatingWorktree → launching through the real funnel; a second `step` is a funnel no-op,
    /// so no side effect repeats.
    private struct DoubleStepper: PhaseStepper {
        static var drives: Phase.Kind { .creatingWorktree }
        func step(_ card: Task, _ ctx: ConvergeContext) async throws {
            _ = await ctx.transition(card.id, .launching, nil, .creatingWorktree, { _ in })
        }
        func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool {
            (await ctx.store.get(card.id))?.phase.kind == .launching
        }
    }

    @Test("the reconciler-owned stepper map has the four PR4b steppers")
    func test_stepperMapHasFourSteppers() {
        #expect(PhaseSteppers.byKind.count == 4)
        #expect(PhaseSteppers.byKind[.creatingWorktree] is MaterializeStepper)
        #expect(PhaseSteppers.byKind[.launching] is LaunchStepper)
        #expect(PhaseSteppers.byKind[.relaunching] is RelaunchStepper)
        #expect(PhaseSteppers.byKind[.archivedPending] is TeardownStepper)
    }

    @Test("test_stepperStepIsIdempotent")
    func test_stepperStepIsIdempotent() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        // Seed a being-born phase directly (live→creatingWorktree is not a legal verb edge).
        _ = try await env.svc.store.update(card.id) { $0.phase = .creatingWorktree }

        let ctx = await env.svc.convergeContext()
        let stepper = DoubleStepper()

        try await stepper.step(card, ctx)
        let after1 = try #require(await env.svc.store.get(card.id))
        #expect(after1.phase.kind == .launching)
        #expect(await stepper.verify(card, ctx))

        // Second call from the same phase: the funnel rejects/no-ops the redundant edge — no repeat side
        // effect. `phaseChangedAt` is stamped ONLY on an applied edge, so it must be unchanged.
        try await stepper.step(card, ctx)
        let after2 = try #require(await env.svc.store.get(card.id))
        #expect(after2.phase.kind == .launching)
        #expect(after2.phaseChangedAt == after1.phaseChangedAt)
    }
}

// MARK: - Test F · the stale bring-up fence (bug #2 — the `--parallel` suite hang)

/// A `LaunchStepper`/`RelaunchStepper` step is dispatched off a phase SNAPSHOT and runs asynchronously
/// (`stepIfEligible` → unstructured `Task` → `runStep`). By the time it reaches `finishLaunch` the card can
/// ALREADY be `.live`: the reconciler's adopt path lands a `.launching` card whose session came up, and
/// `report()`'s SessionStart(clear/resume) writes `.live` directly. The stale step must then STAND DOWN.
///
/// It did not. `finishLaunch`'s bring-up is `kill` + `ensure`, so it tore the live agent's session down and
/// replaced it with a fresh one — a duplicate bring-up on a card nobody asked to relaunch. Under
/// `swift test --parallel` that resurrected a session a test had just killed, so the card never died, never
/// concluded, and the `wait` suspended on it (the only unbounded park in the product) hung forever — wedging
/// the whole run. Agent-agnostic: the fence is a phase/epoch check, not an adapter branch.
@Suite("PR4b Task 5 · Test F — a stale bring-up never resurrects a live session")
struct StaleBringUpFenceTests {

    @Test("a bring-up whose card already left `.launching` stands down (no kill+ensure on a live session)",
          arguments: batteryAgents)
    func test_staleBringUpDoesNotResurrectLiveSession(agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = batteryEnv(agent.caps, id: agent.id)
        let card = try await batterySpawnLive(e, branch: "f")
        let epoch = card.sessionEpoch

        e.sessions.setAlive(card.id, false)               // the agent's session vanishes (crash / tmux kill)
        #expect(!e.sessions.isAliveTest(card.id))

        // The step dispatched back when the card was `.launching` finally runs — the card is `.live` now.
        let outcome = await e.svc.finishLaunch(card.id, flavor: .blank(prompt: nil),
                                               expecting: .launching, epoch: epoch)

        #expect(outcome == .superseded)                   // stood down — a newer landing owns the card
        #expect(!e.sessions.isAliveTest(card.id))         // and did NOT resurrect the vanished session

        // …so the liveness pass can still see the death and conclude the card. (The hang: it couldn't —
        // the resurrected session read `alive`, so the card sat `.live` forever with a `wait` parked on it.)
        await e.svc.reconcileLiveness()
        let after = try #require(await e.svc.list(includeArchived: true).first { $0.id == card.id })
        #expect(after.phase == .dead(.sessionVanished))
    }

    /// The fence is on the CARD's generation too: a restart bumps `sessionEpoch` and re-enters
    /// `.relaunching`, so a step from the previous generation must not bring up the old session under it.
    @Test("a bring-up from a superseded generation stands down", arguments: batteryAgents)
    func test_staleGenerationBringUpStandsDown(agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = batteryEnv(agent.caps, id: agent.id)
        let card = try await batterySpawnLive(e, branch: "g")
        let staleEpoch = card.sessionEpoch

        await e.svc.seedPhase(card.id, .launching, sessionEpoch: staleEpoch + 1)   // a newer generation owns it
        e.sessions.setAlive(card.id, false)

        let outcome = await e.svc.finishLaunch(card.id, flavor: .blank(prompt: nil),
                                               expecting: .launching, epoch: staleEpoch)
        #expect(outcome == .superseded)
        #expect(!e.sessions.isAliveTest(card.id))
    }

    /// **The surviving race (Codex review, BLOCKER).** The entry fence alone is NOT enough: `finishLaunch`
    /// suspends (trust resolve, `prepareToLaunch`) between the fence and its destructive `kill`+`ensure`, so
    /// a report landing the card `.live` at the SAME epoch in that window would leave the step believing it
    /// still owns a being-born card — and it would kill the live session and re-`ensure` a fresh one. The
    /// claim (`inFlightSteps`) is therefore the ownership token: while a bring-up owns the card, a report may
    /// NOT land it `.live`. Both readiness capabilities are covered — Claude's SessionStart(resume/clear)
    /// hook and Codex's rollout-driven report both route through `report()`.
    @Test("a report cannot land a card `.live` under an in-flight bring-up (the fence's surviving window)",
          arguments: batteryAgents)
    func test_reportCannotStealTheLandingFromAnInFlightBringUp(
        agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = batteryEnv(agent.caps, id: agent.id)
        let card = try await batterySpawnLive(e, branch: "h")

        // The card is being relaunched: a step is dispatched and is mid-bring-up (it holds the claim, and is
        // suspended in `prepareToLaunch` — it has NOT killed/ensured yet).
        await e.svc.seedPhase(card.id, .relaunching)
        await e.svc.setStepInFlight(card.id, true)

        // The still-live prior agent reports SessionStart(resume) — the exact interleaving Codex flagged.
        try? await e.svc.report(card.id, StatusReport(sessionSource: "resume"))

        // It must NOT have landed `.live`: the bring-up owns the landing. (Before this fix it did, and the
        // step — fenced only on entry — would then have killed the live session and re-ensured a blank one.)
        let mid = try #require(await e.svc.list(includeArchived: true).first { $0.id == card.id })
        #expect(mid.phase.kind == .relaunching)

        // The report's readiness signal still lands, so the step confirms and lands `.live` itself.
        #expect(await e.svc.hasReadinessWaiter(card.id) == false || mid.phase.kind == .relaunching)
        await e.svc.setStepInFlight(card.id, false)
    }

    /// The adopt path must not land a card `.live` out from under its own in-flight step (`bringingUp` takes
    /// the step's claim, not just a registered readiness waiter — a step registers its waiter only AFTER its
    /// off-actor `kill`+`ensure` returns, so a waiter-only check reads "nobody is bringing this up").
    @Test("reconcile does not adopt a card whose bring-up step is still in flight", arguments: batteryAgents)
    func test_adoptDoesNotRaceAnInFlightStep(agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = batteryEnv(agent.caps, id: agent.id)
        let card = try await batterySpawnLive(e, branch: "i")
        let epoch = card.sessionEpoch

        // A `.launching` card whose session is ALREADY up at the matching epoch — the adopt precondition —
        // but whose own step is still in flight (it ensured, and has not yet registered its waiter).
        await e.svc.seedPhase(card.id, .launching, sessionEpoch: epoch)
        e.sessions.setStampedEpoch(card.id, epoch)
        await e.svc.setStepInFlight(card.id, true)

        await e.svc.reconcile()

        let after = try #require(await e.svc.list(includeArchived: true).first { $0.id == card.id })
        #expect(after.phase.kind == .launching)   // NOT adopted — its own step owns the landing
        await e.svc.setStepInFlight(card.id, false)
    }

    /// **MAJOR 1 (review).** The fence is a CHECK, not a lease: `finishLaunch` cannot hold the actor across
    /// its off-actor `kill`+`ensure`, and the launch-timeout `markDead` runs OUTSIDE the `bringingUp` gate
    /// (deliberately — it is what keeps a wedged bring-up converging). So a card CAN go terminal while the
    /// session is coming up. Nothing else would ever reap that session (the orphan sweep only touches
    /// archived/absent cards; reconcile's `.dead` case is a no-op), so a real tmux session + agent process
    /// would leak under a dead card, across daemon restarts. The bring-up must reap what it created.
    @Test("a bring-up superseded WHILE its session comes up reaps that session (no leak under a dead card)",
          arguments: batteryAgents)
    func test_bringUpReapsItsSessionWhenSupersededMidHop(
        agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = batteryEnv(agent.caps, id: agent.id)
        let card = try await batterySpawnLive(e, branch: "j")
        let epoch = card.sessionEpoch
        await e.svc.seedPhase(card.id, .launching, sessionEpoch: epoch)
        e.sessions.setAlive(card.id, false)

        // The supersede lands INSIDE the ensure — the window the entry fence cannot see.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        e.sessions.onEnsure = { entered.signal(); release.wait() }

        let bringUp = _Concurrency.Task {
            await e.svc.finishLaunch(card.id, flavor: .blank(prompt: nil),
                                     expecting: .launching, epoch: epoch)
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { entered.wait(); c.resume() }
        }
        // The launch timeout concludes the card while its session is mid-bring-up.
        await e.svc.markDead(card.id, reason: .spawnFailed, detail: "launch timed out", source: .daemon)
        release.signal()

        let outcome = await bringUp.value
        e.sessions.onEnsure = nil

        #expect(outcome == .superseded)                       // it lost the card
        #expect(!e.sessions.isAliveTest(card.id))             // …and reaped the session it had just created
        let after = try #require(await e.svc.list(includeArchived: true).first { $0.id == card.id })
        #expect(after.phase == .dead(.spawnFailed))           // the conclusion stands
    }

    /// **The invariant the post-hop reap leans on** (Codex fix-verification, MAJOR — refuted, then pinned).
    /// The reap probes `stampedEpoch` and then `kill`s: two separate tmux calls, so not atomic. That is safe
    /// ONLY because a card can have at most ONE bring-up in flight — `stepIfEligible` takes the
    /// `inFlightSteps` claim synchronously before dispatching, and releases it only after the step returns —
    /// so a newer generation's bring-up cannot `kill`+`ensure` between our probe and our kill. Pin it: if a
    /// future change lets a second step be dispatched under an in-flight one, the reap becomes racy and this
    /// test goes red first.
    @Test("reconcile never dispatches a second bring-up while one is in flight", arguments: batteryAgents)
    func test_noSecondBringUpWhileInFlight(agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = batteryEnv(agent.caps, id: agent.id)
        let card = try await batterySpawnLive(e, branch: "m")
        try await pollUntil { await e.svc.hasStepInFlight(card.id) == false }

        // A being-born card whose bring-up WOULD be re-driven (a resumable transcript ⇒ the RelaunchStepper
        // kills + ensures), but which already has a claim held across its off-actor hop.
        e.adapter.writeTranscript(for: card.agentSessionId!)
        e.sessions.setAlive(card.id, false)   // no live session ⇒ the reconciler would STEP it, not adopt it
        await e.svc.seedPhase(card.id, .relaunching)
        await e.svc.setStepInFlight(card.id, true)
        let ensuresBefore = e.sessions.ensureCount
        let killsBefore = e.sessions.killed.count

        for _ in 0..<5 { await e.svc.reconcile() }        // ticks that WOULD re-step an unclaimed card
        // Steps are dispatched as unstructured tasks, so a dispatched one would land its kill+ensure just
        // after the tick returns — give it ample scheduling room (yields, no wall-clock), then assert it
        // never happened.
        await yieldBriefly(2000)

        #expect(e.sessions.ensureCount == ensuresBefore)  // no second bring-up: no kill, no ensure
        #expect(e.sessions.killed.count == killsBefore)
        await e.svc.setStepInFlight(card.id, false)
    }

    /// **MAJOR 2 (review).** The LANDING needs the same fence as the bring-up. `markDead` does not bump
    /// `sessionEpoch` and `dead → live` is a legal revival edge, so a step whose readiness confirmed only
    /// AFTER the launch timeout concluded the card would flip it back to `.live` — re-animating a card whose
    /// death a watching parent's `wait` has already been told about.
    @Test("a step's landing cannot revive a card the launch timeout already concluded", arguments: batteryAgents)
    func test_landingCannotReviveAConcludedCard(agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = batteryEnv(agent.caps, id: agent.id)
        let card = try await batterySpawnLive(e, branch: "k")
        let epoch = card.sessionEpoch
        await e.svc.seedPhase(card.id, .launching, sessionEpoch: epoch)

        // The timeout concludes it (no epoch bump — that is what defeats the epoch fence alone).
        await e.svc.markDead(card.id, reason: .spawnFailed, detail: "launch timed out", source: .daemon)

        // The in-flight step's readiness confirms afterwards and tries to land `.live` at the SAME epoch.
        let landed = await e.svc.transition(card.id, to: .live(.running),
                                            observedEpoch: epoch, expecting: .launching)

        #expect(landed == .noop)                              // fenced on the dispatched phase
        let after = try #require(await e.svc.list(includeArchived: true).first { $0.id == card.id })
        #expect(after.phase == .dead(.spawnFailed))           // still dead, still concluded
    }
}

// MARK: - the startup-abort retry stamps its generation (review MAJOR 3)

@Suite("PR4b Task 5 · Test G — the startup-abort retry is epoch-stamped")
struct StartupAbortRetryEpochTests {

    /// An UNSTAMPED session is invisible to the epoch machinery: `stampedEpoch` reads nil, so adopt and
    /// `reconcilePhasesAtBoot` can never epoch-match it (the next daemon boot tears a healthy retried session
    /// down and relaunches it, losing the agent's context), and its hooks report with `observedEpoch == nil`,
    /// which skips the funnel's generation fence — letting a stale report land `.live` on a card a newer
    /// relaunch already owns. Every other launch stamps `ORCH_EPOCH`; the retry must too.
    @Test("the retry launch carries ORCH_EPOCH, so the session stays epoch-matchable", arguments: batteryAgents)
    func test_startupAbortRetryStampsEpoch(agent: (id: String, caps: AgentCapabilities)) async throws {
        let e = batteryEnv(agent.caps, id: agent.id)
        // Widen the startup grace BEFORE the spawn arms it: the default is 4s wall-clock, and under a loaded
        // `--parallel` run the spawn itself can outlast it, graduating the card (clearing `spawnPending`) so
        // the abort would never be classified as one. This keeps the test about the epoch stamp, not the clock.
        await e.svc.setStartupConfirmation(graceSeconds: 600, maxRetries: 1)
        let card = try await batterySpawnLive(e, branch: "l")

        // Let the launch step fully drain first: it lands `.live` and only THEN returns, and its `ensure`
        // clears the dead-pane mark — so marking the pane dead under a still-running step is a race.
        try await pollUntil { await e.svc.hasStepInFlight(card.id) == false }

        e.sessions.setPaneDead(card.id)          // the launch aborts → bounded retry
        await e.svc.reconcileLiveness()

        // The retried session is stamped with the card's generation — so the epoch machinery can see it.
        let after = try #require(await e.svc.list(includeArchived: true).first { $0.id == card.id })
        #expect(after.phase.kind != .dead, "gave up instead of retrying (deadReason=\(String(describing: after.deadReason)))")
        #expect(e.sessions.isAliveTest(card.id), "no session after the retry (ensures=\(e.sessions.ensureCount))")
        let stamped = try e.sessions.stampedEpoch(name: e.sessions.sessionName(card.id))
        #expect(stamped == card.sessionEpoch)
    }
}
