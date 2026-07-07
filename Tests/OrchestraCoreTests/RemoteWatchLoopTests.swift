import Foundation
import Testing
@testable import OrchestraCore

@Suite("Remote watch loop — lifecycle, backoff, startup rebuild")
struct RemoteWatchLoopTests {

    static func remoteChild() async throws -> (svc: OrchestraService, repo: String, card: Task) {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let card = try await svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
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
        try await svc.archive(card.id)
        #expect(await svc.remoteWatchActive(card.id) == false)
    }

    @Test("the loop redirects on a MERGED PR (short intervals, no busy-loop)")
    func loopRedirects() async throws {
        let (svc, repo, card) = try await Self.remoteChild()
        await svc.setRemoteWatchIntervals(active: .milliseconds(20), idle: .milliseconds(20))
        await svc.setGh(FakeGh(available: true,
            state: PrState(state: "MERGED", mergedAt: "t", mergeCommit: nil, baseRefName: "main")))
        await svc.startRemoteWatch(cardId: card.id)         // restart with the fake gh + short intervals
        // Poll for the redirect (bounded); the loop should observe MERGED within a few ticks.
        var redirected = false
        for _ in 0..<50 {
            if (await svc.lineage.read(repo: repo, branch: "childP"))?.parent == "origin/main" { redirected = true; break }
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        #expect(redirected)
        await svc.stopRemoteWatch(card.id)
    }
}
