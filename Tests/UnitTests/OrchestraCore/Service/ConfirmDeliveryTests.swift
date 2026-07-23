import Testing
import Foundation
@testable import OrchestraCore

/// B2 — the single delivery-confirm funnel. A message leaves the durable inbox ONLY through
/// `confirmDelivery`, and the attempt/stuck resets happen ONLY on a real confirmation — never on a
/// stale-token no-op or an archive release (a late ack from a superseded attempt can't re-arm the budget).
@Suite("B2 · confirmDelivery funnel")
struct ConfirmDeliveryTests {
    static let fit: @Sendable ([InboxMessage], Int) -> (payload: String, consumed: Int)? = { StopDrain.fit($0, budget: $1) }

    private static func liveCard(_ env: (svc: OrchestraService, base: String)) async throws -> Task {
        try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "t", repo: TestEnv.repo(env.base), branch: "b"))
    }

    @Test("a real confirm removes the batch, prunes the outstanding token, and clears deliveryStuckSince")
    func realConfirm() async throws {
        let env = TestEnv.make()
        let card = try await Self.liveCard((env.svc, env.base))
        let inbox = await env.svc.inbox
        try await inbox.enqueue(card.id, "queued")
        let batch = try #require(try await inbox.claim(card.id, route: .stopDrain, epoch: card.sessionEpoch,
                                                       budget: 10_000, render: Self.fit, now: Date()))
        await env.svc.markDispatched(card.id, token: batch.token)
        _ = try await env.svc.store.update(card.id) { $0.deliveryStuckSince = Date() }

        await env.svc.confirmDelivery(token: batch.token, cardId: card.id)

        #expect(await inbox.peek(card.id).isEmpty)                                   // the ONLY removal path
        #expect(await env.svc.runtime[card.id]?.outstandingTokens.isEmpty == true)   // token pruned
        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince == nil)  // stuck cleared
    }

    @Test("a stale-token confirm removes nothing and resets no delivery state (superseded-ack guard)")
    func staleTokenNoOp() async throws {
        let env = TestEnv.make()
        let card = try await Self.liveCard((env.svc, env.base))
        let inbox = await env.svc.inbox
        try await inbox.enqueue(card.id, "queued")
        let batch = try #require(try await inbox.claim(card.id, route: .stopDrain, epoch: card.sessionEpoch,
                                                       budget: 10_000, render: Self.fit, now: Date()))
        await env.svc.markDispatched(card.id, token: batch.token)
        let stuckAt = Date(timeIntervalSince1970: 42)
        _ = try await env.svc.store.update(card.id) { $0.deliveryStuckSince = stuckAt }

        await env.svc.confirmDelivery(token: UUID(), cardId: card.id)   // a stale / unknown token → no-op

        #expect(await inbox.peek(card.id).count == 1)                                // message retained
        #expect(await env.svc.runtime[card.id]?.outstandingTokens == [batch.token])  // real token still outstanding
        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince == stuckAt)  // NOT reset by a no-op
    }

    @Test("an archived card releases (retains) the message instead of confirming, and resets nothing")
    func archivedReleases() async throws {
        let env = TestEnv.make()
        let card = try await Self.liveCard((env.svc, env.base))
        let inbox = await env.svc.inbox
        try await inbox.enqueue(card.id, "queued")
        let batch = try #require(try await inbox.claim(card.id, route: .stopDrain, epoch: card.sessionEpoch,
                                                       budget: 10_000, render: Self.fit, now: Date()))
        await env.svc.markDispatched(card.id, token: batch.token)
        let stuckAt = Date(timeIntervalSince1970: 42)
        _ = try await env.svc.store.update(card.id) {
            $0.phase = .archived(teardownComplete: true); $0.archived = true; $0.deliveryStuckSince = stuckAt
        }

        await env.svc.confirmDelivery(token: batch.token, cardId: card.id)

        let remaining = await inbox.peek(card.id)
        #expect(remaining.count == 1)                                                // retained for a reopen
        #expect(remaining.first?.lease == nil)                                       // lease released
        #expect(await env.svc.outstandingTokenCountForTest(card.id) == 0)            // no longer in flight
        #expect(try #require(await env.svc.store.get(card.id)).deliveryStuckSince == stuckAt)  // release ≠ confirm
    }
}
