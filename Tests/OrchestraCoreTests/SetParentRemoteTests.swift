import Foundation
import Testing
@testable import OrchestraCore

@Suite("set-parent — remote parent + watch opt-in")
struct SetParentRemoteTests {

    @Test("set-parent to pr#7 with watch:true fetches, records prNumber, starts the watch")
    func remoteSetParent() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        // A plain card on its own branch, no parent yet.
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(prompt: "x", repo: repo, branch: "solo"))
        _ = try await svc.setParent(ref: card.shortId, parent: "pr#7", mode: "adopt", watch: true)
        let link = try #require(await svc.lineage.read(repo: repo, branch: "solo"))
        #expect(link.parent == "pr#7")
        #expect(link.prNumber == 7)
        #expect(link.watch == true)
        let updated = try #require(await svc.store.get(card.id))
        #expect(updated.parentBranch == "pr#7")
        #expect(await svc.remoteWatchActive(card.id) == true)
        await svc.stopRemoteWatch(card.id)
    }

    @Test("clearing a remote parent stops the watch")
    func clearStopsWatch() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        #expect(await svc.remoteWatchActive(card.id) == true)
        _ = try await svc.setParent(ref: card.shortId, parent: nil)
        #expect(await svc.remoteWatchActive(card.id) == false)
        #expect(await svc.lineage.read(repo: repo, branch: "childP") == nil)
    }

    // S2-7: adopting a LOCAL parent over a remote one must tear down the lingering remote watch
    // (the loop otherwise self-heals up to an idle interval — 5 min — later).
    @Test("S2-7: adopting a local parent stops a prior remote watch")
    func adoptLocalStopsRemoteWatch() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        #expect(await svc.remoteWatchActive(card.id) == true)
        // The bare origin pushed a real `feature-b`; fetch it into a LOCAL branch to adopt.
        _ = try RemoteParentTests.git(repo, "fetch", "-q", "origin", "feature-b:local-parent")
        _ = try await svc.setParent(ref: card.shortId, parent: "local-parent", mode: "adopt")
        #expect(await svc.remoteWatchActive(card.id) == false)
    }

    // S2-7: clearing the link must also null treeStat (compare shipped, which clears both) — else
    // `tree` reports parent nil with a stale non-nil badge.
    @Test("S2-7: clearing the parent nils the treeStat badge")
    func clearNilsTreeStat() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        await svc.recomputeTreeStat(card.id)                             // give it a non-nil badge
        #expect(await svc.store.get(card.id)?.treeStat != nil)
        _ = try await svc.setParent(ref: card.shortId, parent: nil)
        #expect(await svc.store.get(card.id)?.treeStat == nil)
    }

    @Test("registry threads watch into set-parent")
    func watchViaRegistry() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(prompt: "x", repo: repo, branch: "solo"))
        let reg = CommandRegistry()
        let cmd = try #require(reg.command("set-parent"))
        _ = try await cmd.run(svc, .object([
            "ref": .string(card.shortId), "parent": .string("pr#7"), "watch": .bool(true)]), .mcp)
        let link = try #require(await svc.lineage.read(repo: repo, branch: "solo"))
        #expect(link.watch == true)
        await svc.stopRemoteWatch(card.id)
    }
}
