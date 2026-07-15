import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

/// Unit-converted (Task 10, branch-tree). RepoGraph models `main` + `parent` + `child` sharing main's
/// base commit (enough for a real `merge-base`); lineage lives in GitConfigEmulator; StubWorktrees cuts
/// the fake worktree. No real git. `merge-base` fidelity is pinned by GitRevContractTests.
@Suite("set-parent / tree commands")
struct TreeCommandTests {

    typealias Env = TreeStatTests.Env

    /// A FakeProc-backed env with `main` + `parent` + `child` all at main's base commit.
    static func setup() -> (env: Env, fake: FakeProc, graph: RepoGraph, repo: String) {
        let (env, fake, graph, repo) = TreeStatTests.setup()
        graph.branch("child", at: "main")
        return (env, fake, graph, repo)
    }

    private func mergeBase(_ fake: FakeProc, _ repo: String, _ a: String, _ b: String) async throws -> String {
        try await fake.run(["git", "-C", repo, "merge-base", "refs/heads/\(a)", "refs/heads/\(b)"],
                           cwd: nil, env: [:], timeout: nil).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: set-parent

    @Test("set-parent adopt records lineage, base = merge-base, and updates parentBranch")
    func adopt() async throws {
        let (env, fake, _, repo) = Self.setup()
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child"))
        let updated = try await env.svc.setParent(ref: t.shortId, parent: "parent")
        #expect(updated.parentBranch == "parent")
        let link = try #require(await BranchLineage(proc: fake).read(repo: repo, branch: "child"))
        #expect(link.parent == "parent")
        #expect(link.base == (try await mergeBase(fake, repo, "child", "parent")))
    }

    @Test("set-parent with no parent clears the link")
    func clear() async throws {
        let (env, fake, _, repo) = Self.setup()
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child"))
        _ = try await env.svc.setParent(ref: t.shortId, parent: "parent")
        let cleared = try await env.svc.setParent(ref: t.shortId, parent: nil)
        #expect(cleared.parentBranch == nil)
        #expect(await BranchLineage(proc: fake).read(repo: repo, branch: "child") == nil)
    }

    @Test("set-parent mode 'move' repoints the lineage and marks restack-needed (BT5)")
    func moveRepoints() async throws {
        let (env, fake, _, repo) = Self.setup()
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child"))
        let updated = try await env.svc.setParent(ref: t.shortId, parent: "parent", mode: "move")
        #expect(updated.parentBranch == "parent")
        #expect(updated.treeStat?.state == .restackNeeded)
        #expect(await BranchLineage(proc: fake).read(repo: repo, branch: "child")?.parent == "parent")
        // invalid mode is still rejected
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.setParent(ref: t.shortId, parent: "parent", mode: "teleport")
        }
    }

    @Test("set-parent dispatches through the registry")
    func setParentViaRegistry() async throws {
        let (env, _, _, repo) = Self.setup()
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
        let (env, fake, _, repo) = Self.setup()
        let parent = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        _ = try await env.svc.setParent(ref: child.shortId, parent: "parent")

        let snap = try await env.svc.tree(ref: nil, repo: nil)
        let childNode = try #require(snap.nodes.first { $0.branch == "child" })
        #expect(childNode.parent == "parent")
        #expect(childNode.parentCardId == parent.id)
        // S2-4: the recorded rebase anchor is recoverable via `orchestra tree` (not just the ephemeral nudge).
        #expect(childNode.base == (try await mergeBase(fake, repo, "child", "parent")))
        let parentNode = try #require(snap.nodes.first { $0.branch == "parent" })
        #expect(parentNode.children == ["child"])
        #expect(parentNode.parent == nil)
    }

    @Test("tree scoped by ref returns just that card's node")
    func treeScopedByRef() async throws {
        let (env, _, _, repo) = Self.setup()
        _ = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        let snap = try await env.svc.tree(ref: child.shortId, repo: nil)
        #expect(snap.nodes.map(\.branch) == ["child"])
    }

    @Test("tree dispatches through the registry")
    func treeViaRegistry() async throws {
        let (env, _, _, repo) = Self.setup()
        _ = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        let reg = CommandRegistry()
        let cmd = try #require(reg.command("tree"))
        let out = try await cmd.run(env.svc, .object([:]), .mcp)
        #expect(try out.decode(TreeSnapshot.self).nodes.contains { $0.branch == "child" })
    }
}
