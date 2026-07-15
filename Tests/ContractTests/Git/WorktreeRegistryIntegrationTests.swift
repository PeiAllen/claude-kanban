import Foundation
import Testing
@testable import OrchestraCore

@Suite("WorktreeRegistry — real git", .enabled(if: IntegrationSupport.gitAvailable))
struct WorktreeRegistryIntegrationTests {

    /// Make a throwaway git repo with one commit; return (repoRoot, worktreesRoot, config, base).
    private func makeRepo() throws -> (repo: String, config: Config, base: String) {
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
        let config = Config(reposRoot: PathResolver.canonical(base), worktreesRoot: PathResolver.canonical(wtRoot),
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        return (PathResolver.canonical(repo), config, base)
    }

    /// A registry over `config` with base-relative (hermetic) borrows/markers paths — never touches
    /// real `~/.orchestra` state.
    private func registry(_ config: Config, base: String) -> WorktreeRegistry {
        WorktreeRegistry(config: config, borrowsPath: base + "/borrows.json",
                         markersDir: base + "/worktree-markers")
    }

    @Test("ensure creates a worktree on a NEW branch (-b), path matches, idempotent")
    func ensureNewBranch() async throws {
        let (repo, config, base) = try makeRepo()
        let wm = registry(config, base: base)
        let w1 = try await wm.ensure(repo: repo, branch: "feature-x", cardId: UUID())
        #expect(w1.created)
        #expect(!w1.branchExisted)   // a fresh `-b` branch did not pre-exist
        #expect(w1.path == wm.path(repo: repo, branch: "feature-x"))
        #expect(FileManager.default.fileExists(atPath: w1.path))
        // second ensure adopts the materialized (marker-stamped) tree — a no-op; the branch now exists
        let w2 = try await wm.ensure(repo: repo, branch: "feature-x", cardId: UUID())
        #expect(!w2.created)
        #expect(w2.branchExisted)
        #expect(w2.path == w1.path)
    }

    @Test("ensure on an EXISTING branch checks it out")
    func ensureExistingBranch() async throws {
        let (repo, config, base) = try makeRepo()
        try Proc.checked(["git", "-C", repo, "branch", "existing"])
        let wm = registry(config, base: base)
        let w = try await wm.ensure(repo: repo, branch: "existing", cardId: UUID())
        #expect(w.created)
        #expect(w.branchExisted)   // checked out a pre-existing branch
        let head = try Proc.checked(["git", "-C", w.path, "rev-parse", "--abbrev-ref", "HEAD"])
        #expect(head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "existing")
    }

    @Test("a branch already checked out elsewhere → branchInUse, no duplicate")
    func branchInUse() async throws {
        let (repo, config, base) = try makeRepo()
        let wm = registry(config, base: base)
        _ = try await wm.ensure(repo: repo, branch: "shared", cardId: UUID())
        // A different worktree path for the same branch must fail.
        let cfg2 = Config(reposRoot: config.reposRoot, worktreesRoot: config.worktreesRoot + "-other",
                          scratchRoot: base + "/scratch", runtimeStateDir: base + "/state")
        let wm2 = WorktreeRegistry(config: Config(reposRoot: config.reposRoot,
                                                  worktreesRoot: cfg2.worktreesRoot,
                                                  allowlist: [config.worktreesRoot, cfg2.worktreesRoot],
                                                  scratchRoot: base + "/scratch",
                                                  runtimeStateDir: base + "/state"),
                                   borrowsPath: base + "/borrows2.json",
                                   markersDir: base + "/worktree-markers2")
        await #expect(throws: OrchestraError.self) {
            _ = try await wm2.ensure(repo: repo, branch: "shared", cardId: UUID())
        }
    }

    @Test("remove deletes the worktree dir but keeps the branch")
    func removeKeepsBranch() async throws {
        let (repo, config, base) = try makeRepo()
        let wm = registry(config, base: base)
        let id = UUID()
        let w = try await wm.ensure(repo: repo, branch: "feature-y", cardId: id)
        let card = Task(id: id, title: "t", repo: repo, branch: "feature-y", cwd: w.path,
                        origin: .worktree, model: AgentModel(id: "m"), startIn: .impl, column: .impl,
                        order: 0, phase: .live(.running), initialPrompt: "")
        try await wm.release(cardId: id, cards: [card], force: false)
        #expect(!FileManager.default.fileExists(atPath: w.path))
        // branch still exists
        #expect(try Proc.checked(["git", "-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/feature-y"]).ok)
    }

    @Test("a non-allowlisted repo is rejected before anything is created")
    func rejectsDisallowedRepo() async throws {
        let (_, config, base) = try makeRepo()
        let wm = registry(config, base: base)
        await #expect(throws: OrchestraError.self) {
            _ = try await wm.ensure(repo: "/etc", branch: "x", cardId: UUID())
        }
    }

    // MARK: - ensure(base:) — BT2 spawn-with-base

    @Test("ensure with a base starts a NEW branch at the base's tip")
    func ensureNewBranchAtBase() async throws {
        let (repo, config, base) = try makeRepo()
        // A second commit on a `base` branch so its tip differs from main's first commit.
        try Proc.checked(["git", "-C", repo, "branch", "base"])
        try Proc.checked(["git", "-C", repo, "checkout", "-q", "base"])
        try "more".write(toFile: repo + "/B.md", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "on base"])
        try Proc.checked(["git", "-C", repo, "checkout", "-q", "main"])
        let baseTip = try Proc.checked(["git", "-C", repo, "rev-parse", "base"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let wm = registry(config, base: base)
        let w = try await wm.ensure(repo: repo, branch: "child", cardId: UUID(), base: "base")
        #expect(w.created)
        #expect(!w.branchExisted)   // child is a fresh -b branch
        let childTip = try Proc.checked(["git", "-C", w.path, "rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(childTip == baseTip)   // started AT the base tip, not main
    }

    @Test("ensure on an EXISTING branch ignores base")
    func ensureExistingIgnoresBase() async throws {
        let (repo, config, base) = try makeRepo()
        // `existing` sits at main's tip; `base` has an extra commit ahead of it.
        try Proc.checked(["git", "-C", repo, "branch", "existing"])
        let existingTip = try Proc.checked(["git", "-C", repo, "rev-parse", "existing"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Proc.checked(["git", "-C", repo, "branch", "base"])
        try Proc.checked(["git", "-C", repo, "checkout", "-q", "base"])
        try "x".write(toFile: repo + "/C.md", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "ahead"])
        try Proc.checked(["git", "-C", repo, "checkout", "-q", "main"])

        let wm = registry(config, base: base)
        let w = try await wm.ensure(repo: repo, branch: "existing", cardId: UUID(), base: "base")
        #expect(w.branchExisted)
        let head = try Proc.checked(["git", "-C", w.path, "rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == existingTip)   // still at existing's own tip — base was ignored
    }

    @Test("ensure resolves base as a LOCAL branch even when a same-named tag exists")
    func ensureBasePrefersLocalBranchOverTag() async throws {
        let (repo, config, base) = try makeRepo()
        // A branch `dup` (with its own commit) and a TAG `dup` pointing at main's first commit.
        // Plain `git rev-parse dup` would disambiguate to the tag; the local-parents contract must
        // start the child at the BRANCH.
        try Proc.checked(["git", "-C", repo, "branch", "dup"])
        try Proc.checked(["git", "-C", repo, "checkout", "-q", "dup"])
        try "z".write(toFile: repo + "/D.md", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "on dup"])
        let branchTip = try Proc.checked(["git", "-C", repo, "rev-parse", "refs/heads/dup"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Proc.checked(["git", "-C", repo, "checkout", "-q", "main"])
        try Proc.checked(["git", "-C", repo, "tag", "dup", "main"])   // tag `dup` at main's tip

        let wm = registry(config, base: base)
        let w = try await wm.ensure(repo: repo, branch: "child", cardId: UUID(), base: "dup")
        let childTip = try Proc.checked(["git", "-C", w.path, "rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(childTip == branchTip)   // started at the BRANCH `dup`, not the tag
    }

    @Test("ensure with an unknown base throws and leaves no worktree dir")
    func ensureUnknownBaseThrows() async throws {
        let (repo, config, base) = try makeRepo()
        let wm = registry(config, base: base)
        let wt = wm.path(repo: repo, branch: "child")
        await #expect(throws: OrchestraError.self) {
            _ = try await wm.ensure(repo: repo, branch: "child", cardId: UUID(), base: "nope")
        }
        #expect(!FileManager.default.fileExists(atPath: wt))   // no half-created worktree
    }
}
