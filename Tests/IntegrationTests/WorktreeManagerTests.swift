import Foundation
import Testing
@testable import OrchestraCore

@Suite("WorktreeManager — real git", .enabled(if: IntegrationSupport.gitAvailable))
struct WorktreeManagerTests {

    /// Make a throwaway git repo with one commit; return (repoRoot, worktreesRoot, config).
    private func makeRepo() throws -> (repo: String, config: Config) {
        let base = IntegrationSupport.tempDir("wt")
        let repo = base + "/repo"
        let wtRoot = base + "/worktrees"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try Proc.checked(["git", "-C", repo, "init", "-q", "-b", "main"])
        try Proc.checked(["git", "-C", repo, "config", "user.email", "t@t.t"])
        try Proc.checked(["git", "-C", repo, "config", "user.name", "T"])
        try "hi".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "init"])
        let config = Config(reposRoot: PathResolver.canonical(base), worktreesRoot: PathResolver.canonical(wtRoot))
        return (PathResolver.canonical(repo), config)
    }

    @Test("ensure creates a worktree on a NEW branch (-b), path matches, idempotent")
    func ensureNewBranch() throws {
        let (repo, config) = try makeRepo()
        let wm = WorktreeManager(config: config)
        let (wt, created) = try wm.ensure(repo: repo, branch: "feature-x")
        #expect(created)
        #expect(wt == wm.path(repo: repo, branch: "feature-x"))
        #expect(FileManager.default.fileExists(atPath: wt))
        // second ensure is a no-op
        let (wt2, created2) = try wm.ensure(repo: repo, branch: "feature-x")
        #expect(!created2)
        #expect(wt2 == wt)
    }

    @Test("ensure on an EXISTING branch checks it out")
    func ensureExistingBranch() throws {
        let (repo, config) = try makeRepo()
        try Proc.checked(["git", "-C", repo, "branch", "existing"])
        let wm = WorktreeManager(config: config)
        let (wt, created) = try wm.ensure(repo: repo, branch: "existing")
        #expect(created)
        let head = try Proc.checked(["git", "-C", wt, "rev-parse", "--abbrev-ref", "HEAD"])
        #expect(head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "existing")
    }

    @Test("a branch already checked out elsewhere → branchInUse, no duplicate")
    func branchInUse() throws {
        let (repo, config) = try makeRepo()
        let wm = WorktreeManager(config: config)
        _ = try wm.ensure(repo: repo, branch: "shared")
        // A different worktree path for the same branch must fail.
        let cfg2 = Config(reposRoot: config.reposRoot, worktreesRoot: config.worktreesRoot + "-other")
        let wm2 = WorktreeManager(config: Config(reposRoot: config.reposRoot,
                                                 worktreesRoot: cfg2.worktreesRoot,
                                                 allowlist: [config.worktreesRoot, cfg2.worktreesRoot]))
        #expect(throws: OrchestraError.self) { try wm2.ensure(repo: repo, branch: "shared") }
    }

    @Test("remove deletes the worktree dir but keeps the branch")
    func removeKeepsBranch() throws {
        let (repo, config) = try makeRepo()
        let wm = WorktreeManager(config: config)
        let (wt, _) = try wm.ensure(repo: repo, branch: "feature-y")
        try wm.remove(worktree: wt)
        #expect(!FileManager.default.fileExists(atPath: wt))
        // branch still exists
        #expect(wm.branchExists(repo: repo, branch: "feature-y"))
    }

    @Test("a non-allowlisted repo is rejected before anything is created")
    func rejectsDisallowedRepo() throws {
        let (_, config) = try makeRepo()
        let wm = WorktreeManager(config: config)
        #expect(throws: OrchestraError.self) {
            try wm.ensure(repo: "/etc", branch: "x")
        }
    }
}
