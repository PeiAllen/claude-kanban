import Foundation
import Testing
import TestSupport

@Suite("TestClock — deterministic time")
struct TestClockTests {
    @Test("advance resumes a parked sleeper; wall-clock does not")
    func advanceResumes() async throws {
        let clock = TestClock()
        let done = Signal()
        let t = _Concurrency.Task {
            try await clock.sleep(for: .seconds(300))
            done.set()
        }
        await clock.parked(1)                  // synchronize on readiness, never on timing
        #expect(!done.isSet)
        clock.advance(by: .seconds(299))
        #expect(!done.isSet)
        clock.advance(by: .seconds(1))
        _ = try await t.value
        #expect(done.isSet)
    }

    @Test("advance past several deadlines resumes all due sleepers in one jump")
    func multiSleeper() async throws {
        let clock = TestClock()
        async let a: Void = clock.sleep(for: .seconds(5))     // SE-0317: `try` marks the read below
        async let b: Void = clock.sleep(for: .seconds(10))
        await clock.parked(2)
        clock.advance(by: .seconds(10))
        _ = try await (a, b)
    }

    @Test("parked(deadlineAtLeast:) ignores unrelated short sleepers")
    func scopedParked() async throws {
        let clock = TestClock()
        let short = _Concurrency.Task { try await clock.sleep(for: .milliseconds(750)) }   // a debounce, say
        await clock.parked(1)
        let long = _Concurrency.Task { try await clock.sleep(for: .seconds(300)) }         // the loop under test
        await clock.parked(1, deadlineAtLeast: .seconds(300))   // must NOT return early on the 750ms sleeper
        clock.advance(by: .seconds(300))
        _ = try? await short.value
        _ = try await long.value
    }

    @Test("a cancelled sleeper throws CancellationError instead of hanging teardown")
    func cancellation() async {
        let clock = TestClock()
        let t = _Concurrency.Task { try await clock.sleep(for: .seconds(60)) }
        await clock.parked(1)
        t.cancel()
        await #expect(throws: CancellationError.self) { try await t.value }
    }

    @Test("cancel racing registration cannot strand the sleeper")
    func cancelRegistrationRace() async {
        // Regression guard for the lost-cancel window: a cancel fired between checkCancellation
        // and the sleeper append must still resume-throwing (the `cancelled` id-set path).
        for _ in 0..<100 {
            let clock = TestClock()
            let t = _Concurrency.Task { try await clock.sleep(for: .seconds(60)) }
            t.cancel()                                        // no parked() — race the registration
            await #expect(throws: CancellationError.self) { try await t.value }
        }
    }

    @Test("sleep with an already-past deadline returns immediately")
    func pastDeadline() async throws {
        let clock = TestClock()
        clock.advance(by: .seconds(10))
        try await clock.sleep(until: TestClock.Instant(offset: .seconds(5)), tolerance: nil)
    }
}

/// Lock-guarded flag for asserting "has not happened yet".
final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
