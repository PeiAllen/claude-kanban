import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit
import TestSupport

/// B4 · teardown disposition of a card's delivery state: its inbox leases are released (so the
/// message is retained-but-unleased for a reopen), and its in-memory delivery-tracking maps are
/// evicted (an archived card is never re-scanned, so nothing else prunes them).
@Suite("B4 · teardown delivery disposition")
struct TeardownLeaseTests {

    @Test("teardown releases every lease — the message is retained but unleased for a reopen")
    func teardownReleasesAllLeases() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        try await env.svc.inbox.enqueue(card.id, "queued")
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch
        _ = try await env.svc.inbox.claim(card.id, route: .stopDrain, epoch: epoch,
                                          budget: StopDrain.maxPayloadChars,
                                          render: { StopDrain.fit($0, budget: $1) }, now: Date())
        #expect(await env.svc.inbox.peek(card.id).contains { $0.lease != nil })

        try await TestEnv.archiveAndTeardown(env.svc, card.id)

        let after = await env.svc.inbox.peek(card.id)
        #expect(after.count == 1)                                   // message RETAINED for a reopen
        #expect(after.allSatisfy { $0.lease == nil })               // …but unleased
    }

    @Test("teardown clears a card's delivery-tracking maps (no per-card leak)")
    func teardownClearsDeliveryMaps() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        // Populate both maps the way a real in-flight dispatch + a failed attempt would.
        await env.svc.markDispatched(card.id, token: UUID())
        await env.svc.chargeDeliveryAttempt(card.id)
        #expect(await env.svc.outstandingTokenCountForTest(card.id) == 1)
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 1)

        try await TestEnv.archiveAndTeardown(env.svc, card.id)

        // An archived card is never re-scanned by confirm/expiry, so teardown must evict both entries
        // or they leak one-per-card for the daemon's lifetime.
        #expect(await env.svc.outstandingTokenCountForTest(card.id) == 0)
        #expect(await env.svc.deliveryAttemptCountForTest(card.id) == 0)
    }
}
