import Foundation
import OrchestraCore

/// A rendezvous for deterministic race tests: the code under test SUSPENDS inside a faked call
/// until the test releases it. Replaces every usleep-to-widen-the-race-window.
///
///     let gate = proc.gate(on: ["git", "fetch"])
///     async let op = service.someOperation(card)
///     await gate.reached()          // provably parked inside the fake
///     await service.reconcile()     // fire the racing op, deterministically
///     gate.release(.init(stdout: "", stderr: "", exitCode: 0))
///
/// Suspension (not semaphore-blocking) is load-bearing: gated calls happen inside actor-isolated
/// methods (BranchLineage/RemoteParents), where parking the thread would deadlock the actor's
/// cooperative-pool executor. `release` before the call arrives is fine — the call returns
/// immediately with the released result (no ordering trap).
public final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var hits = 0
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var released: ProcResult? = nil
    private var parkedWaiters: [CheckedContinuation<ProcResult, Never>] = []

    public init() {}

    /// Test-side: suspend until the gated call has parked (at least once).
    public func reached() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if hits > 0 { return true }
                reachedWaiters.append(c)
                return false
            }
            if done { c.resume() }
        }
    }

    /// Test-side: let the parked call return `result`. Also satisfies a call that arrives later.
    public func release(_ result: ProcResult = ProcResult(stdout: "", stderr: "", exitCode: 0)) {
        let waiters: [CheckedContinuation<ProcResult, Never>] = lock.withLock {
            released = result
            defer { parkedWaiters.removeAll() }
            return parkedWaiters
        }
        for w in waiters { w.resume(returning: result) }
    }

    /// Fake-side: record the hit, wake `reached()` waiters, suspend until released.
    public func park() async -> ProcResult {
        let reached: [CheckedContinuation<Void, Never>] = lock.withLock {
            hits += 1
            defer { reachedWaiters.removeAll() }
            return reachedWaiters
        }
        for r in reached { r.resume() }
        return await withCheckedContinuation { (c: CheckedContinuation<ProcResult, Never>) in
            let early: ProcResult? = lock.withLock {
                if let r = released { return r }
                parkedWaiters.append(c)
                return nil
            }
            if let early { c.resume(returning: early) }
        }
    }
}
