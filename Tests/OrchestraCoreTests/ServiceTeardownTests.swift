import Foundation
import Testing
@testable import OrchestraCore

/// The nudge/watch loops hoisted `guard let self` ABOVE their `while`, so `[weak self]` bought
/// nothing: an armed loop held a STRONG reference and pinned `OrchestraService` (plus its store,
/// lineage and inbox) for the life of the process. Under `swift test --parallel` every test builds its
/// own service, so the zombies piled up — each one still running a periodic loop that forks `git`
/// synchronously on a Swift cooperative-pool thread (~1/core, and the pool never grows). Enough of them
/// and every async task in the process stopped, the test runner included: the suite reached ~975/1180
/// and then sat silent, burning CPU, forever.
///
/// In production `orchestrad` holds ONE service in a top-level `let` for the life of the process, so
/// the leak never multiplied there. This is a test-suite amplifier — and it is what wedged the suite.
@Suite("service teardown — long-lived loops must not pin the service")
struct ServiceTeardownTests {

    /// Holds the weak reference in a box: a mutable local `weak var` captured into an escaping/async
    /// context is a Swift 6 strict-concurrency diagnostic waiting to happen.
    final class WeakBox: @unchecked Sendable { weak var svc: OrchestraService? }

    /// A one-way latch the loop's sleep probe trips. NOT a `DispatchSemaphore` — Swift makes
    /// `wait()` a compile error in an async context ("unavailable from asynchronous contexts"),
    /// which is the very rule this card is about: blocking a cooperative-pool thread. So the test
    /// awaits the latch by suspending, never by parking a thread.
    final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var tripped = false
        func signal() { lock.lock(); tripped = true; lock.unlock() }
        var isTripped: Bool { lock.lock(); defer { lock.unlock() }; return tripped }
    }

    private func awaitLatch(_ latch: Latch, within: Duration = .seconds(60)) async -> Bool {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            if latch.isTripped { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(25))
        }
        return latch.isTripped
    }

    /// Deallocation is not synchronous with the last release — the loop must first hop, observe nil and
    /// unwind — so poll rather than asserting immediately. The bound is generous because a loop
    /// cancelled mid-`Proc.run` keeps a transient strong reference until that fork returns.
    private func awaitDeallocated(_ box: WeakBox, within: Duration = .seconds(30)) async -> Bool {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            if box.svc == nil { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(25))
        }
        return box.svc == nil
    }

    @Test("an armed merge-request nudge does not pin the service")
    func nudgeDoesNotPinService() async throws {
        let box = WeakBox()

        // Scope the ONLY strong reference so it drops at the end of this block. A long interval parks
        // the loop in its sleep holding NOTHING — exactly the state that used to hold `self` strongly.
        do {
            let env = TestEnv.make()
            let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
            _ = try await TestEnv.spawnAndAwaitLive(
                env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
            let child = try await TestEnv.spawnAndAwaitLive(
                env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
            try await BranchLineage().set(repo: repo, branch: "child",
                                          link: ParentLink(parent: "parent", base: parentTip))
            await env.svc.setMergeRequestNudgeInterval(.seconds(3600))   // park the loop in its sleep
            _ = try await env.svc.mergeRequest(ref: child.ref())
            #expect(await env.svc.mergeRequestNudgeActive(child.id))     // the loop IS armed
            box.svc = env.svc
        }

        #expect(await awaitDeallocated(box),
                "an armed merge-request nudge pinned OrchestraService — the loop is not genuinely weak")
    }

    /// The remote-watch loop is `shouldStop → remoteMergeStep → sleep`, so the sleep is LAST: a long
    /// interval does NOT park it on re-arm, it first runs a real `git fetch`/`ls-remote` (bounded at
    /// 20s) while holding a transient strong reference. Dropping the last strong reference during that
    /// window would make this test flake red even once fixed — so wait for the loop to actually reach
    /// its sleep, where it holds nothing.
    @Test("an armed remote watch does not pin the service")
    func remoteWatchDoesNotPinService() async throws {
        let box = WeakBox()
        let parked = Latch()

        do {
            let (svc, _, card) = try await RemoteWatchLoopTests.remoteChild()
            await svc.setRemoteWatchIntervals(active: .seconds(3600), idle: .seconds(3600))
            await svc._setRemoteWatchSleepProbeForTest { parked.signal() }
            await svc.startRemoteWatch(cardId: card.id)
            #expect(await svc.remoteWatchActive(card.id))

            #expect(await awaitLatch(parked), "the remote watch never reached its sleep")
            box.svc = svc
        }

        #expect(await awaitDeallocated(box),
                "an armed remote watch pinned OrchestraService — the loop is not genuinely weak")
    }
}
