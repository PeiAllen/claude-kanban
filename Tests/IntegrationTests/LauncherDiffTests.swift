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

    @Test("openNotes refuses a worktree outside the allowlist before touching Obsidian")
    func openNotesRejectsUnallowedWorktree() throws {
        // An empty allowlist means every path is out of bounds — the security gate must fire on the
        // worktree target before the vault script is ever resolved or run.
        let launcher = Launcher(resolver: PathResolver(allowedRoots: []))
        #expect(throws: OrchestraError.pathNotAllowed("/not/allowed/worktree")) {
            _ = try launcher.openNotes("/not/allowed/worktree")
        }
    }

    /// A repo on `main`, plus a worktree whose branch changes a mix of markdown and non-markdown
    /// files across several dirs: a committed `.md` modify, untracked `.md` adds under `notes/` and
    /// `docs/superpowers/`, a deleted `.md`, and a non-`.md` change.
    private func makeNotesWorktree() throws -> (worktree: String, launcher: Launcher) {
        let root = IntegrationSupport.tempDir("ln")
        let repo = root + "/repo"
        let fm = FileManager.default
        try fm.createDirectory(atPath: repo + "/notes", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: repo + "/docs", withIntermediateDirectories: true)
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "config", "user.email", "t@t.t")
        try git(repo, "config", "user.name", "T")
        try "base\n".write(toFile: repo + "/notes/keep.md", atomically: true, encoding: .utf8)
        try "gone\n".write(toFile: repo + "/docs/gone.md", atomically: true, encoding: .utf8)
        try "code\n".write(toFile: repo + "/main.swift", atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "commit", "-q", "-m", "base")

        let wt = root + "/wt"
        try git(repo, "worktree", "add", "-q", "-b", "feature", wt)
        // Committed change: modify a tracked note.
        try "feature\n".write(toFile: wt + "/notes/keep.md", atomically: true, encoding: .utf8)
        try git(wt, "commit", "-aqm", "edit note")
        // Uncommitted: add notes in two dirs, delete a note, change a non-md file.
        try fm.createDirectory(atPath: wt + "/docs/superpowers", withIntermediateDirectories: true)
        try "new\n".write(toFile: wt + "/notes/added.md", atomically: true, encoding: .utf8)
        try "spec\n".write(toFile: wt + "/docs/superpowers/spec.md", atomically: true, encoding: .utf8)
        try fm.removeItem(atPath: wt + "/docs/gone.md")
        try "changed\n".write(toFile: wt + "/main.swift", atomically: true, encoding: .utf8)

        let config = Config(reposRoot: PathResolver.canonical(root),
                            worktreesRoot: PathResolver.canonical(root))
        return (PathResolver.canonical(wt), Launcher(resolver: PathResolver(config: config)))
    }

    @Test("changedNotes returns only changed .md (across dirs, untracked included), excludes deletes & non-md")
    func changedNotesFiltering() throws {
        let (wt, launcher) = try makeNotesWorktree()
        let got = Set(launcher.changedNotes(worktree: wt))
        let expected: Set<String> = [
            wt + "/notes/keep.md",           // committed modify
            wt + "/notes/added.md",          // untracked add
            wt + "/docs/superpowers/spec.md" // untracked add in a nested dir
        ]
        #expect(got == expected)
        // gone.md was deleted → not openable; main.swift is not markdown → both excluded.
        #expect(!got.contains(wt + "/docs/gone.md"))
        #expect(!got.contains(wt + "/main.swift"))
    }

    @Test("changedNotes is empty for a non-git directory (no base)")
    func changedNotesNonGit() throws {
        let dir = IntegrationSupport.tempDir("ln0")
        let launcher = Launcher(resolver: PathResolver(allowedRoots: [dir]))
        #expect(launcher.changedNotes(worktree: PathResolver.canonical(dir)).isEmpty)
    }
}
