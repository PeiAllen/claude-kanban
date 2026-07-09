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

    // MARK: - wire serialization (round-trip through the real codec, no live socket)

    /// `.iso8601` (the wire's date strategy) truncates to whole seconds, so any `Date` compared for
    /// equality after a round-trip must itself be whole-seconds — else the assertion would flake on
    /// sub-second precision that was never on the wire to begin with.
    private static let wholeSecondDate = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private func sampleTask() -> Task {
        Task(title: "Fix login", repo: "/repos/app", branch: "b", cwd: "/wt/app/b",
             model: AgentModel(id: "claude-sonnet-4-5"), startIn: .plan, column: .plan, order: 0,
             initialPrompt: "Fix login", createdAt: Self.wholeSecondDate, updatedAt: Self.wholeSecondDate)
    }

    /// Encode exactly the way `ControlServer.eventNotification` + `RPCCodec.line` do (wrap in an
    /// `RPCNotification` under `{method:"event", params:<EventEnvelope>}`, then NDJSON-encode), and
    /// decode exactly the way `ControlClient`'s read loop does (`WireMessage` -> `params?.decode`).
    private func roundTrip(_ envelope: EventEnvelope) throws -> EventEnvelope? {
        let notification = RPCNotification(method: "event", params: try? JSONValue(encodable: envelope))
        let line = try RPCCodec.line(notification)
        let msg = try RPCCodec.decoder.decode(WireMessage.self, from: line)
        #expect(msg.method == "event")
        return try msg.params?.decode(EventEnvelope.self)
    }

    @Test("a taskUpserted EventEnvelope round-trips through the real wire codec")
    func test_taskUpsertedEnvelopeRoundTripsThroughWireCodec() throws {
        let task = sampleTask()
        let sent = EventEnvelope(rev: 42, event: .taskUpserted(task))
        let received = try roundTrip(sent)
        #expect(received?.rev == 42)
        if case .taskUpserted(let t) = received?.event {
            #expect(t == task)
        } else {
            Issue.record("expected .taskUpserted, got \(String(describing: received?.event))")
        }
    }

    @Test("an activity EventEnvelope round-trips through the real wire codec")
    func test_activityEnvelopeRoundTripsThroughWireCodec() throws {
        let item = ActivityItem(at: Self.wholeSecondDate, taskId: nil, ref: nil, source: .daemon,
                                 kind: .command, text: "hello")
        let sent = EventEnvelope(rev: 7, event: .activity(item))
        let received = try roundTrip(sent)
        #expect(received?.rev == 7)
        if case .activity(let a) = received?.event {
            #expect(a == item)
        } else {
            Issue.record("expected .activity, got \(String(describing: received?.event))")
        }
    }
}
