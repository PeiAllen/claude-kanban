import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit
import TestSupport

/// B4 · the guarantee's spine: every failure injection ends in re-delivery or durable retention —
/// never silence. Loss-shaped assertions ("gone AND never delivered") are the oracle.
///
/// These use the `.channelPush` route as a plain non-relaunchSeed lease flavor to drive the inbox;
/// the channel-push WAKE path itself is built in the D increment, so its supersede/refuse races
/// (`test_supersededMidClaimRetainsBatch`, `test_pushFalseReleasesThenColdSameCall`) land with it.
@Suite("B4 · delivery races + crash convergence")
struct DeliveryRaceTests {

    typealias Env = (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees,
                     adapter: StubAdapter, trust: TrustLedger, base: String)

    /// Spawn a GRADUATED idle card (see DeliveryStuckTests for why graduation matters to reconcile).
    private func idleGraduated(_ env: Env, prompt: String = "x", branch: String = "b",
                               transcript: Bool = true) async throws -> Task {
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 0)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: prompt, repo: repo, branch: branch))
        if transcript { env.adapter.writeTranscript(for: card.agentSessionId!) }
        try await env.svc.report(card.id, StatusReport(run: .waiting(.humanTurn)))
        await env.svc.reconcile()   // graduate
        return card
    }

    /// B2's documented residual, pinned: `confirmDelivery` does a fresh archived read and RELEASES
    /// instead of confirming; teardown's `releaseAll` backstops the window in between. The message
    /// must survive to be delivered by a reopen.
    @Test("archive during an in-flight delivery RELEASES the batch — a reopen still delivers it")
    func archiveMidWakeRetainsMessages() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        try await env.svc.inbox.enqueue(card.id, "must survive")
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        let batch = try #require(try await env.svc.inbox.claim(
            card.id, route: .channelPush, epoch: epoch, budget: StopDrain.maxPayloadChars,
            render: { StopDrain.fit($0, budget: $1) }, now: Date()))
        await env.svc.markDispatched(card.id, token: batch.token)

        try await TestEnv.archiveAndTeardown(env.svc, card.id)
        // The late ack lands AFTER the archive — it must release, never confirm.
        await env.svc.confirmDelivery(token: batch.token, cardId: card.id)

        let after = await env.svc.inbox.peek(card.id)
        #expect(after.map(\.text) == ["must survive"])      // NOT removed
        #expect(after.allSatisfy { $0.lease == nil })       // and not left leased
    }

    @Test("a send, an arm tick and a wake racing produce at most ONE relaunch generation")
    func concurrentStartersSingleClaim() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await idleGraduated(env)

        async let s: Void = { try? await env.svc.send(card.id, "race") }()
        async let r: Void = env.svc.reconcile()
        async let w: Void = env.svc.wake(card.id)
        _ = await (s, r, w)

        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.sessionEpoch <= card.sessionEpoch + 1)   // at most ONE relaunch generation
        // LOSS-SHAPED leg: the epoch bound alone passes on code that single-winners AND drops the
        // message. It must be accounted for on at most one live lease, never gone.
        let queued = await env.svc.inbox.peek(card.id)
        #expect(queued.map(\.text) == ["race"])
        #expect(Set(queued.compactMap { $0.lease?.token }).count <= 1)
    }

    /// The ledger-overwrite window: a confirm landing WHILE the arm is deciding what to charge must
    /// not be resurrected by a stale write-back, and must not be charged after it reset the budget.
    @Test("a confirm during the expiry scan is neither resurrected nor charged")
    func confirmDuringExpiryScanIsNotCharged() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await idleGraduated(env)
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        try await env.svc.inbox.enqueue(card.id, "m")
        let live = try #require(try await env.svc.inbox.claim(
            card.id, route: .channelPush, epoch: epoch, budget: StopDrain.maxPayloadChars,
            render: { StopDrain.fit($0, budget: $1) }, now: Date()))
        await env.svc.markDispatched(card.id, token: live.token)
        let deadToken = UUID()
        await env.svc.markDispatched(card.id, token: deadToken)   // genuinely dead ⇒ makes the scan run

        let gate = Gate()
        await env.svc.setExpiryScanPauseForTest { _ = await gate.park() }
        let ticking = _Concurrency.Task { await env.svc.reconcile() }
        await gate.reached()                                     // arm parked mid-scan
        await env.svc.confirmDelivery(token: live.token, cardId: card.id)   // lands mid-scan
        gate.release()
        await ticking.value

        // The LIVE token was confirmed mid-scan. It must be neither RESURRECTED into the ledger by a
        // stale write-back (then `outstanding` would be non-zero) nor CHARGED (then the count would be
        // 2, not 1 — the confirm resets attempts to 0, so only the genuinely-dead token adds one).
        #expect(await env.svc.outstandingTokenCountForTest(card.id) == 0)   // both pruned; none resurrected
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 1)    // only the dead token, not the live one
        #expect(await env.svc.inbox.peek(card.id).isEmpty)                  // the live token genuinely delivered
    }

    /// The OTHER half of the ledger re-read: a token dispatched WHILE the scan is paused must survive
    /// — the re-read subtracts only the dead-and-still-present set from the CURRENT ledger, so a fresh
    /// dispatch is preserved, not discarded by a stale-snapshot write-back (which would drop it to 0).
    @Test("a token dispatched during the expiry scan stays outstanding, not discarded")
    func newDispatchDuringScanSurvives() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await idleGraduated(env)
        await env.svc.markDispatched(card.id, token: UUID())     // a dead token, so the scan runs

        let gate = Gate()
        await env.svc.setExpiryScanPauseForTest { _ = await gate.park() }
        let ticking = _Concurrency.Task { await env.svc.reconcile() }
        await gate.reached()                                     // arm parked mid-scan
        let fresh = UUID()
        await env.svc.markDispatched(card.id, token: fresh)      // dispatched DURING the scan
        gate.release()
        await ticking.value

        // The dead token was charged+removed; the fresh one — not in the pre-pause `dead` set — must
        // still be outstanding (a stale-snapshot write-back would have discarded it, leaving count 0).
        #expect(await env.svc.outstandingTokenCountForTest(card.id) == 1)
    }

    /// Crash equivalence: leases are persisted, so a fresh daemon must converge from disk alone.
    @Test("a daemon restart re-drives a claim that crashed before its receipt")
    func channelClaimCrashExpiresAndRedelivers() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, clock: clock, now: clock.dateProvider())
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        env.adapter.writeTranscript(for: card.agentSessionId!)
        try await env.svc.report(card.id, StatusReport(run: .waiting(.humanTurn)))
        try await env.svc.inbox.enqueue(card.id, "crashed mid-claim")
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        _ = try await env.svc.inbox.claim(card.id, route: .channelPush, epoch: epoch,
                                          budget: StopDrain.maxPayloadChars,
                                          render: { StopDrain.fit($0, budget: $1) },
                                          now: clock.dateProvider()())
        // …daemon dies here: the lease is on disk, the in-memory outstanding set is not.

        let fresh = TestEnv.remake(base: env.base, clock: clock, now: clock.dateProvider())
        fresh.adapter.writeTranscript(for: card.agentSessionId!)
        #expect(await fresh.svc.inbox.peek(card.id).count == 1)        // still durable
        clock.advance(by: .seconds(61))                                 // the lease expires
        await fresh.svc.reconcile()

        // LOSS-SHAPED: the crash costs a duplicate at worst, never the message.
        #expect(await fresh.svc.inbox.peek(card.id).map(\.text) == ["crashed mid-claim"])
        #expect(try #require(await fresh.svc.store.get(card.id)).phase.kind == .relaunching)
    }

    /// Every lease kind live at once, across a restart, each ends re-delivered or retained.
    @Test("a daemon restart converges every lease kind — none is lost")
    func remakeConvergesAllLeaseStates() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, clock: clock, now: clock.dateProvider())
        let repo = TestEnv.repo(env.base)
        var cards: [Task] = []
        for (i, route) in [DeliveryRoute.stopDrain, .channelPush, .relaunchSeed].enumerated() {
            let c = try await TestEnv.spawnAndAwaitLive(
                env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b\(i)"))
            try await env.svc.report(c.id, StatusReport(run: .waiting(.humanTurn)))
            try await env.svc.inbox.enqueue(c.id, "route-\(route.rawValue)")
            let e = try #require(await env.svc.store.get(c.id)).sessionEpoch
            _ = try await env.svc.inbox.claim(c.id, route: route, epoch: e,
                                              budget: StopDrain.maxPayloadChars,
                                              render: { StopDrain.fit($0, budget: $1) },
                                              now: clock.dateProvider()())
            cards.append(c)
        }

        let fresh = TestEnv.remake(base: env.base, clock: clock, now: clock.dateProvider())
        clock.advance(by: .seconds(61))
        await fresh.svc.reconcile()

        for c in cards {
            // Loss-shaped: still durable on the fresh daemon, whatever route leased it.
            #expect(await fresh.svc.inbox.peek(c.id).count == 1)
        }
    }

    /// The ordering that made the wave-1 defect reachable (orchestrator message #2): `reopen` is a
    /// legal edge straight out of `archivedPending`, so a reopen landing BEFORE teardown's `releaseAll`
    /// leaves a prior-epoch lease alive into the new generation. The epoch bump makes that lease
    /// stale-claimable (re-owned by the new gen), and the report-path fence (aeffa75) refuses to
    /// confirm it — so the message is retained, never deleted.
    @Test("reopen before teardown's releaseAll leaves a stale lease, message retained")
    func reopenBeforeReleaseAllRetainsMessage() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        env.adapter.writeTranscript(for: card.agentSessionId!)
        try await env.svc.inbox.enqueue(card.id, "survives the reopen")
        let oldEpoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        _ = try #require(try await env.svc.inbox.claim(
            card.id, route: .relaunchSeed, epoch: oldEpoch, budget: StopDrain.maxPayloadChars,
            render: { HandoffSeed.compose(handoff: nil, messages: $0, budget: $1) }, now: Date()))

        // Archive INTENT only (→ archivedPending), then reopen straight out of it — so the
        // TeardownStepper's releaseAll never runs and the prior-epoch lease survives.
        try await env.svc.archive(card.id)
        _ = try await env.svc.reopen(card.id)
        let newEpoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        #expect(newEpoch > oldEpoch)

        // The message is retained; its surviving lease is at the OLD epoch, so it is stale-claimable
        // (the new generation re-owns it) rather than able to confirm into the dead one.
        let after = await env.svc.inbox.peek(card.id)
        #expect(after.map(\.text) == ["survives the reopen"])
        if let lease = after.first?.lease { #expect(lease.epoch == oldEpoch) }   // stale, not current
    }
}
