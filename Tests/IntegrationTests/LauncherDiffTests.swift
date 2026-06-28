import Foundation
import Testing
@testable import OrchestraCore

/// `Launcher.branchDiffPairs` — the branch-vs-base file pairs that drive Zed's `--diff` view.
@Suite("Launcher — branch-vs-base diff", .enabled(if: IntegrationSupport.gitAvailable))
struct LauncherDiffTests {

    private func git(_ repo: String, _ args: String...) throws {
        try Proc.checked(["git", "-C", repo] + args)
    }

    /// A repo on `main` with one base commit, plus a worktree on a feature branch that has a mix of
    /// committed and uncommitted changes: a modify, an add, and a delete.
    private func makeWorktree() throws -> (worktree: String, base: String, launcher: Launcher) {
        let root = IntegrationSupport.tempDir("ld")
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "config", "user.email", "t@t.t")
        try git(repo, "config", "user.name", "T")
        try "base keep\n".write(toFile: repo + "/keep.txt", atomically: true, encoding: .utf8)
        try "base gone\n".write(toFile: repo + "/gone.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "commit", "-q", "-m", "base")
        let base = try Proc.checked(["git", "-C", repo, "rev-parse", "HEAD"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // Worktree on a feature branch.
        let wt = root + "/wt"
        try git(repo, "worktree", "add", "-q", "-b", "feature", wt)
        // Committed change on the branch: modify keep.txt.
        try "feature keep\n".write(toFile: wt + "/keep.txt", atomically: true, encoding: .utf8)
        try git(wt, "commit", "-aqm", "edit keep")
        // Uncommitted changes: add new.txt, delete gone.txt.
        try "brand new\n".write(toFile: wt + "/new.txt", atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: wt + "/gone.txt")

        let config = Config(reposRoot: PathResolver.canonical(root),
                            worktreesRoot: PathResolver.canonical(root))
        return (PathResolver.canonical(wt), base, Launcher(resolver: PathResolver(config: config)))
    }

    @Test("pairs cover modify/add/delete with correct base content")
    func diffPairs() throws {
        let (wt, _, launcher) = try makeWorktree()
        let pairs = try launcher.branchDiffPairs(worktree: wt)

        // One pair per changed file: keep.txt (M), new.txt (A), gone.txt (D).
        #expect(pairs.count == 3)

        func read(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }

        // Modify: old = base content, new = live worktree file with the committed edit.
        let keep = try #require(pairs.first { $0.1.hasSuffix("/keep.txt") })
        #expect(read(keep.0) == "base keep\n")          // base side
        #expect(read(keep.1) == "feature keep\n")       // worktree side
        #expect(keep.1 == wt + "/keep.txt")

        // Add: old side is the empty placeholder, new side is the new worktree file.
        let new = try #require(pairs.first { $0.1.hasSuffix("/new.txt") })
        #expect(read(new.0) == "")
        #expect(read(new.1) == "brand new\n")

        // Delete: old = base content, new side is the empty placeholder (file is gone).
        let gone = try #require(pairs.first { $0.0.hasSuffix("/gone.txt") })
        #expect(read(gone.0) == "base gone\n")
        #expect(read(gone.1) == "")
    }

    @Test("a worktree with no branch divergence yields no pairs")
    func noChanges() throws {
        let root = IntegrationSupport.tempDir("ld0")
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "config", "user.email", "t@t.t")
        try git(repo, "config", "user.name", "T")
        try "x\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "commit", "-q", "-m", "base")
        let wt = root + "/wt"
        try git(repo, "worktree", "add", "-q", "-b", "clean", wt)   // forked from main, no changes
        let config = Config(reposRoot: PathResolver.canonical(root),
                            worktreesRoot: PathResolver.canonical(root))
        let launcher = Launcher(resolver: PathResolver(config: config))
        #expect(try launcher.branchDiffPairs(worktree: PathResolver.canonical(wt)).isEmpty)
    }
}
