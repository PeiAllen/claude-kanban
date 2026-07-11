import Foundation
import Testing
@testable import OrchestraCore

@Suite("set-parent / tree commands")
struct TreeCommandTests {

    /// A real git repo under reposRoot with `main`, and two branches (`parent`, `child`) that share
    /// `main`'s base commit — enough for a real `merge-base`. StubWorktrees still cuts the fake
    /// worktree; the merge-base + config all resolve against this repo.
    static func repoWithBranches(_ base: String) throws -> String {
        let p = TestEnv.repo(base)
        func git(_ a: String...) throws { #expect(try Proc.run(["git", "-C", p] + a).ok) }
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@t")
        try git("config", "user.name", "t")
        try "base\n".write(toFile: p + "/a.txt", atomically: true, encoding: .utf8)
        try git("add", "-A"); try git("commit", "-q", "-m", "base")
        try git("branch", "parent")
        try git("branch", "child")
        return p
    }

    // MARK: set-parent

    @Test("set-parent adopt records lineage, base = merge-base, and updates parentBranch")
    func adopt() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child"))
        let updated = try await env.svc.setParent(ref: t.shortId, parent: "parent")
        #expect(updated.parentBranch == "parent")
        let link = try #require(await BranchLineage().read(repo: repo, branch: "child"))
        #expect(link.parent == "parent")
        let mb = try Proc.run(["git", "-C", repo, "merge-base", "child", "parent"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(link.base == mb)
    }

    @Test("set-parent with no parent clears the link")
    func clear() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child"))
        _ = try await env.svc.setParent(ref: t.shortId, parent: "parent")
        let cleared = try await env.svc.setParent(ref: t.shortId, parent: nil)
        #expect(cleared.parentBranch == nil)
        #expect(await BranchLineage().read(repo: repo, branch: "child") == nil)
    }

    @Test("set-parent mode 'move' repoints the lineage and marks restack-needed (BT5)")
    func moveRepoints() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child"))
        let updated = try await env.svc.setParent(ref: t.shortId, parent: "parent", mode: "move")
        #expect(updated.parentBranch == "parent")
        #expect(updated.treeStat?.state == .restackNeeded)
        #expect(await BranchLineage().read(repo: repo, branch: "child")?.parent == "parent")
        // invalid mode is still rejected
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.setParent(ref: t.shortId, parent: "parent", mode: "teleport")
        }
    }

    @Test("set-parent dispatches through the registry")
    func setParentViaRegistry() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child"))
        let reg = CommandRegistry()
        let cmd = try #require(reg.command("set-parent"))
        let out = try await cmd.run(env.svc,
            .object(["ref": .string(t.shortId), "parent": .string("parent")]), .mcp)
        #expect(try out.decode(Task.self).parentBranch == "parent")
    }

    // MARK: tree

    @Test("tree reports parent + derived parentCardId + children")
    func treeSnapshot() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        let parent = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        _ = try await env.svc.setParent(ref: child.shortId, parent: "parent")

        let snap = try await env.svc.tree(ref: nil, repo: nil)
        let childNode = try #require(snap.nodes.first { $0.branch == "child" })
        #expect(childNode.parent == "parent")
        #expect(childNode.parentCardId == parent.id)
        // S2-4: the recorded rebase anchor is recoverable via `orchestra tree` (not just the ephemeral nudge).
        let mb = try Proc.run(["git", "-C", repo, "merge-base", "child", "parent"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(childNode.base == mb)
        let parentNode = try #require(snap.nodes.first { $0.branch == "parent" })
        #expect(parentNode.children == ["child"])
        #expect(parentNode.parent == nil)
    }

    @Test("tree scoped by ref returns just that card's node")
    func treeScopedByRef() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        let snap = try await env.svc.tree(ref: child.shortId, repo: nil)
        #expect(snap.nodes.map(\.branch) == ["child"])
    }

    @Test("tree dispatches through the registry")
    func treeViaRegistry() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithBranches(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        let reg = CommandRegistry()
        let cmd = try #require(reg.command("tree"))
        let out = try await cmd.run(env.svc, .object([:]), .mcp)
        #expect(try out.decode(TreeSnapshot.self).nodes.contains { $0.branch == "child" })
    }
}
