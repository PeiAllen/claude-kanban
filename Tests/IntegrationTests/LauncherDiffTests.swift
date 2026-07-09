import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit

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
        let dirs = try #require(try launcher.branchDiffDirs(worktree: wt, parentRef: nil))

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
        #expect(try launcher.branchDiffDirs(worktree: PathResolver.canonical(wt), parentRef: nil) == nil)
    }

    @Test("openNotes refuses a worktree outside the allowlist before touching Obsidian")
    func openNotesRejectsUnallowedWorktree() throws {
        // An empty allowlist means every path is out of bounds — the security gate must fire on the
        // worktree target before the vault script is ever resolved or run.
        let launcher = Launcher(resolver: PathResolver(allowedRoots: []))
        #expect(throws: OrchestraError.pathNotAllowed("/not/allowed/worktree")) {
            _ = try launcher.openNotes("/not/allowed/worktree", parentRef: nil)
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
        // Vault-relative paths — the form workspace.json leaf `file` entries use.
        let got = Set(launcher.changedNotes(worktree: wt, parentRef: nil))
        let expected: Set<String> = [
            "notes/keep.md",            // committed modify
            "notes/added.md",           // untracked add
            "docs/superpowers/spec.md", // untracked add in a nested dir
        ]
        #expect(got == expected)
        // gone.md was deleted → not openable; main.swift is not markdown → both excluded.
        #expect(!got.contains("docs/gone.md"))
        #expect(!got.contains("main.swift"))
    }

    @Test("changedNotes is empty for a non-git directory (no base)")
    func changedNotesNonGit() throws {
        let dir = IntegrationSupport.tempDir("ln0")
        let launcher = Launcher(resolver: PathResolver(allowedRoots: [dir]))
        #expect(launcher.changedNotes(worktree: PathResolver.canonical(dir), parentRef: nil).isEmpty)
    }

    @Test("changedNoteFiles returns each changed .md with correct M/A status + live content")
    func changedNoteFilesContent() throws {
        let (wt, launcher) = try makeNotesWorktree()
        // Keyed by path so the assertion doesn't depend on git's enumeration order.
        let byPath = Dictionary(uniqueKeysWithValues:
            launcher.changedNoteFiles(worktree: wt, parentRef: nil).map { ($0.path, $0) })

        #expect(Set(byPath.keys) == ["notes/keep.md", "notes/added.md", "docs/superpowers/spec.md"])

        // committed modify → M, content is the branch (live) version.
        #expect(byPath["notes/keep.md"]?.status == .modified)
        #expect(byPath["notes/keep.md"]?.content == "feature\n")
        // untracked adds → A, with their live content.
        #expect(byPath["notes/added.md"]?.status == .added)
        #expect(byPath["notes/added.md"]?.content == "new\n")
        #expect(byPath["docs/superpowers/spec.md"]?.status == .added)
        #expect(byPath["docs/superpowers/spec.md"]?.content == "spec\n")

        // gone.md was deleted (nothing to show); main.swift is not markdown — both excluded.
        #expect(byPath["docs/gone.md"] == nil)
        #expect(byPath["main.swift"] == nil)
    }

    @Test("changedNoteFiles is empty for a non-git directory (no base)")
    func changedNoteFilesNonGit() throws {
        let dir = IntegrationSupport.tempDir("lnf0")
        let launcher = Launcher(resolver: PathResolver(allowedRoots: [dir]))
        #expect(launcher.changedNoteFiles(worktree: PathResolver.canonical(dir), parentRef: nil).isEmpty)
    }

    /// A repo whose worktree is a CHILD branch stacked on a `parent` branch: main(base) →
    /// parent(+notes/parent.md) → child=worktree(+notes/child.md). With a parent ref the diff/notes
    /// baseline against the parent (child's own work only); with nil they baseline against main (both).
    private func makeStackedWorktree() throws -> (worktree: String, launcher: Launcher) {
        let root = IntegrationSupport.tempDir("lst")
        let repo = root + "/repo"
        let fm = FileManager.default
        try fm.createDirectory(atPath: repo + "/notes", withIntermediateDirectories: true)
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "config", "user.email", "t@t.t")
        try git(repo, "config", "user.name", "T")
        try "base\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "commit", "-q", "-m", "base")
        // Parent branch with its OWN note.
        try git(repo, "checkout", "-q", "-b", "parent")
        try "# parent\n".write(toFile: repo + "/notes/parent.md", atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "commit", "-q", "-m", "parent note")
        try git(repo, "checkout", "-q", "main")   // leave `parent` as a bare local branch for the worktree
        // Child worktree forked from parent, with its OWN note.
        let wt = root + "/wt"
        try git(repo, "worktree", "add", "-q", "-b", "child", wt, "parent")
        try "# child\n".write(toFile: wt + "/notes/child.md", atomically: true, encoding: .utf8)
        try git(wt, "add", ".")
        try git(wt, "commit", "-q", "-m", "child note")

        let config = Config(reposRoot: PathResolver.canonical(root),
                            worktreesRoot: PathResolver.canonical(root))
        return (PathResolver.canonical(wt), Launcher(resolver: PathResolver(config: config)))
    }

    @Test("a parentRef baselines changedNotes + branchDiffDirs against the parent (child's own work only)")
    func parentBaselineExcludesParentWork() throws {
        let (wt, launcher) = try makeStackedWorktree()

        // Parent baseline: only the child's own note.
        #expect(Set(launcher.changedNotes(worktree: wt, parentRef: "parent")) == ["notes/child.md"])
        // Default (nil) baseline vs main: the parent's note is included too.
        #expect(Set(launcher.changedNotes(worktree: wt, parentRef: nil))
                == ["notes/parent.md", "notes/child.md"])

        // Zed "View changes": the parent-baselined multi-diff carries only the child's file.
        let dirs = try #require(try launcher.branchDiffDirs(worktree: wt, parentRef: "parent"))
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dirs.new + "/notes/child.md"))
        #expect(!fm.fileExists(atPath: dirs.new + "/notes/parent.md"))   // parent's work excluded
    }

    @Test("seedWorkspaceTabs writes a valid Obsidian layout: one leaf tab per note, in order")
    func seedWorkspaceTabsFormat() throws {
        let dir = IntegrationSupport.tempDir("lws")
        let launcher = Launcher(resolver: PathResolver(allowedRoots: [dir]))
        let rels = ["notes/a.md", "docs/superpowers/b.md", "c.md"]
        launcher.seedWorkspaceTabs(worktree: dir, relPaths: rels)

        let ws = dir + "/.obsidian/workspace.json"
        let data = try #require(FileManager.default.contents(atPath: ws))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // main → split → [tabs] → leaves, each a markdown leaf whose state.file is the note (in order).
        let main = try #require(obj["main"] as? [String: Any])
        let split = try #require(main["children"] as? [[String: Any]])
        let tabs = try #require(split.first)
        #expect(tabs["type"] as? String == "tabs")
        let leaves = try #require(tabs["children"] as? [[String: Any]])
        let files = leaves.map { (($0["state"] as? [String: Any])?["state"] as? [String: Any])?["file"] as? String }
        #expect(files == rels)                                   // one tab per note, order preserved
        #expect(leaves.allSatisfy { ($0["state"] as? [String: Any])?["type"] as? String == "markdown" })
        let modes = leaves.map { (($0["state"] as? [String: Any])?["state"] as? [String: Any])?["mode"] as? String }
        #expect(modes == Array(repeating: "preview", count: rels.count))
        #expect(obj["lastOpenFiles"] as? [String] == rels)
        #expect((obj["active"] as? String)?.isEmpty == false)    // an active leaf is set
    }
}
