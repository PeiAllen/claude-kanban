import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

// Contract mover (extracted from the unit SpawnBaseTests at the Task-9/11 flip, card-lifecycle):
// `recordedBaseIsLocalBranchNotTag` needs a real branch/tag NAME COLLISION, which `RepoGraph` cannot model
// (its ref table is keyed by bare name, so `refs/heads/parent` and a tag `parent` can't coexist). It runs
// real git; the analogous real-worktree base resolution is pinned by
// WorktreeAddContractTests.addBasePrefersLocalBranchOverTag.
@Suite("Contract: recorded base is the LOCAL branch tip when a same-named tag exists")
struct SpawnBaseContractTests {

    /// A real git repo under reposRoot with `main` + a base commit + a `parent` branch.
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

    @Test("recorded base OID is the LOCAL branch tip even when a same-named tag exists")
    func recordedBaseIsLocalBranchNotTag() async throws {
        let env = TestEnv.make(proc: RealProc())   // mover: real repo — the base probe must run real git
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
        let link = try #require(await BranchLineage(proc: RealProc()).read(repo: repo, branch: "child"))
        #expect(link.base == branchTip)   // the branch tip, not the tag's OID
    }
}
