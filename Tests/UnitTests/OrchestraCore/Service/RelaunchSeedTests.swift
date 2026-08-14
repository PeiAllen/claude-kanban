import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// B3 — the COLD delivery path: the RelaunchStepper claims a `relaunchSeed` batch (handoff + inbox
/// composed) as the launch seed, confirms it on `.signal` readiness or HOLDS the lease on `.ticks`, and
/// `report()`'s provenance-fenced held-confirm removes a held lease on the first proven current-gen
/// line/hook. Both agents via the capability seam; loss-shaped assertions are the spine.
@Suite("B3 · relaunchSeed claim / confirm / hold")
struct RelaunchSeedTests {

    /// A fileTail (Codex-shaped) stub whose relaunch readiness is `.rolloutMeta` — a `codex resume` writes no
    /// rollout, so the N=3 tick fallback resolves it `.ticks` (the seed lease is HELD).
    static let codexStub = AgentCapabilities(
        sessionId: .seeded, telemetry: .fileTail, contextUsage: .tokens,
        wakeTransport: .relaunch, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .subscription,
        readinessConfirmation: .rolloutMeta)

    private static func makeDeadResumable(
        _ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
        _ branch: String = "b") async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: branch))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        return t
    }

    // MARK: - signal confirms / ticks holds

    @Test("test_signalReadinessConfirms: a signal-readiness relaunch confirms the seed (inbox emptied)")
    func test_signalReadinessConfirms() async throws {
        let env = TestEnv.make(grace: 10, capabilities: .claudeCode)   // sessionStartHook → signal on inject
        let t = try await Self.makeDeadResumable(env)
        try await env.svc.send(t.id, "deliver-me")

        _ = try await env.svc.resume(t.id)
        _ = try await TestEnv.reconcileToLive(env.svc, t.id, inject: true)   // epoch-stamped resume → .signal
        // The seed carried the message AND the signal proved the boot → the lease was confirmed + removed.
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.last?.contains("deliver-me") == true)
        #expect(try await env.svc.inboxPeek(t.id).isEmpty)
    }

    @Test("test_ticksReadinessHoldsToken: a tick-readiness relaunch HOLDS the seed lease (message durable)")
    func test_ticksReadinessHoldsToken() async throws {
        // The default stub is `.relaunchLiveness` → `.ticks` (no boot signal proven) → the lease is held.
        let env = TestEnv.make(grace: 10)
        let t = try await Self.makeDeadResumable(env)
        try await env.svc.send(t.id, "hold-me")

        _ = try await env.svc.resume(t.id)
        let live = try await TestEnv.reconcileToLive(env.svc, t.id)
        #expect(live.phase.kind == .live)
        // Delivered in the seed, but NOT confirmed — the message is still present, riding a HELD lease.
        let held = try await env.svc.inboxPeek(t.id)
        #expect(held.count == 1)
        #expect(held.first?.lease?.route == .relaunchSeed)
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.last?.contains("hold-me") == true)
    }

    /// An AWAITING readiness cap (`.rolloutMeta`) whose telemetry is `hooksPush`, so the readiness waiter
    /// really registers and the reconciler's PRODUCTION N=3 tick resolves it — without `pollTelemetry`
    /// tailing the stub. This is the shape that exercises `tickLaunchReadyPublic`.
    static let awaitingStub = AgentCapabilities(
        sessionId: .seeded, telemetry: .hooksPush, contextUsage: .tokens,
        wakeTransport: .relaunch, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .subscription,
        readinessConfirmation: .rolloutMeta)

    @Test("test_productionTickHoldsSeed: the RECONCILER's N=3 tick resolves .ticks, so the seed lease is HELD")
    func test_productionTickHoldsSeed() async throws {
        // Guards the production tick resolver specifically. `test_ticksReadinessHoldsToken` uses the default
        // `.relaunchLiveness` stub, which returns `.ticks` DIRECTLY from confirmReadiness and never touches
        // `tickLaunchReadyPublic` (+Reconcile) — so regressing THAT resolver to `.signal` would stay green
        // there. Here readiness is awaited and resolved only by the reconciler's N=3 fallback: if the
        // production tick ever yields `.signal`, the stepper would confirm the seed and this fails.
        let env = TestEnv.make(grace: 30, capabilities: Self.awaitingStub)
        let t = try await Self.makeDeadResumable(env)
        try await env.svc.send(t.id, "tick-held")

        _ = try await env.svc.resume(t.id)
        let live = try await TestEnv.reconcileToLive(env.svc, t.id)   // NO signal injected → N=3 production tick
        #expect(live.phase.kind == .live)
        let held = try await env.svc.inboxPeek(t.id)
        #expect(held.count == 1)                                  // NOT confirmed — the tick only proved liveness
        #expect(held.first?.lease?.route == .relaunchSeed)         // still riding its held lease
    }

    @Test("test_archivedAtIntentReleasesNotConfirms: a confirm on an archived card retains the message for reopen")
    func test_archivedAtIntentReleasesNotConfirms() async throws {
        // `archive` sets `archived = true` in the SAME patch as the `.archivedPending` intent, so
        // confirmDelivery's fresh read sees it and takes the release-not-confirm branch: the message stays
        // durable (lease cleared) for a reopen to redeliver, instead of being removed.
        let env = TestEnv.make(grace: 5)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        try await env.svc.send(t.id, "retain-me")
        let epoch = try #require(await env.svc.store.get(t.id)).sessionEpoch
        let batch = try #require(await env.svc.claimSeed(t.id, epoch: epoch))

        try await env.svc.archive(t.id)                            // intent: archived = true immediately
        await env.svc.confirmDelivery(token: batch.token, cardId: t.id)

        let retained = try await env.svc.inboxPeek(t.id)
        #expect(retained.count == 1)                               // NOT removed — retained for reopen
        #expect(retained.first?.lease == nil)                      // released, so a late confirm is a no-op
    }

    @Test("test_heldLeaseNotRewokenByWakeIfPending (D5): a held-lease card is not re-woken into a relaunch loop")
    func test_heldLeaseNotRewokenByWakeIfPending() async throws {
        let env = TestEnv.make(grace: 10)   // .relaunchLiveness → .ticks → held lease
        let t = try await Self.makeDeadResumable(env)
        try await env.svc.send(t.id, "held")

        _ = try await env.svc.resume(t.id)
        _ = try await TestEnv.reconcileToLive(env.svc, t.id)   // lands .live holding the lease
        let ensureAfterFirst = env.sessions.ensureCount

        // The funnel fired wakeIfPending on the .live landing; with the hasClaimable gate a held same-epoch
        // lease is NOT claimable, so NO second relaunch fires. Extra reconciles must not re-wake it either.
        await env.svc.reconcile(); await env.svc.reconcile()
        await yieldBriefly()
        #expect(env.sessions.ensureCount == ensureAfterFirst)   // no relaunch loop
        #expect(try await env.svc.inboxPeek(t.id).count == 1)   // still held, not double-delivered
    }

    @Test("test_provisionalBlankLaunchCarriesPrompt: a provisional card blank-launches with the payload, lands running")
    func test_provisionalBlankLaunchCarriesPrompt() async throws {
        // A never-prompted (provisional) card with no transcript: the seed rides as the blank launch's
        // opening POSITIONAL prompt, and submitting a prompt lands `.running`.
        let env = TestEnv.make(grace: 10)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        // Make it provisional + transcript-less, then dead → a wake will blank-relaunch it.
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        try await env.svc.restart(t.id)   // provisional + fresh id (no transcript on disk)
        _ = try await TestEnv.reconcileToLive(env.svc, t.id)   // lands the blank restart
        await env.svc.testSetTurnStatus(t.id, .waiting())
        try await env.svc.send(t.id, "prompt-payload")

        _ = try await env.svc.resume(t.id)   // wake the provisional card for delivery
        let live = try await TestEnv.reconcileToLive(env.svc, t.id)
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.last?.contains("prompt-payload") == true)   // payload delivered as the launch positional
        #expect(live.phase.kind == .live)                         // reached live carrying the seed
    }

    @Test("test_handoffOnlyTicksLandingNoPhantomToken: a handoff-only batch leaves no held lease and no outstanding token")
    func test_handoffOnlyTicksLandingNoPhantomToken() async throws {
        let env = TestEnv.make(grace: 10)   // .ticks
        let t = try await Self.makeDeadResumable(env)
        // Handoff only — NO inbox messages.
        _ = try await env.svc.resume(t.id, seed: "just-handoff")
        _ = try await TestEnv.reconcileToLive(env.svc, t.id)
        // The 0-message batch persists no lease; nothing is held, and no phantom token is left outstanding.
        #expect(try await env.svc.inboxPeek(t.id).isEmpty)
        #expect(await env.svc.outstandingTokenCountForTest(t.id) == 0)
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.last?.contains("just-handoff") == true)
    }

    // MARK: - report() held-relaunch confirm (provenance fence)

    /// Put a card `.live` holding a `relaunchSeed` lease at its current epoch, returning (card, epoch, lease).
    private static func liveWithHeldLease(
        _ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
        caps: AgentCapabilities? = nil) async throws -> (id: UUID, epoch: Int) {
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        try await env.svc.send(t.id, "M")
        let epoch = try #require(await env.svc.store.get(t.id)).sessionEpoch
        let batch = try #require(await env.svc.claimSeed(t.id, epoch: epoch))
        #expect(!batch.ids.isEmpty)
        #expect(try await env.svc.inboxPeek(t.id).count == 1)   // held, still present
        return (t.id, epoch)
    }

    @Test("test_hookEpochMatchConfirmsHeld: a current-epoch hook confirms the held lease")
    func test_hookEpochMatchConfirmsHeld() async throws {
        let env = TestEnv.make(grace: 5, capabilities: .claudeCode)
        let held = try await Self.liveWithHeldLease(env)
        try await env.svc.report(held.id, StatusReport(), observedEpoch: held.epoch)
        #expect(try await env.svc.inboxPeek(held.id).isEmpty)   // confirmed + removed
    }

    @Test("test_hookStaleEpochNeverConfirms: a stale-epoch hook never confirms the held lease")
    func test_hookStaleEpochNeverConfirms() async throws {
        let env = TestEnv.make(grace: 5, capabilities: .claudeCode)
        let held = try await Self.liveWithHeldLease(env)
        try await env.svc.report(held.id, StatusReport(), observedEpoch: held.epoch - 1)
        #expect(try await env.svc.inboxPeek(held.id).count == 1)   // NOT confirmed — retained
    }

    @Test("test_heldLeaseConfirmedByPostWatermarkLine: a same-path line at/after the watermark confirms")
    func test_heldLeaseConfirmedByPostWatermarkLine() async throws {
        let env = TestEnv.make(grace: 5, capabilities: Self.codexStub)
        let held = try await Self.liveWithHeldLease(env)
        try await env.svc.inbox.setTailWatermark(cardId: held.id, epoch: held.epoch, watermark: 100, path: "/roll.jsonl")
        try await env.svc.report(held.id, StatusReport(), tail: ("/roll.jsonl", 150))
        #expect(try await env.svc.inboxPeek(held.id).isEmpty)
    }

    @Test("test_preWatermarkLineNeverConfirms: a same-path line BELOW the watermark never confirms")
    func test_preWatermarkLineNeverConfirms() async throws {
        let env = TestEnv.make(grace: 5, capabilities: Self.codexStub)
        let held = try await Self.liveWithHeldLease(env)
        try await env.svc.inbox.setTailWatermark(cardId: held.id, epoch: held.epoch, watermark: 100, path: "/roll.jsonl")
        try await env.svc.report(held.id, StatusReport(), tail: ("/roll.jsonl", 50))
        #expect(try await env.svc.inboxPeek(held.id).count == 1)   // pre-kill line → retained
    }

    @Test("test_wrongRolloutPathNeverConfirms: a line from a DIFFERENT rollout path never confirms")
    func test_wrongRolloutPathNeverConfirms() async throws {
        let env = TestEnv.make(grace: 5, capabilities: Self.codexStub)
        let held = try await Self.liveWithHeldLease(env)
        try await env.svc.inbox.setTailWatermark(cardId: held.id, epoch: held.epoch, watermark: 100, path: "/roll.jsonl")
        try await env.svc.report(held.id, StatusReport(), tail: ("/OTHER.jsonl", 9999))
        #expect(try await env.svc.inboxPeek(held.id).count == 1)   // rotated rollout → retained (dup-not-loss)
    }

    @Test("test_staleEpochTailLineNeverConfirms: a post-watermark line from a LATER generation never confirms a stale-epoch held lease")
    func test_staleEpochTailLineNeverConfirms() async throws {
        let env = TestEnv.make(grace: 5, capabilities: Self.codexStub)
        let held = try await Self.liveWithHeldLease(env)
        try await env.svc.inbox.setTailWatermark(cardId: held.id, epoch: held.epoch, watermark: 100, path: "/roll.jsonl")
        // The epoch bumps WITHOUT a relaunchSeed re-own — the LaunchStepper path (reopen /
        // creatingWorktree), which never calls `claimSeed`, so the prior-epoch held lease survives.
        _ = try await env.svc.store.update(held.id) { $0.sessionEpoch += 1 }
        // A line from the NEW generation, on the SAME transcript (a resume keeps `agentSessionId` and
        // appends), past the OLD lease's watermark. It proves the NEW session is alive — it proves
        // NOTHING about the stale lease's messages, which that session never received.
        try await env.svc.report(held.id, StatusReport(), tail: ("/roll.jsonl", 150))
        #expect(try await env.svc.inboxPeek(held.id).count == 1)   // stale generation → retained
    }
}
