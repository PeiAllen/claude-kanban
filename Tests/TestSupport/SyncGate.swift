import Foundation

/// A rendezvous for race tests at SYNC stub seams (WorktreeManaging/SessionManaging methods are
/// sync `throws`, and WorktreeRegistry.ensure has a documented no-await critical section — a
/// suspension Gate cannot live there). The stub side BLOCKS its thread on a bounded semaphore —
/// the identical thread semantics of the usleep it replaces at the same call site, made
/// deterministic; the test side stays suspension-based. The safety timeout makes a mis-armed
/// test fail loudly instead of hanging the suite. Async seams (ProcRunning) keep using `Gate`.
public final class SyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private let sem = DispatchSemaphore(value: 0)
    private var hits = 0
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Test-side: suspend until the gated call has parked (at least once).
    public func reached() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if hits > 0 { return true }
                reachedWaiters.append(c); return false
            }
            if done { c.resume() }
        }
    }

    /// Test-side: unpark the stub.
    public func release() { sem.signal() }

    /// Stub-side: record the hit, wake reached() waiters, BLOCK until release. The safety timeout
    /// is a mis-arm tripwire, not a graceful path: if `release()` never arrives the gate FATALS
    /// rather than silently continuing (a swallowed timeout let a mis-armed test pass on a stub
    /// that was never unparked).
    public func parkBlocking(timeout: DispatchTimeInterval = .seconds(30)) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            hits += 1
            defer { reachedWaiters.removeAll() }
            return reachedWaiters
        }
        for w in waiters { w.resume() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            fatalError("SyncGate.parkBlocking: release() never arrived within \(timeout) — mis-armed test (gate set but never released)")
        }
    }
}
