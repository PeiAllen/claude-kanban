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
        let card = try await svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "solo"))
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
        let card = try await svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        #expect(await svc.remoteWatchActive(card.id) == true)
        _ = try await svc.setParent(ref: card.shortId, parent: nil)
        #expect(await svc.remoteWatchActive(card.id) == false)
        #expect(await svc.lineage.read(repo: repo, branch: "childP") == nil)
    }

    @Test("registry threads watch into set-parent")
    func watchViaRegistry() async throws {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
        let card = try await svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "solo"))
        let reg = CommandRegistry()
        let cmd = try #require(reg.command("set-parent"))
        _ = try await cmd.run(svc, .object([
            "ref": .string(card.shortId), "parent": .string("pr#7"), "watch": .bool(true)]), .mcp)
        let link = try #require(await svc.lineage.read(repo: repo, branch: "solo"))
        #expect(link.watch == true)
        await svc.stopRemoteWatch(card.id)
    }
}
