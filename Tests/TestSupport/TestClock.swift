import Foundation

/// A manually-advanced Clock for tests.
///
/// - Stdlib `Clock` conformance: seams typed `any Clock<Duration>` accept it unchanged, and
///   `clock.sleep(for:)` (SE-0374) works as-is.
/// - `parked(_:deadlineAtLeast:)` is the anti-race primitive: a naive fake clock lets the test
///   `advance` BEFORE the code under test reaches its `sleep`, and the sleeper then never wakes.
///   Tests synchronize on "N sleepers are parked", never on timing. `deadlineAtLeast` scopes the
///   wait to the sleeper you mean — one service shares one clock across its nudge/debounce/watch
///   loops, so a bare count can be satisfied by an unrelated short sleeper.
/// - Cancellation: a `cancelled` id-set closes the lost-cancel window (an `onCancel` firing
///   between `checkCancellation` and the sleeper append must still resume-throwing). Production
///   loops are `while !Task.isCancelled { try? await clock.sleep(…) }` — a cancelled loop must
///   exit rather than hang suite teardown.
public final class TestClock: Clock, @unchecked Sendable {
    public struct Instant: InstantProtocol, Hashable, Sendable {
        public var offset: Duration
        public init(offset: Duration = .zero) { self.offset = offset }
        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (l: Instant, r: Instant) -> Bool { l.offset < r.offset }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var _now = Instant()
    private var sleepers: [Sleeper] = []
    private var cancelled: Set<UUID> = []
    private var parkWaiters: [(count: Int, minDeadline: Instant?, continuation: CheckedContinuation<Void, Never>)] = []

    public init() {}
    public var now: Instant { lock.withLock { _now } }
    public var minimumResolution: Duration { .zero }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        // Always reclaim this id from `cancelled` once the whole sleep (park + any cancellation
        // handshake) unwinds. Without it, a sleeper that resumed normally and was cancelled LATER
        // leaves its id in `cancelled` forever — an unbounded per-clock leak across a long test.
        defer { lock.withLock { _ = cancelled.remove(id) } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                enum Verdict { case resume, cancel, park }
                let verdict: Verdict = lock.withLock {
                    if cancelled.remove(id) != nil { return .cancel }      // onCancel already fired
                    if deadline <= _now { return .resume }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: c))
                    wakeParkWaitersLocked()
                    return .park
                }
                switch verdict {
                case .resume: c.resume()
                case .cancel: c.resume(throwing: CancellationError())
                case .park: break
                }
            }
        } onCancel: {
            let c: CheckedContinuation<Void, any Error>? = lock.withLock {
                guard let i = sleepers.firstIndex(where: { $0.id == id }) else {
                    cancelled.insert(id)     // not appended yet — mark for the append path
                    return nil
                }
                defer { sleepers.remove(at: i) }
                return sleepers[i].continuation
            }
            c?.resume(throwing: CancellationError())
        }
    }

    /// Jump time forward; every sleeper whose deadline has passed resumes (outside the lock).
    public func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            _now = _now.advanced(by: duration)
            let d = sleepers.filter { $0.deadline <= _now }
            sleepers.removeAll { $0.deadline <= _now }
            return d
        }
        for s in due { s.continuation.resume() }
    }

    /// Suspend until at least `count` sleepers are parked — optionally counting only sleepers
    /// whose deadline is at least `deadlineAtLeast` past the CURRENT time (scope the wait to
    /// the loop you mean, ignoring unrelated short debounce sleepers).
    public func parked(_ count: Int = 1, deadlineAtLeast: Duration? = nil) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                let minDeadline = deadlineAtLeast.map { Instant(offset: _now.offset + $0) }
                if matchingSleepersLocked(minDeadline: minDeadline) >= count { return true }
                parkWaiters.append((count, minDeadline, c))
                return false
            }
            if done { c.resume() }
        }
    }

    private func matchingSleepersLocked(minDeadline: Instant?) -> Int {
        guard let m = minDeadline else { return sleepers.count }
        return sleepers.count { $0.deadline >= m }
    }

    private func wakeParkWaitersLocked() {
        let met = parkWaiters.enumerated().filter {
            matchingSleepersLocked(minDeadline: $0.element.minDeadline) >= $0.element.count
        }
        for (i, w) in met.reversed() {
            parkWaiters.remove(at: i)
            w.continuation.resume()
        }
    }
}

extension TestClock {
    /// A `Date` provider on THIS clock's timeline: one `advance` moves both scheduling (`sleep`) and
    /// absolute stamping (lease `leasedAt`, message `createdAt`, stuck age). Keeping them on one
    /// timeline is what lets a test advance 61s and have the lease expire deterministically without a
    /// wall-clock wait. `base` is a fixed epoch so failures print stable instants.
    public func dateProvider(base: Date = Date(timeIntervalSince1970: 1_800_000_000))
        -> @Sendable () -> Date {
        { [self] in base.addingTimeInterval(now.offset.asTimeInterval) }
    }
}

extension Duration {
    /// Whole + fractional seconds as a `TimeInterval` (attoseconds folded in). Named `asTimeInterval`
    /// rather than `seconds` so it cannot be misread as the stdlib's `Duration.seconds(_:)` factory.
    public var asTimeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) * 1e-18
    }
}
