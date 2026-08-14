import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit
import TestSupport

/// B4 · the level-triggered delivery arm: every tick, any deliverable card with claimable messages and
/// no dispatch in flight gets re-driven. This is what makes delivery a CONVERGENCE rather than a
/// one-shot — it re-drives Codex's idle-lag no-op and every expired lease B3's residuals leave behind.
@Suite("B4 · delivery arm")
struct DeliveryArmTests {

    typealias Env = (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees,
                     adapter: StubAdapter, trust: TrustLedger, base: String)

    private func idleWithMessage(_ env: Env, branch: String = "b") async throws -> Task {
        // Bake a ZERO startup grace before spawn so the card GRADUATES (its spawnPending deadline is
        // already past on the first reconcile with a live pane). Otherwise reconcile's startup-abort
        // `continue` skips the delivery arm during the card's grace window — a one-tick delay that is
        // harmless in production (the card graduates within spawnGraceSeconds) but blocks a test that
        // reconciles immediately.
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 0)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: branch))
        env.adapter.writeTranscript(for: t.agentSessionId!)
        await env.svc.testSetTurnStatus(t.id, .waiting())
        // One reconcile to GRADUATE (clear spawnPending): the graduating tick hits the startup-abort
        // `continue`, so it does not also run the arm — and there is no message yet, so even if the
        // card were already graduated this tick delivers nothing. After it, the card is normal-live
        // and the test's own reconcile exercises the arm.
        await env.svc.reconcile()
        try await env.svc.inbox.enqueue(t.id, "queued")   // enqueue WITHOUT send's fast wake
        return t
    }

    @Test("the arm re-drives an idle card whose send never woke it (Codex idle-lag no-op)")
    func armRedrivesIdleLagNoop() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await idleWithMessage(env)
        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .live)

        await env.svc.reconcile()

        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .relaunching)
        // LOSS-SHAPED leg (04-tests calls this the battery's spine): a phase assertion alone would
        // pass on code that re-drove the card while dropping the message. The arm recorded only the
        // `.relaunching` INTENT — the RelaunchStepper claims the seed on a later tick — so the message
        // is durably queued (not yet leased). What matters is it is still THERE, never silently gone.
        #expect(await env.svc.inbox.peek(card.id).map(\.text) == ["queued"])
    }

    // slice 4: `hasPendingDelivery` is maintained in the per-tick reconciler, BEFORE the deliverable
    // guard — so it arms even for a running card (whose `wake` returns before delivering) and disarms
    // when the queue drains. Broadcast-only; a later stall-detection slice consumes it.
    @Test("hasPendingDelivery arms on an enqueue to a RUNNING card, and disarms when the queue drains")
    func pendingDeliveryArmsAndDisarms() async throws {
        let env = TestEnv.make(grace: 2)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 0)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))   // stays .running
        env.adapter.writeTranscript(for: card.agentSessionId!)
        await env.svc.reconcile()   // graduate past spawnPending so the arm runs next tick
        #expect(try #require(await env.svc.store.get(card.id)).hasPendingDelivery == false)

        // Enqueue to the still-RUNNING card — its Stop hook owns delivery so `wake`/the arm won't deliver,
        // but the per-tick refresh still arms the broadcast bit.
        try await env.svc.inbox.enqueue(card.id, "later")
        await env.svc.reconcile()
        #expect(try #require(await env.svc.store.get(card.id)).hasPendingDelivery == true)

        // Drain the queue (remove the last message) → the next tick disarms it.
        let msg = try #require(await env.svc.inbox.peek(card.id).first)
        _ = try await env.svc.inbox.remove(msg.id)
        await env.svc.reconcile()
        #expect(try #require(await env.svc.store.get(card.id)).hasPendingDelivery == false)
    }

    @Test("the arm never fires on a RUNNING card — its Stop hook owns delivery")
    func armSkipsRunning() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))   // .running
        env.adapter.writeTranscript(for: card.agentSessionId!)
        try await env.svc.inbox.enqueue(card.id, "later")

        await env.svc.reconcile()

        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .live)
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["later"])
    }

    @Test("the arm never fires on a permission-parked card — it is mid-turn")
    func armSkipsPermissionWaiting() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await idleWithMessage(env)
        await env.svc.testSetTurnStatus(card.id, .running)
        await env.svc.testSetRequests(card.id, [.init(id: "permission", kind: .permission)])

        await env.svc.reconcile()

        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .live)
    }

    /// A resumable dead card BELOW the retry budget is revived, not flipped stuck — the below-budget
    /// counterexample to `resumableDeadNeverConfirmingFlipsStuck` (the pre-wake flip owns the dead phase
    /// ONLY once ≥ 5 attempts are spent). `.agentExited` is the resumable dead reason (the mid-life quit)
    /// after `DeadReason.completed` was removed upstream (`remove-inferred-done-state`).
    @Test("the arm revives a resumable DEAD card — a send to a dead card is a work request")
    func armRevivesDeadResumable() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await idleWithMessage(env)
        await env.svc.markDead(card.id, reason: .agentExited, detail: nil, source: .daemon)

        await env.svc.reconcile()

        #expect(try #require(await env.svc.store.get(card.id)).phase.kind == .relaunching)
    }

    @Test("the arm backs off a failing card instead of hot-looping")
    func armBackoffCapped() async throws {
        let env = TestEnv.make(grace: 2)
        await env.svc.setDeliveryBackoff(3600)                  // one charge parks it for the test
        let card = try await idleWithMessage(env)
        _ = try await env.svc.store.update(card.id) { $0.awaitingFirstPrompt = false }
        env.adapter.deleteTranscript(for: card.agentSessionId!) // no route ⇒ charge

        await env.svc.reconcile()
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 1)
        await env.svc.reconcile()
        await env.svc.reconcile()
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 1)   // backed off, not re-charged
    }

    @Test("an expired unconfirmed token is charged exactly ONCE, however many ticks pass")
    func expiryChargedOncePerToken() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, clock: clock, now: clock.dateProvider())
        await env.svc.setDeliveryBackoff(3600)
        let card = try await idleWithMessage(env)
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        let batch = try #require(try await env.svc.inbox.claim(
            card.id, route: .channelPush, epoch: epoch, budget: StopDrain.maxPayloadChars,
            render: { StopDrain.fit($0, budget: $1) }, now: clock.dateProvider()()))
        await env.svc.markDispatched(card.id, token: batch.token)

        clock.advance(by: .seconds(61))                       // the lease dies unconfirmed
        await env.svc.reconcile()
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 1)
        #expect(await env.svc.outstandingTokenCountForTest(card.id) == 0)   // charge REMOVES it
        await env.svc.reconcile()
        await env.svc.reconcile()
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 1)    // never double-charged
    }

    /// The reason `Inbox.confirm` returns Bool (B2 as-built): a bridge that ACKS without ever notifying
    /// the session would otherwise reset the retry budget on every stale ack and suppress the stuck
    /// flip forever — the card would look healthy while nothing was ever delivered.
    @Test("a non-confirming ack cannot re-arm the budget or suppress the stuck flip")
    func ackWithoutNotifyCannotSuppressStuck() async throws {
        let env = TestEnv.make(grace: 2)
        let card = try await idleWithMessage(env)
        await env.svc.chargeDeliveryAttempt(card.id)
        await env.svc.chargeDeliveryAttempt(card.id)
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 2)

        // A stale/unknown token: `inbox.confirm` removes nothing, so `didConfirm` is false.
        await env.svc.deliveryConfirmed(cardId: card.id, token: UUID(), didConfirm: false)

        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 2)   // NOT re-armed
    }

    @Test("a confirmed delivery resets the whole retry budget")
    func confirmResetsAttempts() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, clock: clock, now: clock.dateProvider())
        let card = try await idleWithMessage(env)
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        let batch = try #require(try await env.svc.inbox.claim(
            card.id, route: .channelPush, epoch: epoch, budget: StopDrain.maxPayloadChars,
            render: { StopDrain.fit($0, budget: $1) }, now: clock.dateProvider()()))
        await env.svc.markDispatched(card.id, token: batch.token)
        await env.svc.chargeDeliveryAttempt(card.id)
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 1)

        await env.svc.confirmDelivery(token: batch.token, cardId: card.id)

        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 0)
        #expect(await env.svc.outstandingTokenCountForTest(card.id) == 0)
    }
}
