import Foundation
import Testing
@testable import OrchestraCore

/// `Launcher.branchDiffDirs` — the two mirror directories that drive Zed's single multi-diff view.
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

    @Test("two mirror dirs cover modify/add/delete; new side hardlinks to live worktree files")
    func diffDirs() throws {
        let (wt, _, launcher) = try makeWorktree()
        let dirs = try #require(try launcher.branchDiffDirs(worktree: wt))

        func read(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
        let fm = FileManager.default
        func inode(_ p: String) -> UInt? {
            (try? fm.attributesOfItem(atPath: p)[.systemFileNumber]) as? UInt
        }

        // OLD side holds materialized base content for modify/delete, an empty placeholder for adds.
        #expect(read(dirs.old + "/keep.txt") == "base keep\n")
        #expect(read(dirs.old + "/gone.txt") == "base gone\n")
        #expect(read(dirs.old + "/new.txt") == "")

        // NEW side: modify/add are hardlinks to the live worktree file (shared inode → Zed reads real
        // content); a delete is an empty placeholder (the worktree file is gone).
        #expect(read(dirs.new + "/keep.txt") == "feature keep\n")
        #expect(inode(dirs.new + "/keep.txt") == inode(wt + "/keep.txt"))   // hardlink, not a copy

        #expect(read(dirs.new + "/new.txt") == "brand new\n")
        #expect(inode(dirs.new + "/new.txt") == inode(wt + "/new.txt"))

        #expect(read(dirs.new + "/gone.txt") == "")
        #expect(inode(dirs.new + "/gone.txt") != inode(wt + "/keep.txt"))   // placeholder, not linked
    }

    @Test("a worktree with no branch divergence yields no dirs")
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
        #expect(try launcher.branchDiffDirs(worktree: PathResolver.canonical(wt)) == nil)
    }

    @Test("openNotes refuses a repo outside the allowlist before touching Obsidian")
    func openNotesRejectsUnallowedRepo() throws {
        // An empty allowlist means every path is out of bounds — the security gate must fire on the
        // `<repo>/notes` target before the script is ever resolved or run.
        let launcher = Launcher(resolver: PathResolver(allowedRoots: []))
        #expect(throws: OrchestraError.pathNotAllowed("/not/allowed/repo/notes")) {
            try launcher.openNotes("/not/allowed/repo")
        }
    }
}
