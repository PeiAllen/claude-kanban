import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// Unit-converted (Task 10, remote-git). The watch loop's lifecycle (start/stop/rebuild/archive), its
/// restart generation-fence, and its redirect DECISION are all logic over actor state + the `gh` fake —
/// no real remote effect. The remote tip is scripted (`RemoteRules` on `FakeProc`, `pr#7` reachable),
/// pinned to real git by ContractTests/Git/RemoteFetchContractTests; the merge decision is driven by
/// `FakeGh` (already a fake). No real git in this file.
@Suite("Remote watch loop — lifecycle, backoff, startup rebuild")
struct RemoteWatchLoopTests {

    /// A spawned remote-parent (`pr#7`) card over FakeProc, watch auto-started. Shared with the
    /// card-lifecycle leak test (ServiceTeardownTests) — keep the `(svc, repo, card)` shape. `origin/main`
    /// is pre-registered reachable so the MERGED-redirect path's target private ref resolves.
    static func remoteChild() async throws -> (svc: OrchestraService, repo: String, card: Task) {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let (_, rules) = RepoScripts.withRemote(on: fake)
        rules.reachable(remote: "origin", src: "refs/pull/7/head")
        rules.reachable(remote: "origin", src: "refs/heads/main")   // the redirect target's private ref
        let (svc, _, _, _, _, base) = TestEnv.make(proc: fake)
        await svc.setGh(FakeGh(available: false))            // no real gh from the auto-started loop
        let repo = TestEnv.repo(base)
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        return (svc, repo, card)
    }

    @Test("a remote-base spawn starts a watch")
    func spawnStartsWatch() async throws {
        let (svc, _, card) = try await Self.remoteChild()
        #expect(await svc.remoteWatchActive(card.id) == true)
        await svc.stopRemoteWatch(card.id)
    }

    @Test("startup rebuild restarts a watch for a live remote-parent card with watch=true")
    func rebuildFromLineage() async throws {
        let (svc, _, card) = try await Self.remoteChild()
        await svc.stopRemoteWatch(card.id)                  // simulate a fresh daemon (no watches yet)
        #expect(await svc.remoteWatchActive(card.id) == false)
        await svc.rebuildRemoteWatches()
        #expect(await svc.remoteWatchActive(card.id) == true)
        await svc.stopRemoteWatch(card.id)
    }

    @Test("archive stops the watch")
    func archiveStops() async throws {
        let (svc, _, card) = try await Self.remoteChild()
        #expect(await svc.remoteWatchActive(card.id) == true)
        // Intent-only archive: the remote-watch teardown is a TeardownStepper actor-duty (PR4b Task 4).
        try await TestEnv.archiveAndTeardown(svc, card.id)
        #expect(await svc.remoteWatchActive(card.id) == false)
    }

    @Test("a restart then stop leaves the watch inactive (no orphaned loop)")
    func restartThenStopIsInactive() async throws {
        let (svc, _, card) = try await Self.remoteChild()
        await svc.setRemoteWatchIntervals(active: .milliseconds(10), idle: .milliseconds(10))
        // Restart several times; the prior loop's terminal cleanup must not clear a newer generation.
        for _ in 0..<5 {
            await svc.startRemoteWatch(cardId: card.id)
            #expect(await svc.remoteWatchActive(card.id) == true)
        }
        // Let cancelled loops run their terminal cleanup, which must no-op against the current generation.
        await yieldBriefly()   // negative: cancelled loops' cleanups get their chance to (wrongly) clear us
        #expect(await svc.remoteWatchActive(card.id) == true)   // still active after all the cleanups
        await svc.stopRemoteWatch(card.id)
        try await pollUntil("stop deactivates the watch") { await svc.remoteWatchActive(card.id) == false }
        await yieldBriefly()   // and no orphan loop revives it
        #expect(await svc.remoteWatchActive(card.id) == false)  // stop wins; no orphan revives it
    }

    @Test("the loop redirects on a MERGED PR (short intervals, no busy-loop)")
    func loopRedirects() async throws {
        let (svc, repo, card) = try await Self.remoteChild()
        await svc.setRemoteWatchIntervals(active: .milliseconds(20), idle: .milliseconds(20))
        await svc.setGh(FakeGh(available: true,
            state: PrState(state: "MERGED", mergedAt: "t", mergeCommit: nil, baseRefName: "main")))
        await svc.startRemoteWatch(cardId: card.id)         // restart with the fake gh + short intervals
        // Poll for the redirect (bounded); the loop should observe MERGED within a few ticks.
        try await pollUntil("the loop observed MERGED and redirected the lineage") {
            (await svc.lineage.read(repo: repo, branch: "childP"))?.parent == "origin/main"
        }
        await svc.stopRemoteWatch(card.id)
    }
}
