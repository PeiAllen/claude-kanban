import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

@Suite("ControlServer / event rev") struct ControlServerRevTests {
    @Test("a task-state event carries the store's rev at emit")
    func test_eventCarriesRev() async throws {
        let env = TestEnv.make()
        let card = try await env.svc.spawn(SpawnInput(prompt: "p", repo: TestEnv.repo(env.base), branch: "b"))
        let stream = await env.svc.subscribe()
        var iter = stream.makeAsyncIterator()
        _ = try await env.svc.move(card.id, to: .review)          // deterministic .taskUpserted
        let expected = await env.svc.storeCurrentRevForTest()     // = TaskStore.currentRev after the move
        // drain until the taskUpserted for our move (skip any interleaved ephemerals)
        var env0 = await iter.next()
        while env0 != nil, { if case .taskUpserted = env0!.event { return false }; return true }() {
            env0 = await iter.next()
        }
        #expect(env0?.rev == expected)
    }

    @Test("BoardSnapshot carries the store's rev")
    func test_boardSnapshotCarriesRev() async throws {
        let env = TestEnv.make()
        _ = try await env.svc.spawn(SpawnInput(prompt: "p", repo: TestEnv.repo(env.base), branch: "b"))
        let snap = await env.svc.boardSnapshot()
        #expect(snap.rev == (await env.svc.storeCurrentRevForTest()))
    }

    @Test("an ephemeral activity event carries the current board rev (lastRev mirror)")
    func test_activityEventCarriesCurrentRev() async throws {
        let env = TestEnv.make()
        let card = try await env.svc.spawn(SpawnInput(prompt: "p", repo: TestEnv.repo(env.base), branch: "b"))
        _ = try await env.svc.move(card.id, to: .review)          // primes lastRev to the current board rev
        let rev = await env.svc.storeCurrentRevForTest()
        let stream = await env.svc.subscribe()
        var iter = stream.makeAsyncIterator()
        await env.svc.emitActivityForTest()                      // ephemeral — stamps lastRev
        let e = await iter.next()
        #expect(e?.rev == rev)
        if case .activity = e?.event {} else { Issue.record("expected activity") }
    }
}
