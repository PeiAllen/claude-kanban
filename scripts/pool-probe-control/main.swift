// POSITIVE CONTROL for pool-probe.sh.
//
// Deliberately reproduces the bug the card is about: an `actor` whose method blocks a
// cooperative-pool thread on a DispatchSemaphore — exactly the shape of `Proc.run`'s `exited.wait()`
// inside `BranchLineage` / `RemoteParents` / `WorktreeRegistry`.
//
// If pool-probe's classifier is sound, sampling THIS process must report parked > 0 (and in fact
// parked ≈ pool width). If it reports 0 here too, the classifier is blind and the real run's
// "parked=0" is meaningless.
import Foundation

actor Forker {
    let id: Int
    init(id: Int) { self.id = id }

    // The exact hazard: a synchronous, semaphore-backed block inside actor isolation.
    func blockLikeProcRun() {
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { sem.signal() }
        sem.wait()                                  // parks THIS cooperative-pool thread
    }
}

let n = ProcessInfo.processInfo.activeProcessorCount * 2
let forkers = (0..<n).map { Forker(id: $0) }

for f in forkers {
    Task { await f.blockLikeProcRun() }
}

// Keep the main thread alive on a NON-cooperative wait so it can't be confused for the pool.
Thread.sleep(forTimeInterval: 40)
