import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit
import TestSupport

/// PR-0 of the CardRuntime teardown work: two per-card duties `teardownActorDuties` got wrong,
/// pinned here before the structural refactor lands (so PR-1 is behavior-preserving by
/// construction).
@Suite("teardownActorDuties — per-card duty regressions")
struct TeardownDutiesTests {

    /// A pending diffstat debounce must be CANCELLED by archive teardown, exactly like its
    /// `treeStatDebounce`/`childFanoutDebounce` twins — not left to fire a recompute against an
    /// archived card. Deterministic: the task is parked in `clock.sleep` (TestClock, no wall
    /// clock); cancellation is asserted on the captured handle, never on timing.
    @Test("archive teardown cancels a pending diffstat debounce")
    func teardownCancelsDiffStatDebounce() async throws {
        let clock = TestClock()
        let env = TestEnv.make(clock: clock)
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "dbnc"))

        await env.svc.scheduleDiffStat(card.id)
        await clock.parked(1, deadlineAtLeast: .milliseconds(700))   // debounce sleeper is parked
        let task = try #require(await env.svc.diffStatDebounce[card.id])

        try await TestEnv.archiveAndTeardown(env.svc, card.id)

        #expect(task.isCancelled)                                     // cancelled, not orphaned
        #expect(await env.svc.diffStatDebounce[card.id] == nil)       // and the slot is dropped
    }

    /// The merge-request-nudge generation fence must SURVIVE teardown. It is unique per arming for
    /// the process's lifetime: a ghost tick from a pre-archive arming (cancelled, but already past
    /// its cancellation check and suspended in `reNudgeMergeRequest`) compares its captured gen
    /// against the current one. Nil-ing the gen at teardown made a post-reopen re-arm re-seed from
    /// 1 — matching the ghost, which then sent a duplicate reminder, CAS-counted it, and nilled
    /// the live task's slot. The fence value's monotonicity IS the safety property pinned here.
    @Test("teardown keeps the nudge gen fence; a re-arm never re-seeds to a pre-archive gen")
    func teardownKeepsMergeRequestNudgeGenFence() async throws {
        let env = TestEnv.make(clock: TestClock())
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "genf"))

        await env.svc.startMergeRequestNudge(childId: card.id)
        let armed = await env.svc.mergeRequestNudgeGeneration(card.id)
        #expect(armed >= 1)

        try await TestEnv.archiveAndTeardown(env.svc, card.id)
        // `stopMergeRequestNudge` bumped past `armed`; teardown must NOT nil the entry back to 0.
        #expect(await env.svc.mergeRequestNudgeGeneration(card.id) > armed)

        // A later re-arm (reopen path) seeds beyond every pre-archive gen — a parked ghost holding
        // `armed` can never match again.
        await env.svc.startMergeRequestNudge(childId: card.id)
        #expect(await env.svc.mergeRequestNudgeGeneration(card.id) > armed)
        await env.svc.stopMergeRequestNudge(card.id)
    }

    /// Same fence-survival contract for the remote-watch gen (the twin map, nilled on the
    /// adjacent teardown line).
    @Test("teardown keeps the remote-watch gen fence")
    func teardownKeepsRemoteWatchGenFence() async throws {
        let env = TestEnv.make(clock: TestClock())
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "rwgen"))

        await env.svc.startRemoteWatch(cardId: card.id)
        let armed = await env.svc.remoteWatchGen[card.id] ?? 0
        #expect(armed >= 1)

        try await TestEnv.archiveAndTeardown(env.svc, card.id)
        #expect((await env.svc.remoteWatchGen[card.id] ?? 0) > armed)
    }
}
