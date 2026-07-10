import Foundation
import Testing
@testable import OrchestraCore

/// Task 2.3 — the single `transition()` funnel + `isLegalEdge` edge validator + conclusions +
/// wake-on-live. Exercises the funnel in isolation (spawn/resume/report are NOT yet rerouted through
/// it — that is 2.4/2.5).
@Suite("Stage 2 · phase transition funnel + edge validation")
struct PhaseTransitionTests {

    // Representative phase per kind for the pure edge-set enumeration.
    private static let byKind: [Phase.Kind: Phase] = [
        .creatingWorktree: .creatingWorktree,
        .launching: .launching,
        .live: .live(.running),
        .relaunching: .relaunching,
        .dead: .dead(.agentExited),
        .archivedPending: .archived(teardownComplete: false),
        .archivedComplete: .archived(teardownComplete: true),
    ]

    // MARK: - Step 1/3 · pure edge set

    @Test("isLegalEdge encodes exactly the §P1 edge set; everything else is rejected")
    func test_illegalEdgesRejected() {
        // The legal edge set, keyed by (from.kind, to.kind). `dead → live` is legal ONLY viaSignal.
        let legal: Set<[Phase.Kind]> = [
            [.creatingWorktree, .launching], [.creatingWorktree, .dead],
            [.creatingWorktree, .archivedPending], [.creatingWorktree, .archivedComplete],
            [.launching, .live], [.launching, .dead],
            [.launching, .archivedPending], [.launching, .archivedComplete],
            [.live, .live], [.live, .relaunching], [.live, .dead],
            [.live, .archivedPending], [.live, .archivedComplete],
            [.relaunching, .relaunching], [.relaunching, .live], [.relaunching, .dead],
            [.relaunching, .archivedPending], [.relaunching, .archivedComplete],
            [.dead, .relaunching], [.dead, .archivedPending], [.dead, .archivedComplete],
            [.archivedPending, .archivedComplete],
            [.archivedPending, .creatingWorktree], [.archivedComplete, .creatingWorktree],
        ]
        // `dead → live` is the ONLY edge whose legality depends on viaSignal.
        let signalGated: Set<[Phase.Kind]> = [[.dead, .live]]

        for (fromKind, from) in Self.byKind {
            for (toKind, to) in Self.byKind {
                let key = [fromKind, toKind]
                let viaFalse = OrchestraService.isLegalEdge(from: from, to: to, viaSignal: false)
                let viaTrue = OrchestraService.isLegalEdge(from: from, to: to, viaSignal: true)
                if signalGated.contains(key) {
                    #expect(viaTrue == true, "\(fromKind)→\(toKind) must be legal viaSignal")
                    #expect(viaFalse == false, "\(fromKind)→\(toKind) must be illegal without a signal")
                } else {
                    let want = legal.contains(key)
                    #expect(viaFalse == want, "\(fromKind)→\(toKind) viaSignal:false expected \(want)")
                    #expect(viaTrue == want, "\(fromKind)→\(toKind) viaSignal:true expected \(want)")
                }
            }
        }

        // Explicit brief asserts.
        #expect(OrchestraService.isLegalEdge(from: .relaunching, to: .relaunching, viaSignal: false) == true)
        #expect(OrchestraService.isLegalEdge(from: .dead(.completed), to: .live(.running), viaSignal: true) == true)
        #expect(OrchestraService.isLegalEdge(from: .dead(.completed), to: .live(.running), viaSignal: false) == false)
        #expect(OrchestraService.isLegalEdge(from: .archived(teardownComplete: false),
                                             to: .archived(teardownComplete: true), viaSignal: false) == true)
        #expect(OrchestraService.isLegalEdge(from: .archived(teardownComplete: true),
                                             to: .archived(teardownComplete: false), viaSignal: false) == false)
        #expect(OrchestraService.isLegalEdge(from: .relaunching,
                                             to: .archived(teardownComplete: false), viaSignal: false) == true)
        #expect(OrchestraService.isLegalEdge(from: .dead(.spawnFailed), to: .relaunching, viaSignal: false) == true)
    }

    // MARK: - Step 5/6 · funnel

    @Test("transition rejects an illegal edge and leaves the stored phase unchanged")
    func test_transitionRejectsIllegalEdge() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        _ = try await env.svc.store.update(card.id) { $0.phase = .dead(.completed) }

        // Verb-path (observedEpoch: nil) revival is illegal — only a signal may drive dead→live.
        let r = await env.svc.transition(card.id, to: .live(.running))
        #expect(r == .rejected(from: .dead(.completed), to: .live(.running)))
        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.phase == .dead(.completed))   // unchanged
    }

    @Test("transition to the same phase is an idempotent noop (no persist / event / conclusion)")
    func test_transitionNoopIsIdempotent() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        _ = try await env.svc.store.update(card.id) { $0.phase = .archived(teardownComplete: true) }
        let epochBefore = try #require(await env.svc.store.get(card.id)).sessionEpoch

        let r = await env.svc.transition(card.id, to: .archived(teardownComplete: true))
        #expect(r == .noop)
        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.phase == .archived(teardownComplete: true))
        #expect(after.sessionEpoch == epochBefore)   // no bump on a noop
    }

    @Test("the relaunching→relaunching supersede is NOT a noop: it applies and bumps the epoch")
    func test_relaunchSupersedeIsNotNoop() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        _ = try await env.svc.store.update(card.id) { $0.phase = .relaunching }
        let epochBefore = try #require(await env.svc.store.get(card.id)).sessionEpoch

        let r = await env.svc.transition(card.id, to: .relaunching)
        #expect(r == .applied)
        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.phase == .relaunching)
        #expect(after.sessionEpoch == epochBefore + 1)   // the supersede self-edge bumps
    }

    // Wake-on-live: a message parked while the card was provisioning (creatingWorktree / launching) —
    // where wake no-ops — is picked up by the funnel's single release point when the card goes live.
    @Test("a message parked during provisioning is delivered when the card transitions to live")
    func test_sendDuringProvisioningDeliveredOnLive() async throws {
        // Case A — parked at .creatingWorktree.
        try await runProvisioningDelivery(seed: .creatingWorktree, branch: "cw")
        // Case B — parked at .launching.
        try await runProvisioningDelivery(seed: .launching, branch: "lw")
    }

    private func runProvisioningDelivery(seed: Phase, branch: String) async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: branch))
        env.adapter.writeTranscript(for: card.agentSessionId!)          // resumable
        let name = env.sessions.sessionName(card.id)
        // Seed the provisioning phase directly (live→creatingWorktree is not a legal verb edge).
        _ = try await env.svc.store.update(card.id) { $0.phase = seed }

        // Park a message while provisioning — nothing delivers it yet.
        let inbox = await env.svc.inbox
        try await inbox.enqueue(card.id, "PARKED-\(branch)")
        let ensureBefore = env.sessions.ensureCount

        // If seeded at creatingWorktree, first advance to launching (no wake on a non-live target).
        if seed.kind == .creatingWorktree {
            #expect(await env.svc.transition(card.id, to: .launching) == .applied)
            try await _Concurrency.Task.sleep(for: .milliseconds(40))
            #expect(env.sessions.ensureCount == ensureBefore)          // still parked
        }

        // Going live (idle) fires wakeIfPending → resume-seed delivers the parked message.
        #expect(await env.svc.transition(card.id, to: .live(.waiting(.humanTurn))) == .applied)
        try await pollUntil { env.sessions.ensureArgv[name]?.contains("--resume") == true }
        try await env.svc.report(card.id, StatusReport(sessionSource: "resume"))
        let argv = try #require(env.sessions.ensureArgv[name])
        #expect(argv.contains("--resume"))
        #expect(try #require(argv.last).contains("PARKED-\(branch)"))
    }

    @Test("dead → archived does NOT re-conclude a watched child (only the entry into terminal concludes)")
    func test_deadToArchivedDoesNotReconclude() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let parent = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "p"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        await env.svc.registerWatch(parent.id, [child.id])

        // Conclusion #1: live → dead(agentExited).
        #expect(await env.svc.transition(child.id, to: .dead(.agentExited)) == .applied)
        let inbox = await env.svc.inbox
        try await pollUntil { await inbox.peek(parent.id).count == 1 }
        #expect(await inbox.peek(parent.id).count == 1)

        // dead → archived is terminal→terminal: the funnel must NOT conclude again.
        #expect(await env.svc.transition(child.id, to: .archived(teardownComplete: false)) == .applied)
        try await _Concurrency.Task.sleep(for: .milliseconds(60))
        #expect(await inbox.peek(parent.id).count == 1)   // no second notice
    }

    @Test("wait short-circuit unregisters the settled child so a later conclusion does not re-notify")
    func test_waitShortCircuitUnregistersChild() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let parent = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "p"))
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))

        // Child concludes BEFORE the parent watches it (no watcher yet → no notice).
        #expect(await env.svc.transition(child.id, to: .dead(.agentExited)) == .applied)
        let inbox = await env.svc.inbox
        #expect(await inbox.peek(parent.id).isEmpty)

        // wait short-circuits on the already-settled child AND unregisters it from the watch registry.
        let conc = await env.svc.wait(watcher: parent.id, refs: [child.id])
        #expect(conc?.cardId == child.id)
        #expect(conc?.kind == .exited)
        #expect(conc?.deadReason == .agentExited)   // resolves on the real terminal reason (bug-#2)
        #expect(await inbox.peek(parent.id).isEmpty)

        // A later DIRECT conclusion of the same child (the archive verb calls concludeCard) must NOT
        // re-notify the parent — the short-circuit already unregistered the watch.
        try await env.svc.archive(child.id)
        try await _Concurrency.Task.sleep(for: .milliseconds(60))
        #expect(await inbox.peek(parent.id).isEmpty)   // no stale re-notification
    }
}

/// Task 2.4 — the epoch guard makes stale liveness signals harmless, and `report()`'s status/exit
/// writes are rerouted through the `transition()` funnel (which becomes the sole concluder).
@Suite("Stage 2 · epoch guard + report→funnel reroute")
struct EpochGuardReportFunnelTests {

    // A read-only borrowed card (origin != .worktree, access == .readOnly) — the durable-card form of a
    // one-shot delegation, so `shouldConcludeOnTurnCompletion` is true for it.
    private func readOnlyCard(_ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String), _ name: String) async throws -> Task {
        let dir = env.base + "/borrow-\(name)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return try await env.svc.spawn(SpawnInput(prompt: "work", cwd: dir, access: .readOnly))
    }

    // MARK: - epoch fence on the SessionEnd (kill-class) signal

    @Test("a stale-epoch SessionEnd is dropped; the matching-epoch one applies")
    func test_staleSessionEndIgnored() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        _ = try await env.svc.store.update(card.id) { $0.sessionEpoch = 2 }

        // A SessionEnd stamped with the SUPERSEDED generation (1 ≠ 2) is fenced out by the funnel.
        try await env.svc.report(card.id, StatusReport(endReason: "exit"), observedEpoch: 1)
        var after = try #require(await env.svc.store.get(card.id))
        #expect(after.phase.kind != .dead)   // not killed by a stale signal

        // The SAME signal at the CURRENT generation applies.
        try await env.svc.report(card.id, StatusReport(endReason: "exit"), observedEpoch: 2)
        after = try #require(await env.svc.store.get(card.id))
        #expect(after.phaseDisplay == .dead)
        #expect(after.deadReason == .agentExited)
    }

    @Test("a nil-epoch kill signal transitions only after the isAlive probe confirms the session is gone")
    func test_nilEpochKillSignalRequiresProbe() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)

        // Kill-class, nil epoch, session STILL ALIVE → the probe blocks the kill.
        let live = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "a", repo: repo, branch: "a"))
        #expect(env.sessions.isAliveTest(live.id))   // spawn ensured it
        try await env.svc.report(live.id, StatusReport(endReason: "exit"), observedEpoch: nil)
        var after = try #require(await env.svc.store.get(live.id))
        #expect(after.phase.kind != .dead)           // isAlive == true → not killed

        // Session now genuinely gone → the probe permits the kill.
        env.sessions.setAlive(live.id, false)
        try await env.svc.report(live.id, StatusReport(endReason: "exit"), observedEpoch: nil)
        after = try #require(await env.svc.store.get(live.id))
        #expect(after.phaseDisplay == .dead)
        #expect(after.deadReason == .agentExited)
        #expect(env.sessions.isAliveQueries.contains(env.sessions.sessionName(live.id)))

        // A nil-epoch STATUS signal (running↔waiting) is NOT kill-class → it passes unprobed.
        let status = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "b", repo: repo, branch: "b"))
        try await env.svc.report(status.id, StatusReport(run: .waiting(.humanTurn)), observedEpoch: nil)
        let s = try #require(await env.svc.store.get(status.id))
        #expect(s.phaseDisplay == .idle)
    }

    // MARK: - status/exit writes go through the funnel

    @Test("a running→waiting report drives the funnel and emits exactly one upsert")
    func test_reportStatusWritesGoThroughFunnel() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        try await env.svc.report(card.id, StatusReport(run: .waiting(.humanTurn)))
        try await _Concurrency.Task.sleep(for: .milliseconds(60))

        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.phase == .live(.waiting(.humanTurn)))
        let upserts = await collector.upserts.filter { $0.id == card.id }
        #expect(upserts.count == 1)                          // a pure phase change = one funnel write
        #expect(upserts.last?.phase == .live(.waiting(.humanTurn)))
    }

    @Test("turn completion concludes a read-only card once; a worktree card just goes idle")
    func test_turnCompletionConcludesReadOnlyOnly() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let inbox = await env.svc.inbox

        // Read-only card: a completed turn is terminal (.dead(.completed)) and concludes exactly once.
        let watcherA = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "wA", repo: repo, branch: "wa"))
        let readOnly = try await readOnlyCard(env, "ro")
        await env.svc.registerWatch(watcherA.id, [readOnly.id])
        try await env.svc.report(readOnly.id, StatusReport(run: .waiting(.humanTurn), turnCompleted: true))
        let ro = try #require(await env.svc.store.get(readOnly.id))
        #expect(ro.phase == .dead(.completed))
        try await pollUntil { await inbox.peek(watcherA.id).count == 1 }
        #expect(await inbox.peek(watcherA.id).count == 1)     // EXACTLY one conclusion

        // Worktree card: a completed turn stays long-lived (.live(.waiting(.humanTurn))), never concludes.
        let watcherB = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "wB", repo: repo, branch: "wb"))
        let worktree = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "wt", repo: repo, branch: "wt"))
        await env.svc.registerWatch(watcherB.id, [worktree.id])
        try await env.svc.report(worktree.id, StatusReport(run: .waiting(.humanTurn), turnCompleted: true))
        try await _Concurrency.Task.sleep(for: .milliseconds(60))
        let wt = try #require(await env.svc.store.get(worktree.id))
        #expect(wt.phase == .live(.waiting(.humanTurn)))      // NOT terminal
        #expect(await inbox.peek(watcherB.id).isEmpty)        // no conclusion
    }

    // MARK: - stampedEpoch readback parsing

    @Test("stampedEpoch parses tmux show-environment output")
    func test_stampedEpochParses() {
        #expect(SessionManager.parseStampedEpoch("ORCH_EPOCH=3\n") == 3)
        #expect(SessionManager.parseStampedEpoch("ORCH_EPOCH=0") == 0)
        #expect(SessionManager.parseStampedEpoch("-ORCH_EPOCH\n") == nil)   // tmux's unset form
        #expect(SessionManager.parseStampedEpoch("") == nil)
        #expect(SessionManager.parseStampedEpoch("OTHER=x\n") == nil)
    }
}
