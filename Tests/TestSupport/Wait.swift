import Foundation

/// Thrown when `pollUntil` gives up. It is an ERROR, not an `#expect` — a wait that timed out has
/// invalidated the test's premise, so the test must ABORT here rather than press on and produce a
/// misleading downstream assertion failure against a card that never reached the expected state.
public struct PollTimeout: Error, CustomStringConvertible {
    public let what: String
    public let waited: Duration
    public let polls: Int
    public init(what: String, waited: Duration, polls: Int) {
        self.what = what; self.waited = waited; self.polls = polls
    }
    public var description: String {
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
/// 2. **The inter-poll wait is a YIELD, not a wall-clock sleep.** The happy path costs no wall-clock at
///    all: each miss re-runs `cond()` as soon as the cooperative pool has run whatever the condition is
///    waiting on. The `timeout` parameter survives purely as the FAILURE backstop — a coarse ContinuousClock
///    deadline that only a genuinely stuck test ever reaches.
///
/// The budget is bounded by BOTH the wall-clock deadline and a floor on the number of attempts, and it gives
/// up only when both are spent — a convergence guard must give the condition enough CHANCES to converge
/// *and* refuse to hang forever. The happy path is unaffected (it returns the instant the condition holds);
/// only a genuinely stuck test pays the full bound.
///
/// A pure yield-loop can starve the cooperative pool under `--parallel` (a spinning poller monopolizes a
/// pool thread that the awaited work needs), so yields come in batches: after every 1000 fruitless polls
/// the loop makes ONE 1ms wall-clock sleep to guarantee everyone else gets scheduled.
public func pollUntil(_ what: String = "condition", timeout: Duration = .seconds(120), minPolls: Int = 12,
                      _ cond: @Sendable () async -> Bool) async throws {
    let start = ContinuousClock.now
    let deadline = start + timeout
    var polls = 0
    while true {
        try _Concurrency.Task.checkCancellation()   // a cancelled poller must stop, not spin out its deadline
        polls += 1
        if await cond() { return }
        if ContinuousClock.now >= deadline && polls >= minPolls { break }
        if polls % 1000 == 0 {
            try? await _Concurrency.Task.sleep(for: .milliseconds(1))   // backstop sleep: the ONLY sanctioned wall-clock wait, lint-allowlisted via Wait.swift
        } else {
            await _Concurrency.Task.yield()
        }
    }
    throw PollTimeout(what: what, waited: start.duration(to: .now), polls: polls)
}

/// Give already-scheduled asynchronous work ample chances to run WITHOUT wall-clock: a bounded burst
/// of cooperative yields. The deterministic replacement for "sleep, then assert nothing happened" —
/// a wrongfully-dispatched task (an event fan-out, a detached wake, an unstructured step) that was
/// scheduled before this call gets scheduled during it, so the caller's negative assertion sees its
/// effect. A correctly-idle system pays nothing but the yields.
public func yieldBriefly(_ rounds: Int = 200) async {
    for _ in 0..<rounds { await _Concurrency.Task.yield() }
}

/// Race `body` against a yield-based deadline: nil if it did not finish in time. The failure backstop
/// for "this must resolve rather than park forever" assertions — the deadline task never sleeps
/// (beyond pollUntil's allowlisted backstop), and `cancelAll` stops the loser immediately.
public func withDeadline<T: Sendable>(_ timeout: Duration = .seconds(120),
                                      _ body: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { g in
        g.addTask { await body() }
        g.addTask { try? await pollUntil("deadline", timeout: timeout) { false }; return nil }
        let first = await g.next() ?? nil
        g.cancelAll()
        return first
    }
}
