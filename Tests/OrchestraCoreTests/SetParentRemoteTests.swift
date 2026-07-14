import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

/// Unit-converted (Task 10, remote-git). `set-parent` to a remote parent (`pr#7`) is: fetch the private
/// ref (over `FakeProc` — `RemoteRules` lands it), record lineage config (emulator), and flip the watch —
/// all decision + config-write, no real remote effect. The private-ref fetch is pinned to real git by
/// ContractTests/Git/RemoteFetchContractTests; the merge-base of the local-adopt case is modelled in the
/// RepoGraph (pinned by GitRevContractTests). `gh` is a non-available fake so an auto-started watch never
/// shells real `gh`. No real git in this file.
@Suite("set-parent — remote parent + watch opt-in")
struct SetParentRemoteTests {

    /// A service over FakeProc with the config emulator + RepoGraph + RemoteRules (`pr#7` reachable) and a
    /// non-available `gh`. Returns the service, graph (to model local branches), rules, and a fake repo dir.
    static func setup() async -> (svc: OrchestraService, graph: RepoGraph, rules: RemoteRules, repo: String) {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let (graph, rules) = RepoScripts.withRemote(on: fake)
        rules.reachable(remote: "origin", src: "refs/pull/7/head")
        let (svc, _, _, _, _, base) = TestEnv.make(proc: fake)
        await svc.setGh(FakeGh(available: false))
        return (svc, graph, rules, TestEnv.repo(base))
    }

    @Test("set-parent to pr#7 with watch:true fetches, records prNumber, starts the watch")
    func remoteSetParent() async throws {
        let (svc, _, _, repo) = await Self.setup()
        // A plain card on its own branch, no parent yet.
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "solo"))
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
        let (svc, _, _, repo) = await Self.setup()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        #expect(await svc.remoteWatchActive(card.id) == true)
        _ = try await svc.setParent(ref: card.shortId, parent: nil)
        #expect(await svc.remoteWatchActive(card.id) == false)
        #expect(await svc.lineage.read(repo: repo, branch: "childP") == nil)
    }

    // S2-7: adopting a LOCAL parent over a remote one must tear down the lingering remote watch
    // (the loop otherwise self-heals up to an idle interval — 5 min — later).
    @Test("S2-7: adopting a local parent stops a prior remote watch")
    func adoptLocalStopsRemoteWatch() async throws {
        let (svc, graph, _, repo) = await Self.setup()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        #expect(await svc.remoteWatchActive(card.id) == true)
        // Model the child + a local parent branch sharing history, so merge-base(childP, local-parent)
        // resolves (the original fetched a real `feature-b` into a local branch to adopt).
        graph.commit(on: "main")                     // a shared base commit (withRemote's graph starts empty)
        graph.branch("childP", at: "main")
        graph.branch("local-parent", at: "main")
        _ = try await svc.setParent(ref: card.shortId, parent: "local-parent", mode: "adopt")
        #expect(await svc.remoteWatchActive(card.id) == false)
    }

    // S2-7: clearing the link must also null treeStat (compare shipped, which clears both) — else
    // `tree` reports parent nil with a stale non-nil badge.
    @Test("S2-7: clearing the parent nils the treeStat badge")
    func clearNilsTreeStat() async throws {
        let (svc, _, _, repo) = await Self.setup()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        await svc.stopRemoteWatch(card.id)
        await svc.recomputeTreeStat(card.id)                             // give it a non-nil badge
        #expect(await svc.store.get(card.id)?.treeStat != nil)
        _ = try await svc.setParent(ref: card.shortId, parent: nil)
        #expect(await svc.store.get(card.id)?.treeStat == nil)
    }

    @Test("registry threads watch into set-parent")
    func watchViaRegistry() async throws {
        let (svc, _, _, repo) = await Self.setup()
        let card = try await TestEnv.spawnAndAwaitLive(svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "solo"))
        let reg = CommandRegistry()
        let cmd = try #require(reg.command("set-parent"))
        _ = try await cmd.run(svc, .object([
            "ref": .string(card.shortId), "parent": .string("pr#7"), "watch": .bool(true)]), .mcp)
        let link = try #require(await svc.lineage.read(repo: repo, branch: "solo"))
        #expect(link.watch == true)
        await svc.stopRemoteWatch(card.id)
    }
}
