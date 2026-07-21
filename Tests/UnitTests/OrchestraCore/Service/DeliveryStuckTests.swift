import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit
import TestSupport

/// B4 · the stuck lifecycle. Stuck is STABLE — the arm goes quiet so the human's editor window is
/// never raced by a re-lease — and is cleared only by a confirm, a new `send` (B5a), or an emptied
/// inbox. The flip re-validates its guard ON THE ACTOR immediately before the write.
@Suite("B4 · delivery-stuck lifecycle")
struct DeliveryStuckTests {

    typealias Env = (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees,
                     adapter: StubAdapter, trust: TrustLedger, base: String)

    /// Spawn an idle, GRADUATED, unresumable card (no transcript, not provisional → the cold path has
    /// no route and charges). Graduation matters: `spawnPending` is stamped on the REAL wall clock, so
    /// advancing a TestClock never clears it — an un-graduated card is skipped by reconcile's
    /// startup-abort `continue` and the arm never runs.
    private func idleUnresumable(_ env: Env, branch: String = "b") async throws -> Task {
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 0)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: branch))
        try await env.svc.report(card.id, StatusReport(run: .waiting(.humanTurn)))
        _ = try await env.svc.store.update(card.id) { $0.titleProvisional = false }
        await env.svc.reconcile()   // graduate (no message yet ⇒ no charge)
        return card
    }

    /// A card with a message old enough to be stuck-eligible and a retry budget already spent.
    private func exhausted(_ clock: TestClock) async throws -> (env: Env, card: Task) {
        let env = TestEnv.make(grace: 2, clock: clock, now: clock.dateProvider())
        await env.svc.setDeliveryBackoff(0)
        let card = try await idleUnresumable(env)
        try await env.svc.inbox.enqueue(card.id, "undeliverable")   // stamped at clock t0
        clock.advance(by: .seconds(301))                            // older than deliveryStuckAfter
        return (env, card)
    }

    @Test("attempts + message age both exhausted → the card flips stuck and the arm goes quiet")
    func stuckFlipStableStopsClaims() async throws {
        let clock = TestClock()
        let (env, card) = try await exhausted(clock)

        for _ in 0..<6 { await env.svc.reconcile() }                // no route ⇒ charge each tick

        let stuck = try #require(await env.svc.store.get(card.id))
        #expect(stuck.deliveryStuckSince != nil)
        let attemptsAtFlip = await env.svc.deliveryAttemptCountForTest(card.id)
        await env.svc.reconcile()
        // STABLE: a stuck card is not re-driven, so the attempt count stops moving.
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == attemptsAtFlip)
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["undeliverable"])
    }

    @Test("a young message never flips stuck, however many attempts are spent")
    func youngMessageNeverFlips() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, clock: clock, now: clock.dateProvider())
        await env.svc.setDeliveryBackoff(0)
        let card = try await idleUnresumable(env)
        try await env.svc.inbox.enqueue(card.id, "fresh")

        for _ in 0..<8 { await env.svc.reconcile() }

        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince == nil)
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) >= 5)   // budget spent, age gate held
    }

    @Test("a stale flip decision is aborted by the on-actor re-validation (budget re-armed)")
    func stuckGuardRevalidatedOnActor() async throws {
        let clock = TestClock()
        let (env, card) = try await exhausted(clock)
        for _ in 0..<6 { await env.svc.reconcile() }
        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince != nil)

        // A confirm/send resets the budget — the contract's other re-arm. The next flip attempt must
        // not re-flip off the stale count.
        _ = try await env.svc.store.update(card.id) { $0.deliveryStuckSince = nil }
        await env.svc.resetDeliveryAttemptsForTest(card.id)
        await env.svc.reconcile()
        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince == nil)
    }

    /// 02 §deliverable-card: "Dead and not resumable → stuck-eligible directly." B4 reaches that end
    /// state through the uniform charge→flip path rather than a special case (declared deviation).
    @Test("a dead, unresumable card converges to stuck rather than retrying forever")
    func deadUnresumableGoesStuck() async throws {
        let clock = TestClock()
        let (env, card) = try await exhausted(clock)
        await env.svc.markDead(card.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.deleteTranscript(for: card.agentSessionId!)   // nothing to resume

        for _ in 0..<6 { await env.svc.reconcile() }

        let stuck = try #require(await env.svc.store.get(card.id))
        #expect(stuck.deliveryStuckSince != nil)
        #expect(await env.svc.inbox.peek(card.id).count == 1)      // durable, never silently dropped
    }

    /// Wave-1 T3 regression (Codex). The stuck rule is UNCONDITIONAL on route, but a RESUMABLE card's only
    /// route is a cold relaunch that bumps the epoch the post-wake flip is fenced to — so before the
    /// pre-wake flip a boots-but-never-confirms card relaunch-churned forever and NEVER set
    /// `deliveryStuckSince`. B5b is surfacing-only (reads a B4-stable flag), so it cannot surface a state
    /// B4 never sets: the arm itself must reach the terminal state. After ≥5 charged attempts and an aged
    /// message, the arm must flip stuck BEFORE the next relaunch (card stays `.live`, does not churn).
    @Test("a resumable card that never confirms flips stuck instead of relaunch-churning forever")
    func resumableNeverConfirmingFlipsStuck() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, clock: clock, now: clock.dateProvider())
        await env.svc.setDeliveryBackoff(0)
        // A RESUMABLE, graduated, live-waiting card: its transcript exists, so wake's ONLY route is a cold
        // relaunch (the churn path). Contrast `idleUnresumable`, which has no route and flips via the
        // post-wake path already covered above.
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 0)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "b"))
        env.adapter.writeTranscript(for: card.agentSessionId!)
        try await env.svc.report(card.id, StatusReport(run: .waiting(.humanTurn)))
        await env.svc.reconcile()                                    // graduate (no message yet ⇒ no charge)
        try await env.svc.inbox.enqueue(card.id, "never confirms")   // stamped at clock t0
        // Spend the retry budget directly — the same shortcut `ackWithoutNotifyCannotSuppressStuck` uses;
        // in production these accrue one-per-expired-relaunch-token over the churn cycles.
        for _ in 0..<OrchestraService.deliveryStuckAttemptThreshold { await env.svc.chargeDeliveryAttempt(card.id) }
        clock.advance(by: .seconds(301))                            // oldest message older than deliveryStuckAfter

        await env.svc.reconcile()

        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.deliveryStuckSince != nil)                    // the terminal state is REACHED (never set before the fix)
        #expect(after.phase.kind == .live)                          // flipped BEFORE the next relaunch — no churn
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["never confirms"])   // durable throughout
    }

    /// Wave-1 T3 (Codex, MAJOR follow-up). A `.dead(.resumeFailed)` card is STILL resumable — `isResumable`
    /// keys on capability + session id + transcript existence, with NO deadReason check — so it skips the
    /// unresumable-dead shortcut and reaches the pre-wake flip. The live-waiting fix's `expectDead == false`
    /// would reject its dead phase, letting it relaunch-churn forever (the reviewer's fifth-relaunch-fails
    /// path). The flip must expect `.dead` when its snapshot is dead, while still requiring the ≥5 budget.
    @Test("a resumable DEAD card that never confirms flips stuck instead of relaunch-churning")
    func resumableDeadNeverConfirmingFlipsStuck() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, clock: clock, now: clock.dateProvider())
        await env.svc.setDeliveryBackoff(0)
        await env.svc.setStartupConfirmation(graceSeconds: 0, maxRetries: 0)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: TestEnv.repo(env.base), branch: "b"))
        env.adapter.writeTranscript(for: card.agentSessionId!)      // transcript retained ⇒ resumable even when dead
        try await env.svc.report(card.id, StatusReport(run: .waiting(.humanTurn)))
        await env.svc.reconcile()                                   // graduate
        try await env.svc.inbox.enqueue(card.id, "never confirms")
        // Dead but resumable (transcript intact, session id retained) — the reviewer's "fifth relaunch
        // claims the message but launch fails, leaving .dead(.resumeFailed)" state. markDead does not bump
        // the epoch, so any relaunch by the arm would.
        await env.svc.markDead(card.id, reason: .resumeFailed, detail: "launch failed", source: .daemon)
        let deadEpoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        for _ in 0..<OrchestraService.deliveryStuckAttemptThreshold { await env.svc.chargeDeliveryAttempt(card.id) }
        clock.advance(by: .seconds(301))

        await env.svc.reconcile()

        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.deliveryStuckSince != nil)                    // terminal state reached (dead phase now owned)
        #expect(after.phase.kind == .dead)                          // did NOT relaunch
        #expect(after.sessionEpoch == deadEpoch)                    // and did NOT bump the epoch
        #expect(try await env.svc.inboxPeek(card.id).map(\.text) == ["never confirms"])   // durable
    }

    /// The wave-1 fix (aeffa75) epoch-fences the held-relaunch confirm, so a stale-generation held
    /// lease is now NEVER confirmed — it must expire and be re-driven. The arm's expiry charge is what
    /// terminates the path: without it the token sits outstanding forever.
    @Test("a stale-generation held lease reaches the expiry charge instead of sitting outstanding")
    func staleHeldLeaseReachesExpiryCharge() async throws {
        let clock = TestClock()
        let env = TestEnv.make(grace: 2, clock: clock, now: clock.dateProvider())
        await env.svc.setDeliveryBackoff(3600)
        let card = try await idleUnresumable(env)
        try await env.svc.inbox.enqueue(card.id, "held at an old generation")
        let oldEpoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        let batch = try #require(try await env.svc.inbox.claim(
            card.id, route: .relaunchSeed, epoch: oldEpoch, budget: StopDrain.maxPayloadChars,
            render: { HandoffSeed.compose(handoff: nil, messages: $0, budget: $1) },
            now: clock.dateProvider()()))
        await env.svc.markDispatched(card.id, token: batch.token)
        // ACTUALLY make the lease stale-generation — the point of the test. Without this bump the lease
        // is merely current-and-expiring, which exercises a different (easier) path.
        _ = try await env.svc.store.update(card.id) { $0.sessionEpoch = oldEpoch + 1 }
        #expect(await env.svc.inbox.peek(card.id).first?.lease?.epoch == oldEpoch)

        clock.advance(by: .seconds(61))
        await env.svc.reconcile()

        #expect(await env.svc.outstandingTokenCountForTest(card.id) == 0)   // charged, not stranded
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) >= 1)
        #expect(await env.svc.inbox.peek(card.id).count == 1)               // still durable
    }

    /// Impl-review MAJOR: the direct-dead bypass computes `!isResumable` on a pre-await snapshot, and
    /// `isResumable` suspends. A `restart` reviving the card (→ `.relaunching`, epoch++) during that
    /// window must NOT leave a false stuck flag on the now-reviving generation — the flip's
    /// `expectedEpoch` fence aborts it.
    @Test("a restart reviving a dead card mid-flip leaves NO false stuck flag")
    func deadBypassFencedAgainstRevival() async throws {
        let clock = TestClock()
        let (env, card) = try await exhausted(clock)   // live, unresumable, old message
        await env.svc.markDead(card.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.deleteTranscript(for: card.agentSessionId!)   // unresumable ⇒ dead-bypass path
        let deadEpoch = try #require(await env.svc.store.get(card.id)).sessionEpoch

        // In the isResumable→flip window, revive the card: restart moves .dead → .relaunching, epoch++.
        let gate = Gate()
        await env.svc.setDeadBypassPauseForTest { _ = await gate.park() }
        let ticking = _Concurrency.Task { await env.svc.reconcile() }
        await gate.reached()
        _ = try await env.svc.restart(card.id)
        gate.release()
        await ticking.value

        let after = try #require(await env.svc.store.get(card.id))
        #expect(after.sessionEpoch > deadEpoch)                    // genuinely superseded
        #expect(after.deliveryStuckSince == nil)                   // NO false flag on the reviving gen
        #expect(await env.svc.inbox.peek(card.id).count == 1)      // message still durable
    }

    @Test("an emptied inbox clears the stuck flag")
    func drainClearsStuck() async throws {
        let clock = TestClock()
        let (env, card) = try await exhausted(clock)
        for _ in 0..<6 { await env.svc.reconcile() }
        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince != nil)

        for m in try await env.svc.inboxPeek(card.id) { try await env.svc.inbox.remove(m.id) }
        await env.svc.reconcile()

        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince == nil)
    }

    @Test("stuck survives a daemon restart via the PERSISTED message age + flag")
    func stuckSurvivesRestartViaAge() async throws {
        let clock = TestClock()
        let (env, card) = try await exhausted(clock)
        for _ in 0..<6 { await env.svc.reconcile() }
        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince != nil)

        let fresh = TestEnv.remake(base: env.base, clock: clock, now: clock.dateProvider())
        let reread = try #require(await fresh.svc.store.get(card.id))
        #expect(reread.deliveryStuckSince != nil)                  // read back from disk
        #expect(await fresh.svc.inbox.peek(card.id).count == 1)     // message still durable
    }
}
