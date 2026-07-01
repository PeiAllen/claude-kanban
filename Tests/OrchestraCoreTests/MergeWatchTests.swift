import Foundation
import Testing
@testable import OrchestraCore

@Suite("C2 · MergeWatch continuation registry (subscriber, not detector)")
struct MergeWatchTests {

    @Test("awaitConclusion resolves when the watched card concludes")
    func resolvesOnConclude() async throws {
        let mw = MergeWatch()
        let a = UUID()
        let waiting = _Concurrency.Task { await mw.awaitConclusion([a]) }
        try await pollUntil { await mw.waiterCount() == 1 }
        await mw.conclude(Conclusion(cardId: a, ref: "orchestra://task/aaaaaa", kind: .done))
        let got = await waiting.value
        #expect(got?.cardId == a)
        #expect(got?.kind == .done)
        #expect(await mw.waiterCount() == 0)   // resolved waiter removed
    }

    @Test("a set watcher resolves on the FIRST of its cards to conclude")
    func firstOfSet() async throws {
        let mw = MergeWatch()
        let a = UUID(); let b = UUID()
        let waiting = _Concurrency.Task { await mw.awaitConclusion([a, b]) }
        try await pollUntil { await mw.waiterCount() == 1 }
        await mw.conclude(Conclusion(cardId: b, ref: "r", kind: .exited))
        #expect(await waiting.value?.cardId == b)
    }

    @Test("conclude for an unwatched card resolves nothing")
    func unwatchedNoop() async throws {
        let mw = MergeWatch()
        let a = UUID(); let other = UUID()
        let waiting = _Concurrency.Task { await mw.awaitConclusion([a]) }
        try await pollUntil { await mw.waiterCount() == 1 }
        await mw.conclude(Conclusion(cardId: other, ref: "r", kind: .done))
        try await _Concurrency.Task.sleep(for: .milliseconds(60))
        #expect(await mw.waiterCount() == 1)   // still waiting
        await mw.conclude(Conclusion(cardId: a, ref: "r", kind: .done))   // cleanup
        _ = await waiting.value
    }

    @Test("cancellation unblocks awaitConclusion with nil and drops the waiter")
    func cancel() async throws {
        let mw = MergeWatch()
        let a = UUID()
        let waiting = _Concurrency.Task { await mw.awaitConclusion([a]) }
        try await pollUntil { await mw.waiterCount() == 1 }
        waiting.cancel()
        #expect(await waiting.value == nil)
        #expect(await mw.waiterCount() == 0)
    }
}

/// Poll a condition up to ~2s; fail if it never holds. Deterministic replacement for fixed sleeps.
func pollUntil(_ cond: @Sendable () async -> Bool) async throws {
    for _ in 0..<200 { if await cond() { return }; try await _Concurrency.Task.sleep(for: .milliseconds(10)) }
    #expect(Bool(false), "condition never became true")
}
