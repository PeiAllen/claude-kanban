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
        await mw.conclude(Conclusion(cardId: other, ref: "r", kind: .done))
        try await _Concurrency.Task.sleep(for: .milliseconds(60))
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

/// Thrown when `pollUntil` gives up. It is an ERROR, not an `#expect` — a wait that timed out has
/// invalidated the test's premise, so the test must ABORT here rather than press on and produce a
/// misleading downstream assertion failure against a card that never reached the expected state.
struct PollTimeout: Error, CustomStringConvertible {
    let what: String
    let waited: Duration
    let polls: Int
    var description: String {
        "pollUntil timed out after \(waited) (\(polls) polls) waiting for: \(what)"
    }
}

/// Poll a condition until it holds; THROW if it never does. The deterministic replacement for fixed sleeps.
///
/// Two properties matter, and the old implementation had neither:
///
/// 1. **A timeout aborts the test.** It used to `#expect(false)` and *return*, letting the caller carry on
///    against a premise that never held (e.g. `reconcileToLive` handing back a card still `.launching`).
///    The real failure then surfaced as a baffling downstream assertion (`waitReason == nil`) that reads
///    like a product bug. Throwing stops the test at the wait that actually failed.
/// 2. **The budget is WALL-CLOCK.** The old cap was 1000 iterations of `cond() + 10ms`, but `cond()` is not
///    free — it typically drives a `reconcile()` with off-actor hops, costing far more than the 10ms sleep
///    under `--parallel` load. So the real budget swung with machine load, which is precisely what a
///    flakiness bound must not do. A wall-clock deadline is the same budget on an idle and a loaded machine.
///
/// The budget is bounded by BOTH a wall-clock deadline and a floor on the number of attempts, and it gives
/// up only when both are spent. Each alone is load-sensitive in an opposite direction, which is the trap:
///
///   - Attempts alone (the original 1000-iteration cap) is a budget whose wall-clock length swings with how
///     expensive `cond()` happens to be.
///   - Wall-clock alone shrinks the number of ATTEMPTS exactly when attempts get expensive. Measured: a
///     `reconcile()` costs well under a second idle but up to ~20s under full `--parallel` load, so a flat
///     60s deadline bought a spawn only 3 tries where it needed ~5 — turning a slow machine into a failure
///     for a test that was converging perfectly well.
///
/// A convergence guard must give the condition enough CHANCES to converge *and* refuse to hang forever. So:
/// keep polling while either budget remains. The happy path is unaffected (it returns the instant the
/// condition holds); only a genuinely stuck test pays the full bound.
func pollUntil(_ what: String = "condition", timeout: Duration = .seconds(120), minPolls: Int = 12,
               _ cond: @Sendable () async -> Bool) async throws {
    let start = ContinuousClock.now
    let deadline = start + timeout
    var polls = 0
    while true {
        polls += 1
        if await cond() { return }
        if ContinuousClock.now >= deadline && polls >= minPolls { break }
        try await _Concurrency.Task.sleep(for: .milliseconds(10))
    }
    throw PollTimeout(what: what, waited: start.duration(to: .now), polls: polls)
}
