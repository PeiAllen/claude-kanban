import Foundation
import Testing
@testable import OrchestraCore

/// S2-3: spawn lineage failures fire AFTER the worktree is cut. (i) a user-supplied `refs/`-prefixed
/// local base double-prefixes in recordSpawnBase; (ii) a dangling `orchestra-parent` value (deleted
/// parent, name reused) trips a false cycle; both leave an orphan worktree + branch that a retry
/// silently adopts with no base.
@Suite("Spawn base validation + rollback + dangling cycle guard (S2-3)")
struct SpawnBaseValidationTests {

    /// A real repo (real WorktreeManager) on `main` with a `foo` branch. Returns (svc, repo path).
    static func repo() throws -> (svc: OrchestraService, repo: String) {
        let (svc, _, _, base) = TestEnv.makeReal()
        let repo = base + "/repos/app"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func g(_ a: String...) throws { #expect(try Proc.run(["git", "-C", repo] + a).ok) }
        try g("init", "-q", "-b", "main"); try g("config", "user.email", "t@t"); try g("config", "user.name", "t")
        try "0\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try g("add", "-A"); try g("commit", "-q", "-m", "base"); try g("branch", "foo")
        return (svc, repo)
    }

    @Test("S2-3(i): a refs/heads/-prefixed local base is normalized to the bare branch name")
    func normalizesRefsHeadsBase() async throws {
        let (svc, repo) = try Self.repo()
        let card = try await svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child", base: "refs/heads/foo"))
        #expect(card.parentBranch == "foo")
        let link = try #require(await svc.lineage.read(repo: repo, branch: "child"))
        #expect(link.parent == "foo")
    }

    @Test("S2-3(i): a non-branch refs/ base (e.g. a tag ref) is rejected before the worktree is cut")
    func rejectsNonBranchRefsBase() async throws {
        let (svc, repo) = try Self.repo()
        await #expect(throws: OrchestraError.self) {
            _ = try await svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child", base: "refs/tags/v1"))
        }
        // No orphan worktree/branch left behind.
        #expect(try Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/child"]).ok == false)
    }

    @Test("S2-3(ii): a dangling orchestra-parent value (deleted parent, name reused) is not a false cycle")
    func danglingParentValueNoFalseCycle() async throws {
        let (svc, repo) = try Self.repo()
        func g(_ a: String...) throws { #expect(try Proc.run(["git", "-C", repo] + a).ok) }
        // feat-x with a child feat-x-fix that records feat-x as its parent.
        try g("branch", "feat-x", "main")
        try g("branch", "feat-x-fix", "feat-x")
        let fxTip = try Proc.run(["git", "-C", repo, "rev-parse", "feat-x"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await BranchLineage().set(repo: repo, branch: "feat-x-fix",
                                      link: ParentLink(parent: "feat-x", base: fxTip))
        // Delete feat-x — its config section goes, but feat-x-fix.orchestra-parent = feat-x now dangles.
        try g("branch", "-D", "feat-x")

        // Reuse the name: spawn a NEW feat-x on top of feat-x-fix. Must NOT trip a false cycle.
        let card = try await svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "feat-x", base: "feat-x-fix"))
        #expect(card.parentBranch == "feat-x-fix")
    }

    @Test("S2-3(iii): a lineage-record failure rolls back the just-created worktree + branch")
    func rollbackOnLineageFailure() async throws {
        let (svc, repo) = try Self.repo()
        // Force the `git config` write in recordSpawnBase to fail by holding the config lock — the
        // failure fires AFTER `ensure` cut the worktree + branch, exercising the rollback path.
        let lock = repo + "/.git/config.lock"
        FileManager.default.createFile(atPath: lock, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: lock) }

        await #expect(throws: OrchestraError.self) {
            _ = try await svc.spawn(SpawnInput(prompt: "n", repo: repo, branch: "nb", base: "foo"))
        }
        try? FileManager.default.removeItem(atPath: lock)   // release before asserting (rev-parse is a read)
        // Rolled back: the just-created nb branch is gone (no orphan for a retry to silently adopt).
        #expect(try Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/nb"]).ok == false)
    }
}
