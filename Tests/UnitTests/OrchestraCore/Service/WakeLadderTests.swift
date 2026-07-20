import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit
import TestSupport

/// B4 · `wake` is the ONE delivery chokepoint. The ladder: in-flight claim → CLI-wait defer →
/// outstanding-lease defer → channel push (dark) → attach grace → cold resume intent.
@Suite("B4 · wake route ladder")
struct WakeLadderTests {

    typealias Env = (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees,
                     adapter: StubAdapter, trust: TrustLedger, base: String)

    private func idleResumable(_ env: Env, branch: String) async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: branch))
        env.adapter.writeTranscript(for: t.agentSessionId!)
        try await env.svc.report(t.id, StatusReport(run: .waiting(.humanTurn)))
        return t
    }

    @Test("two concurrent wakes produce ONE relaunch intent (deliveriesInFlight single-winner)")
    func deliveriesInFlightSingleWinner() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await idleResumable(env, branch: "b")
        try await env.svc.inbox.enqueue(card.id, "m")

        async let a: Void = env.svc.wake(card.id)
        async let b: Void = env.svc.wake(card.id)
        _ = await (a, b)

        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.phase.kind == .relaunching)
        #expect(after.sessionEpoch == card.sessionEpoch + 1)   // exactly ONE bump, not two
    }

    @Test("a nativeReinvoke card with a live CLI wait defers — the harness will re-invoke it")
    func activeCliWaitDefers() async throws {
        let env = TestEnv.make(grace: 2)                        // .stub == nativeReinvoke
        let parent = try await idleResumable(env, branch: "p")
        let repo = TestEnv.repo(env.base)
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: parent.id, refs: [child.id]) }
        try await pollUntil { await env.svc.activeWaitSubscriptionCount() == 1 }
        try await env.svc.report(parent.id, StatusReport(run: .waiting(.humanTurn)))

        try await env.svc.send(parent.id, "poke")

        #expect(try #require(await env.svc.store.get(parent.id)).phase.kind == .live)   // NOT relaunched
        #expect(try await env.svc.inboxPeek(parent.id).contains { $0.text == "poke" })
        waiting.cancel(); _ = await waiting.value
    }

    @Test("an unexpired same-epoch lease blocks the cold fallback (a delivery is mid-confirm)")
    func outstandingLeaseBlocksColdFallback() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, clock: clock, now: clock.dateProvider())
        let card = try await idleResumable(env, branch: "b")
        try await env.svc.inbox.enqueue(card.id, "held")
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        // A held relaunchSeed lease — the `.ticks`-readiness case awaiting its first-signal confirm.
        _ = try await env.svc.inbox.claim(card.id, route: .relaunchSeed, epoch: epoch,
                                          budget: StopDrain.maxPayloadChars,
                                          render: { HandoffSeed.compose(handoff: nil, messages: $0, budget: $1) },
                                          now: clock.dateProvider()())

        await env.svc.wake(card.id)

        // NEVER supersede a session that just took a delivery.
        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .live)
    }

    @Test("once the lease expires the cold path runs (duplicate over loss)")
    func expiredLeaseUnblocksColdFallback() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, clock: clock, now: clock.dateProvider())
        let card = try await idleResumable(env, branch: "b")
        try await env.svc.inbox.enqueue(card.id, "held")
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        _ = try await env.svc.inbox.claim(card.id, route: .relaunchSeed, epoch: epoch,
                                          budget: StopDrain.maxPayloadChars,
                                          render: { HandoffSeed.compose(handoff: nil, messages: $0, budget: $1) },
                                          now: clock.dateProvider()())

        clock.advance(by: .seconds(61))                          // past deliveryLeaseTimeout
        await env.svc.wake(card.id)

        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .relaunching)
    }

    @Test("a card with nothing to resume charges an attempt instead of relaunching")
    func unresumableChargesAttempt() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        // Prompted, no transcript written, not provisional → no route at all.
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        try await env.svc.report(card.id, StatusReport(run: .waiting(.humanTurn)))
        _ = try await env.svc.store.update(card.id) { $0.titleProvisional = false }
        try await env.svc.send(card.id, "hello")

        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .live)   // no relaunch
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["hello"])         // durable
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 1)               // charged
    }

    // MARK: - attach grace (against the starved broker — always unattached) + activity line

    @Test("a live channel card with no parked poll defers cold inside the grace window")
    func unattachedChannelCardDefersColdWithinGrace() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, capabilities: .channelStub,
                               clock: clock, now: clock.dateProvider())
        let card = try await idleResumable(env, branch: "b")
        try await env.svc.inbox.enqueue(card.id, "m")

        await env.svc.wake(card.id)

        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .live)   // deferred
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 1)              // charged
    }

    @Test("grace expiry falls cold — a bridge-less setup still delivers")
    func graceExpiryFallsCold() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, capabilities: .channelStub,
                               clock: clock, now: clock.dateProvider())
        await env.svc.setDeliveryBackoff(0)
        let card = try await idleResumable(env, branch: "b")
        try await env.svc.inbox.enqueue(card.id, "m")
        await env.svc.wake(card.id)                        // stamps the unattached-since instant

        clock.advance(by: .seconds(16))                    // past channelAttachGrace (15)
        await env.svc.wake(card.id)

        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .relaunching)
    }

    @Test("a delivered card gets a FRESH grace window on the next outage")
    func confirmClearsGraceStamp() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, capabilities: .channelStub,
                               clock: clock, now: clock.dateProvider())
        let card = try await idleResumable(env, branch: "b")
        try await env.svc.inbox.enqueue(card.id, "m")
        await env.svc.wake(card.id)                        // stamps unattached-since at t0
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        let batch = try #require(try await env.svc.inbox.claim(
            card.id, route: .channelPush, epoch: epoch, budget: StopDrain.maxPayloadChars,
            render: { StopDrain.fit($0, budget: $1) }, now: clock.dateProvider()()))
        await env.svc.confirmDelivery(token: batch.token, cardId: card.id)   // clears the stamp

        clock.advance(by: .seconds(16))                    // would have blown the ORIGINAL window
        try await env.svc.inbox.enqueue(card.id, "m2")
        await env.svc.wake(card.id)

        // A fresh window, so this wake DEFERS rather than cold-restarting a healthy live session.
        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .live)
    }

    @Test("an idle wake that restarts the session says so in the activity feed")
    func idleWakeRestartEmitsActivity() async throws {
        let env = TestEnv.make(grace: 2)
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        let card = try await idleResumable(env, branch: "b")

        try await env.svc.send(card.id, "wake me")

        try await pollUntil {
            await collector.activities.contains { $0.taskId == card.id && $0.text.contains("restart") }
        }
    }
}
