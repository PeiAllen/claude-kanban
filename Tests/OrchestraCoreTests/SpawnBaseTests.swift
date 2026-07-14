import Foundation
import Testing
@testable import OrchestraCore

@Suite("Spawn with base — lineage recorded at branch creation (local parents)")
struct SpawnBaseTests {

    /// A real git repo under reposRoot with `main` + a base commit + a `parent` branch. StubWorktrees
    /// still cuts the fake worktree; the base tip + lineage config resolve against this real repo.
    static func repoWithParent(_ base: String) throws -> String {
        let p = TestEnv.repo(base)
        func git(_ a: String...) throws { #expect(try Proc.run(["git", "-C", p] + a).ok) }
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@t")
        try git("config", "user.name", "t")
        try "base\n".write(toFile: p + "/a.txt", atomically: true, encoding: .utf8)
        try git("add", "-A"); try git("commit", "-q", "-m", "base")
        try git("branch", "parent")
        return p
    }

    @Test("spawn(base:) records lineage and sets parentBranch to the base")
    func spawnWithBaseRecordsLineage() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child", base: "parent"))
        #expect(t.parentBranch == "parent")

        let link = try #require(await BranchLineage().read(repo: repo, branch: "child"))
        #expect(link.parent == "parent")
        // Recorded base OID = the parent branch's tip at creation.
        let parentTip = try Proc.run(["git", "-C", repo, "rev-parse", "parent"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(link.base == parentTip)
    }

    @Test("spawn(base:) passes the base into the registry's ensure")
    func spawnThreadsBaseToEnsure() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child", base: "parent"))
        #expect(env.worktrees.ensuredBases["child"] == "parent")
    }

    @Test("spawning onto a PRE-EXISTING branch ignores base and keeps churn derivation")
    func existingBranchIgnoresBase() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        // The branch pre-exists with its OWN durable lineage (parent = other), as after a prior card.
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "other", base: "deadbeef"))
        env.worktrees.markBranchExists("child")
        // Even though we pass base = parent, the existing branch must derive parent from config (= other).
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child", base: "parent"))
        #expect(t.parentBranch == "other")
        let link = try #require(await BranchLineage().read(repo: repo, branch: "child"))
        #expect(link.parent == "other")   // not overwritten by base
    }

    @Test("recorded base OID is the LOCAL branch tip even when a same-named tag exists")
    func recordedBaseIsLocalBranchNotTag() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        func git(_ a: String...) throws { #expect(try Proc.run(["git", "-C", repo] + a).ok) }
        // Advance `parent` one commit, then add a TAG `parent` at main (a different OID). Plain
        // `rev-parse parent` would resolve to the tag; recordSpawnBase must record the branch tip.
        try git("checkout", "-q", "parent")
        try "more\n".write(toFile: repo + "/b.txt", atomically: true, encoding: .utf8)
        try git("add", "-A"); try git("commit", "-q", "-m", "advance parent")
        let branchTip = try Proc.run(["git", "-C", repo, "rev-parse", "refs/heads/parent"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try git("checkout", "-q", "main")
        try git("tag", "parent", "main")

        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child", base: "parent"))
        #expect(t.parentBranch == "parent")
        let link = try #require(await BranchLineage().read(repo: repo, branch: "child"))
        #expect(link.base == branchTip)   // the branch tip, not the tag's OID
    }

    @Test("base is ignored for a scratch spawn (no worktree branch to base)")
    func scratchIgnoresBase() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "", scratch: true, base: "parent"))
        #expect(t.origin == .scratch)
        #expect(t.parentBranch == nil)   // base never consulted off the worktree arm
    }

    @Test("no base → no lineage, parentBranch nil (today's behavior)")
    func noBaseNoLineage() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "solo"))
        #expect(t.parentBranch == nil)
        #expect(await BranchLineage().read(repo: repo, branch: "solo") == nil)
    }

    @Test("spawn threads base through the registry handler")
    func spawnBaseViaRegistry() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let reg = CommandRegistry()
        let cmd = try #require(reg.command("spawn"))
        let out = try await cmd.run(env.svc,
            .object(["id": .string(UUID().uuidString), "prompt": .string("x"), "repo": .string(repo),
                     "branch": .string("child"), "base": .string("parent")]), .mcp)
        // Non-blocking spawn: the command returns a `.creatingWorktree` card; drive the reconciler so
        // materialize records the parent link, then read it back.
        let id = try out.decode(Task.self).id
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list().first { $0.id == id }?.phase.kind == .live
        }
        #expect(await env.svc.list().first { $0.id == id }?.parentBranch == "parent")
    }
}
