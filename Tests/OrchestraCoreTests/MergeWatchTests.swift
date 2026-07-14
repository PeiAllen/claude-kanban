import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

@Suite("C2 · MergeWatch continuation registry (subscriber, not detector)")
struct MergeWatchTests {

    @Test("awaitConclusion resolves when the watched card concludes")
    func resolvesOnConclude() async throws {
        let mw = MergeWatch()
        let a = UUID()
        let waiting = _Concurrency.Task { await mw.awaitConclusion([a]) }
        try await pollUntil { await mw.subscriptionCount() == 1 }
        await mw.conclude(Conclusion(cardId: a, ref: "orchestra://task/aaaaaa", kind: .done))
        let got = await waiting.value
        #expect(got?.cardId == a)
        #expect(got?.kind == .done)
        #expect(await mw.subscriptionCount() == 0)   // resolved subscription removed
    }

    @Test("a set watcher resolves on the FIRST of its cards to conclude")
    func firstOfSet() async throws {
        let mw = MergeWatch()
        let a = UUID(); let b = UUID()
        let waiting = _Concurrency.Task { await mw.awaitConclusion([a, b]) }
        try await pollUntil { await mw.subscriptionCount() == 1 }
        await mw.conclude(Conclusion(cardId: b, ref: "r", kind: .exited))
        #expect(await waiting.value?.cardId == b)
    }

    @Test("conclude for an unwatched card resolves nothing")
    func unwatchedNoop() async throws {
        let mw = MergeWatch()
        let a = UUID(); let other = UUID()
        let waiting = _Concurrency.Task { await mw.awaitConclusion([a]) }
        try await pollUntil { await mw.subscriptionCount() == 1 }
        // `conclude` is an actor call: by the time the await returns, the registry has fully
        // processed it — if it were (wrongly) going to resolve our subscription, the removal
        // would already have happened. No settling wait is needed for the negative assertion.
        await mw.conclude(Conclusion(cardId: other, ref: "r", kind: .done))
        #expect(await mw.subscriptionCount() == 1)   // still subscribed
        await mw.conclude(Conclusion(cardId: a, ref: "r", kind: .done))   // cleanup
        _ = await waiting.value
    }

    /// The lost wakeup that hung `wait` forever. A conclusion that lands while a subscriber is ARMED but has
    /// not yet parked must be RETAINED, not dropped — that gap is exactly where `wait` sits while it reads
    /// card state (it subscribes first, then reads, so that no conclusion can fall between the two).
    @Test("a conclusion landing between subscribe and park is retained, not dropped")
    func retainedBetweenSubscribeAndPark() async throws {
        let mw = MergeWatch()
        let a = UUID()
        let token = await mw.subscribe([a])                     // armed; nobody parked yet
        await mw.conclude(Conclusion(cardId: a, ref: "r", kind: .exited, deadReason: .sessionVanished))
        let got = await mw.awaitConclusion(token: token)        // must return immediately, not hang
        #expect(got?.cardId == a)
        #expect(got?.deadReason == .sessionVanished)
        #expect(await mw.subscriptionCount() == 0)
    }

    /// An armed subscription the caller resolved from card state instead is dropped cleanly.
    @Test("unsubscribe drops an armed subscription")
    func unsubscribeDropsArmed() async throws {
        let mw = MergeWatch()
        let token = await mw.subscribe([UUID()])
        #expect(await mw.subscriptionCount() == 1)
        await mw.unsubscribe(token)
        #expect(await mw.subscriptionCount() == 0)
        #expect(await mw.awaitConclusion(token: token) == nil)   // a dropped token never parks
    }

    @Test("cancellation resolves awaitConclusion with nil and drops the subscription")
    func cancel() async throws {
        let mw = MergeWatch()
        let a = UUID()
        let waiting = _Concurrency.Task { await mw.awaitConclusion([a]) }
        try await pollUntil { await mw.subscriptionCount() == 1 }
        waiting.cancel()
        #expect(await waiting.value == nil)
        #expect(await mw.subscriptionCount() == 0)
    }
}
