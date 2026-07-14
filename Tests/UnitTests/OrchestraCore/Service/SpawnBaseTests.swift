import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// Unit-converted (Task 10, card-lifecycle): spawn-with-base LINEAGE-RECORDING logic runs over FakeProc —
/// `RepoGraph` (main + a `parent` branch, pinned to real git by ContractTests/Git/GitRevContractTests)
/// answers the `rev-parse` the `recordSpawnBase` seam runs, and the lineage lives in `GitConfigEmulator`
/// (pinned by GitConfigContractTests). No real git.
///
/// The one exception — a real branch/tag NAME COLLISION, which `RepoGraph` cannot model (its ref table is
/// keyed by bare name) — was extracted at the flip to ContractTests/Git/SpawnBaseContractTests; the
/// analogous real-worktree base resolution is pinned by
/// WorktreeAddContractTests.addBasePrefersLocalBranchOverTag.
@Suite("Spawn with base — lineage recorded at branch creation (local parents)")
struct SpawnBaseTests {

    /// A service whose git seam is a FakeProc carrying the config emulator + a RepoGraph seeded with one
    /// base commit on `main` and a `parent` branch at that tip. Returns everything a converted case needs.
    static func setup() -> (env: TreeStatTests.Env, fake: FakeProc, graph: RepoGraph, repo: String) {
        let fake = FakeProc()
        GitConfigEmulator().install(on: fake)
        let graph = RepoScripts.withParent(on: fake)
        let env = TestEnv.make(proc: fake)
        let repo = TestEnv.repo(env.base)   // a bare dir — the fake answers every git verb
        return (env, fake, graph, repo)
    }

    @Test("spawn(base:) records lineage and sets parentBranch to the base")
    func spawnWithBaseRecordsLineage() async throws {
        let (env, fake, graph, repo) = Self.setup()
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child", base: "parent"))
        #expect(t.parentBranch == "parent")

        let link = try #require(await BranchLineage(proc: fake).read(repo: repo, branch: "child"))
        #expect(link.parent == "parent")
        // Recorded base OID = the parent branch's tip at creation (the stub cut no `child` ref, so
        // recordSpawnBase falls back to `refs/heads/parent`, which the RepoGraph resolves to that tip).
        #expect(link.base == graph.tip("parent")!)
    }

    @Test("spawn(base:) passes the base into the registry's ensure")
    func spawnThreadsBaseToEnsure() async throws {
        let (env, _, _, repo) = Self.setup()
        _ = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child", base: "parent"))
        #expect(env.worktrees.ensuredBases["child"] == "parent")
    }

    @Test("spawning onto a PRE-EXISTING branch ignores base and keeps churn derivation")
    func existingBranchIgnoresBase() async throws {
        let (env, fake, _, repo) = Self.setup()
        // The branch pre-exists with its OWN durable lineage (parent = other), as after a prior card.
        try await BranchLineage(proc: fake).set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "other", base: "deadbeef"))
        env.worktrees.markBranchExists("child")
        // Even though we pass base = parent, the existing branch must derive parent from config (= other).
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "child", base: "parent"))
        #expect(t.parentBranch == "other")
        let link = try #require(await BranchLineage(proc: fake).read(repo: repo, branch: "child"))
        #expect(link.parent == "other")   // not overwritten by base
    }

    @Test("base is ignored for a scratch spawn (no worktree branch to base)")
    func scratchIgnoresBase() async throws {
        let (env, _, _, repo) = Self.setup()
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "", scratch: true, base: "parent"))
        #expect(t.origin == .scratch)
        #expect(t.parentBranch == nil)   // base never consulted off the worktree arm
    }

    @Test("no base → no lineage, parentBranch nil (today's behavior)")
    func noBaseNoLineage() async throws {
        let (env, fake, _, repo) = Self.setup()
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "solo"))
        #expect(t.parentBranch == nil)
        #expect(await BranchLineage(proc: fake).read(repo: repo, branch: "solo") == nil)
    }

    @Test("spawn threads base through the registry handler")
    func spawnBaseViaRegistry() async throws {
        let (env, _, _, repo) = Self.setup()
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
