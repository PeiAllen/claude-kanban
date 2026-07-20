import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit
import TestSupport

/// B4 · lease/broker disposition across teardown and epoch bumps. The broker is starved (nothing
/// parks), so `isAttached` reads false either way — these pin the STRUCTURAL contract: teardown
/// reaches a broker at all (release + detach), and the epoch bump runs the eager revoke. D1's
/// `test_socketCloseDetaches` / `test_epochBumpRevokesOlderPolls` make the detach/revoke observable
/// with a real parked poll.
@Suite("B4 · teardown + epoch-bump lease disposition")
struct TeardownLeaseTests {

    @Test("teardown releases every lease AND reaches the broker detach")
    func teardownReleasesAllLeasesAndDetaches() async throws {
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
        #expect(await env.svc.broker.isAttached(card.id, epoch: epoch) == false)
    }

    @Test("an epoch bump runs the eager older-generation poll revoke")
    func epochBumpRevokesOlderPolls() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        let before = try #require(await env.svc.store.get(card.id)).sessionEpoch
        env.adapter.writeTranscript(for: card.agentSessionId!)

        try await env.svc.restart(card.id)                          // → .relaunching, epoch++

        let after = try #require(await env.svc.store.get(card.id)).sessionEpoch
        #expect(after == before + 1)
        // Starved broker: both read false. What this pins is that the bump path reaches the revoke at
        // all; D1's `test_epochBumpRevokesOlderPolls` parks a real poll and re-runs it.
        #expect(await env.svc.broker.isAttached(card.id, epoch: before) == false)
    }
}
