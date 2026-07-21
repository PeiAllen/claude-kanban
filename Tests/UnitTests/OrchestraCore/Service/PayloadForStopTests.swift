import Testing
import Foundation
@testable import OrchestraCore
import TestSupport

/// B2 — the busy (Stop-hook) delivery path: claim-then-confirm with an epoch fence, a `stopHookActive`
/// confirm, and a live-lease guard so a later Stop can never confirm the wrong batch.
@Suite("B2 · payloadForStop")
struct PayloadForStopTests {
    static let fit: @Sendable ([InboxMessage], Int) -> (payload: String, consumed: Int)? = { StopDrain.fit($0, budget: $1) }

    private static func liveCard(_ svc: OrchestraService, _ base: String) async throws -> (id: UUID, epoch: Int) {
        let card = try await TestEnv.spawnAndAwaitLive(
            svc, SpawnInput(id: UUID(), prompt: "t", repo: TestEnv.repo(base), branch: "b"))
        // Re-fetch the CURRENT epoch (spawn/launch may have advanced it) so the fence matches.
        let epoch = try #require(await svc.store.get(card.id)).sessionEpoch
        return (card.id, epoch)
    }

    /// Claim m into a held stopDrain lease (the "prior continuation's batch"), returning the token.
    @discardableResult
    private static func claimHeld(_ svc: OrchestraService, _ card: UUID, _ epoch: Int, _ text: String) async throws -> UUID {
        let inbox = await svc.inbox
        try await inbox.enqueue(card, text)
        let batch = try #require(try await inbox.claim(card, route: .stopDrain, epoch: epoch,
                                                       budget: 10_000, render: Self.fit, now: Date()))
        await svc.markDispatched(card, token: batch.token)
        return batch.token
    }

    // MARK: confirm

    @Test("a stopHookActive Stop confirms the prior stopDrain lease (removes it from the inbox)")
    func stopHookActiveConfirmsPriorLease() async throws {
        let env = TestEnv.make()
        let c = try await Self.liveCard(env.svc, env.base)
        try await Self.claimHeld(env.svc, c.id, c.epoch, "prior")

        _ = await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: true)

        #expect(await env.svc.inbox.peek(c.id).isEmpty)   // the continuation ran → its batch is confirmed
    }

    @Test("a plain / human-turn Stop (stopHookActive false) confirms nothing")
    func plainStopConfirmsNothing() async throws {
        let env = TestEnv.make()
        let c = try await Self.liveCard(env.svc, env.base)
        let token = try await Self.claimHeld(env.svc, c.id, c.epoch, "prior")

        _ = await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: false)

        let held = await env.svc.inbox.peek(c.id)
        #expect(held.count == 1)                          // prior batch NOT confirmed (may be a lost reply)
        #expect(held.first?.lease?.token == token)        // still leased under the same token
    }

    @Test("the confirm rides the stopHookActive arg directly, so a report-less bg-yield Stop still confirms")
    func bgYieldContinuationStillConfirms() async throws {
        let env = TestEnv.make()
        let c = try await Self.liveCard(env.svc, env.base)
        try await Self.claimHeld(env.svc, c.id, c.epoch, "prior")

        // No StatusReport is involved — payloadForStop takes stopHookActive as a plain arg (that is WHY the
        // field is a sibling, not Adapter.parse): a continuation that yielded to background work confirms.
        _ = await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: true)

        #expect(await env.svc.inbox.peek(c.id).isEmpty)
    }

    // MARK: epoch fence

    @Test("a nil-epoch Stop claims nothing and confirms nothing (leaves messages durable)")
    func nilEpochStopClaimsNothing() async throws {
        let env = TestEnv.make()
        let c = try await Self.liveCard(env.svc, env.base)
        try await env.svc.inbox.enqueue(c.id, "pending")

        #expect(await env.svc.payloadForStop(c.id, observedEpoch: nil, stopHookActive: true) == nil)
        #expect(await env.svc.inbox.peek(c.id).count == 1)   // still pending, unleased
        #expect(await env.svc.inbox.peek(c.id).first?.lease == nil)
    }

    @Test("a stale-epoch Stop claims nothing and confirms nothing")
    func staleEpochStopClaimsNothing() async throws {
        let env = TestEnv.make()
        let c = try await Self.liveCard(env.svc, env.base)
        let token = try await Self.claimHeld(env.svc, c.id, c.epoch, "prior")

        // A superseded session's Stop (epoch mismatch) must neither confirm the prior lease nor claim anew.
        #expect(await env.svc.payloadForStop(c.id, observedEpoch: c.epoch + 9, stopHookActive: true) == nil)
        #expect(await env.svc.inbox.peek(c.id).first?.lease?.token == token)   // prior lease untouched
    }

    // MARK: live-lease guard (BLOCKER regression)

    @Test("a false Stop does not claim a second batch while a lease is outstanding, so the later true Stop can't confirm the wrong one")
    func falseStopDoesNotClaimWhileLeaseOutstanding() async throws {
        let env = TestEnv.make()
        let c = try await Self.liveCard(env.svc, env.base)
        let inbox = await env.svc.inbox
        let m1 = try await Self.claimHeld(env.svc, c.id, c.epoch, "m1")   // prior, held (lost-reply flavor)
        try await inbox.enqueue(c.id, "m2")                                // a fresh message arrives

        // A false Stop must NOT claim m2 into a SECOND same-epoch lease.
        #expect(await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: false) == nil)
        let after = await inbox.peek(c.id)
        #expect(after.count == 2)
        #expect(after.filter { $0.lease != nil }.map { $0.lease!.token } == [m1])   // ONLY m1 leased
        #expect(after.first(where: { $0.text.contains("m2") })?.lease == nil)       // m2 still unleased

        // The later true Stop confirms the SINGLE outstanding lease (m1) — no `.first` ambiguity — then
        // claims m2. m1 is never silently dropped.
        let payload = await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: true)
        #expect(payload?.contains("m2") == true)
        let end = await inbox.peek(c.id)
        #expect(end.count == 1)                                    // m1 confirmed away
        #expect(end.first?.text.contains("m2") == true)
        #expect(end.first?.lease?.route == .stopDrain)             // m2 now leased
    }

    @Test("two concurrent same-epoch Stops never create two stopDrain leases (the guard is atomic with the claim)")
    func concurrentStopsNeverDoubleLease() async throws {
        let env = TestEnv.make()
        let c = try await Self.liveCard(env.svc, env.base)
        let inbox = await env.svc.inbox
        // Two messages that do NOT both fit one budget, so a racing (non-atomic) guard+claim would lease
        // them under two separate tokens.
        let big = String(repeating: "z", count: 6_000)
        try await inbox.enqueue(c.id, "a-" + big)
        try await inbox.enqueue(c.id, "b-" + big)

        // Two concurrent Stop deliveries for the same card+epoch reenter payloadForStop on the service actor.
        async let p1 = env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: false)
        async let p2 = env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: false)
        _ = await (p1, p2)

        // At most ONE live stopDrain lease exists — never two (which would let a later stopHookActive Stop's
        // `.first` confirm remove the wrong batch). Because the check is inside the atomic claim, this holds
        // regardless of how the two reentrant calls interleave.
        let tokens = Set(await inbox.peek(c.id).compactMap { $0.lease }.filter { $0.route == .stopDrain }.map { $0.token })
        #expect(tokens.count <= 1)
        #expect(await inbox.peek(c.id).count == 2)   // both messages durable (leased or pending) — none lost
    }

    // MARK: claim + loop-guard semantics

    @Test("confirming and claiming happen in one call (confirm prior, return the next batch)")
    func confirmingStopClaimsNextBatchSameCall() async throws {
        let env = TestEnv.make()
        let c = try await Self.liveCard(env.svc, env.base)
        let inbox = await env.svc.inbox
        try await Self.claimHeld(env.svc, c.id, c.epoch, "prior")
        try await inbox.enqueue(c.id, "next")

        let payload = await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: true)
        #expect(payload?.contains("next") == true)                 // the NEXT batch, this call
        let end = await inbox.peek(c.id)
        #expect(end.count == 1)                                    // "prior" confirmed away
        #expect(end.first?.text.contains("next") == true)
    }

    @Test("the inject loop guard caps consecutive auto-injects and resets on a real user prompt")
    func payloadForStopKeepsInjectCountSemantics() async throws {
        let env = TestEnv.make()
        let c = try await Self.liveCard(env.svc, env.base)
        let inbox = await env.svc.inbox
        let cap = await env.svc.maxConsecutiveInjects

        // The healthy continuation loop: each turn confirms the prior batch (stopHookActive) then claims
        // the next fresh message, so the counter climbs to the cap.
        for i in 0..<cap {
            try await inbox.enqueue(c.id, "m\(i)")
            let p = await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: i > 0)
            #expect(p != nil)                                      // claimed each time up to the cap
        }
        // At the cap the guard trips: the prior batch still confirms, but no new inject.
        try await inbox.enqueue(c.id, "over")
        #expect(await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: true) == nil)
        #expect(await env.svc.inbox.peek(c.id).map(\.text) == ["over"])   // durable, unleased — never lost

        // A genuine user prompt resets the guard → injects again.
        await env.svc.resetInjectCount(c.id)
        let after = await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: true)
        #expect(after?.contains("over") == true)
    }

    @Test("an empty (lease-free) inbox resets the inject counter to 0")
    func emptyInboxResetsCounter() async throws {
        let env = TestEnv.make()
        let c = try await Self.liveCard(env.svc, env.base)
        try await env.svc.inbox.enqueue(c.id, "one")
        _ = await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: false)   // count → 1
        #expect(await env.svc.injectCounts[c.id] == 1)
        // Confirm it away, so the inbox is genuinely lease-free empty, then a Stop resets the counter.
        _ = await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: true)
        #expect(await env.svc.inbox.peek(c.id).isEmpty)
        #expect(await env.svc.injectCounts[c.id] == 0)
    }

    @Test("delivers whole-messages-to-fit under the 10k budget, deferring the overflow across turns, never losing one")
    func drainsWholeMessagesToFitAcrossTurns() async throws {
        let env = TestEnv.make()
        let c = try await Self.liveCard(env.svc, env.base)
        let inbox = await env.svc.inbox
        let big = String(repeating: "x", count: 4_000)          // 3×~4k + header overflows one 10k payload
        for i in 0..<3 { try await inbox.enqueue(c.id, "\(i)-" + big) }

        // Turn 1: claim+lease the fitted prefix, bounded by the budget (the overflow stays pending).
        let first = await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: false)
        #expect(first != nil)
        #expect(first!.count <= StopDrain.maxPayloadChars)
        // The deferred overflow (still unleased) keeps its FULL text — never sliced mid-message.
        let overflow = await inbox.peek(c.id).filter { $0.lease == nil }
        #expect(!overflow.isEmpty)
        #expect(overflow.allSatisfy { $0.text.count == big.count + 2 })   // "i-" prefix = +2
        // Turn 2: the continuation's Stop confirms the prior prefix, then claims the overflow.
        #expect(await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: true) != nil)
        // Turn 3: confirm the last batch → nothing left; every one of the 3 messages was delivered whole.
        #expect(await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: true) == nil)
        #expect(await inbox.peek(c.id).isEmpty)
    }

    // MARK: post-claim epoch re-guard (wave-1 T3 regression)

    /// The step-1 epoch fence is only an ENTRY check. The service actor is reentrant, so a restart can
    /// persist epoch e+1 DURING payloadForStop's peek/confirm/claim awaits — and `blockIfLiveLease`
    /// won't catch it (it is epoch-e-scoped). Without the post-claim re-guard, the stale-e claim mints a
    /// lease and returns fresh payload to the SUPERSEDED Stop's pane (about to be killed by the relaunch),
    /// leasing messages the e+1 relaunch then re-owns and re-delivers — the stale-pane injection + duplicate
    /// the locked Stop fence forbids. The re-guard must RELEASE the batch and return nil, leaving the
    /// message durable and unleased for the new generation. (Found by the wave-1 T3 review pair.)
    @Test("a restart landing during the stopDrain claim releases the stale-epoch batch and returns nil")
    func stopClaimLosingEpochReleasesAndReturnsNil() async throws {
        let env = TestEnv.make()
        let c = try await Self.liveCard(env.svc, env.base)
        try await env.svc.inbox.enqueue(c.id, "deliver me")

        let gate = Gate()
        await env.svc.setStopClaimPauseForTest { _ = await gate.park() }
        let stop = _Concurrency.Task {
            await env.svc.payloadForStop(c.id, observedEpoch: c.epoch, stopHookActive: false)
        }
        await gate.reached()                 // parked AFTER the claim, BEFORE the re-guard
        try await env.svc.restart(c.id)      // → .relaunching, epoch e+1: supersedes the Stop's generation
        gate.release()

        #expect(await stop.value == nil)     // stale-epoch payload is NOT handed to the dying pane
        let after = await env.svc.inbox.peek(c.id)
        #expect(after.map(\.text) == ["deliver me"])              // durable — never lost
        #expect(after.allSatisfy { $0.lease == nil })             // and NOT left leased at the stale epoch
        #expect(await env.svc.outstandingTokenCountForTest(c.id) == 0)   // no phantom dispatched token
    }
}
