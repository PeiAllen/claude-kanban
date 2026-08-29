import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit
import TestSupport

/// The CardRuntime acceptance invariants (design doc A1–A5): teardown is structurally complete —
/// containment survives the real resurrection vectors, the armed-task bag is cancelled wholesale,
/// durable duties run on a crash-redrive with no in-memory entry, and a stale (lease-lost)
/// teardown mutates nothing.
@Suite("CardRuntime — teardown acceptance invariants")
struct CardRuntimeTests {

    // A1 — containment: `runtime[id]` stays nil through the funnel (the one high-frequency path
    // with no archived gate of its own) and further reconcile ticks. The funnel is the vector that
    // matters: tick-side writes are update-if-present, but a late statusline report arrives with
    // full create intent and only the ensure gate stops it.
    @Test("A1: a post-teardown funnel report cannot resurrect the runtime entry")
    func containmentSurvivesLateReport() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "a1"))
        try await TestEnv.archiveAndTeardown(env.svc, card.id)
        #expect(await env.svc.runtime[card.id] == nil)

        // A late statusline/rollout report for the archived card — seq high enough to pass the
        // monotonic gate if the entry existed.
        try? await env.svc.report(card.id, StatusReport(seq: 999, desc: "late"), observedEpoch: nil)
        await env.svc.receiveAgentSignals(
            cardId: card.id,
            signals: [.init(sessionEpoch: card.sessionEpoch, kind: .observationLost)]
        )
        await env.svc.reconcile()   // plus a full tick (visits archived cards forever)

        #expect(await env.svc.runtime[card.id] == nil)   // still detached — no resurrection
    }

    // A2 — cancellation: every task in the bag is cancelled by the detach, whatever slot it holds.
    @Test("A2: detach cancels every armed slot in the bag")
    func detachCancelsWholeBag() async throws {
        let clock = TestClock()
        let env = TestEnv.make(clock: clock)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "a2"))

        // Arm the three debounces (the loops are exercised by their own suites) and park them.
        await env.svc.scheduleDiffStat(card.id)
        await env.svc.scheduleTreeStat(card.id)
        await env.svc.scheduleChildFanout(card.id)
        await clock.parked(3, deadlineAtLeast: .milliseconds(700))
        let armed = try #require(await env.svc.runtime[card.id]?.tasks).values.map(\.task)
        #expect(armed.count == 3)

        await env.svc.detachCardRuntime(card.id)

        #expect(armed.allSatisfy { $0.isCancelled })      // cancelled, not orphaned
        #expect(await env.svc.runtime[card.id] == nil)
    }

    // A4 — durable duties redrive: a crash between archive intent and step 4 restarts the daemon
    // with an EMPTY runtime map; the redrive must still remove the archived watcher's persisted
    // watch-registry key. (The child nudge's at-most-once dedup is pinned by the teardown suite.)
    @Test("A4: watcher-side registry removal runs on a redrive with no runtime entry")
    func durableDutiesRedriveWithEmptyRuntime() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let watcher = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "w", repo: repo, branch: "a4w"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "a4c"))
        await env.svc.registerWatch(watcher.id, [child.id])   // persisted watcher-side key

        // Crash simulation: archive intent lands, then the daemon restarts before step 4 —
        // the remade service has an empty runtime map and redrives teardown from the store.
        try await env.svc.archive(watcher.id)
        let re = TestEnv.remake(base: env.base)
        #expect(await re.svc.runtime[watcher.id] == nil)      // genuinely empty pre-redrive
        try await pollUntil {
            await re.svc.reconcile()
            return await re.svc.list(includeArchived: true)
                .first { $0.id == watcher.id }?.phase.kind == .archivedComplete
        }

        // The persisted key is gone — reload from disk on a THIRD service to prove durability.
        let third = TestEnv.remake(base: env.base)
        await third.svc.reloadWatchRegistry()
        #expect(await third.svc.watchRegistry[watcher.id] == nil)
    }

    // A5/lease — a teardown dispatched under a stale epoch (a reopen won the race) stands down:
    // it detaches nothing and runs no durable duty.
    @Test("lease: a stale-epoch teardown mutates nothing")
    func staleLeaseStandsDown() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "lease"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "leasec"))
        await env.svc.registerWatch(card.id, [child.id])
        try await env.svc.archive(card.id)   // intent only: .archivedPending at the SAME epoch
        let epoch = try #require(await env.svc.store.get(card.id)).sessionEpoch

        // A duties call carrying a stale lease — as if dispatched before a reopen/relaunch bumped
        // the epoch out from under it. Phase matches; the epoch does not.
        await env.svc.teardownActorDuties(card.id, expectedEpoch: epoch - 1)
        #expect(await env.svc.runtime[card.id] != nil)                 // entry untouched
        #expect(await env.svc.watchRegistry[card.id] == [child.id])    // durable state untouched

        // The same call under the CURRENT lease proceeds: detach + durable duties.
        await env.svc.teardownActorDuties(card.id, expectedEpoch: epoch)
        #expect(await env.svc.runtime[card.id] == nil)
        #expect(await env.svc.watchRegistry[card.id] == nil)
    }

    // The child-effect trio (stop the child's nudge loop + schedule its tree stat) runs AFTER the
    // per-child enqueue/wake suspensions — a reopen landing inside that window makes the "parent
    // archived" premise false, and the stale teardown must not stop a live child's nudge loop.
    @Test("lease: a reopen inside the child-nudge window aborts the child side effects")
    func reopenInsideChildNudgeWindowAbortsTrio() async throws {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let graph = RepoScripts.withChild(on: fake)
        let env = TestEnv.make(proc: fake)
        let repo = TestEnv.repo(env.base)
        let parent = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                                link: ParentLink(parent: "parent", base: graph.tip("parent")!))
        _ = try await env.svc.mergeRequest(ref: child.ref())            // arms the child's nudge loop
        #expect(await env.svc.mergeRequestNudgeActive(child.id))

        // Land the reopen exactly between the child enqueue/wake awaits and the side-effect trio.
        let svc = env.svc, pid = parent.id
        await env.svc.setTeardownNudgePauseForTest { _ = try? await svc.reopen(pid) }

        try await env.svc.archive(parent.id)
        await env.svc.reconcile()                                       // dispatches the teardown step
        try await pollUntil {                                           // wait for the step to settle
            await env.svc.list(includeArchived: true)
                .first { $0.id == pid }?.phase.kind == .creatingWorktree
        }

        #expect(await env.svc.mergeRequestNudgeActive(child.id))        // trio aborted — loop untouched
    }

    // The lease end-to-end: `.archivedPending` is RE-ENTERABLE (archive → reopen → archive again),
    // so a phase-only stepper fence would let a stale step — dispatched for the FIRST archive —
    // complete the SECOND archive's teardown (releaseAll + final flip) with none of its duties
    // run. The whole stale step must stand down on the epoch.
    @Test("lease: a stale-snapshot TeardownStepper stands down after reopen→re-archive")
    func staleStepperSnapshotStandsDown() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "restep"))

        try await env.svc.archive(card.id)                        // archive #1 (intent)
        let stale = try #require(await env.svc.store.get(card.id))   // the step's dispatched snapshot
        _ = try await env.svc.reopen(card.id)                     // epoch bump, .creatingWorktree
        try await env.svc.archive(card.id)                        // archive #2: .archivedPending again

        // The stale step (snapshot from archive #1) runs in full — it must do NOTHING: no duty, no
        // releaseAll side effects it owns, and above all no final flip of archive #2.
        try await TeardownStepper().step(stale, env.svc.convergeContext())
        let now = try #require(await env.svc.store.get(card.id))
        #expect(now.phase.kind == .archivedPending)               // archive #2 NOT flipped complete
        #expect(await env.svc.runtime[card.id] != nil)            // archive #2's duties still pending

        // The legitimate redrive (current epoch) completes archive #2 with its duties.
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list(includeArchived: true)
                .first { $0.id == card.id }?.phase.kind == .archivedComplete
        }
        #expect(await env.svc.runtime[card.id] == nil)
    }
}
