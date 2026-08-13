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
                            worktreesRoot: PathResolver.canonical(root),
                            scratchRoot: PathResolver.canonical(root) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(root) + "/state")
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
                            worktreesRoot: PathResolver.canonical(root),
                            scratchRoot: PathResolver.canonical(root) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(root) + "/state")
        let launcher = Launcher(resolver: PathResolver(config: config))
        #expect(try launcher.branchDiffDirs(worktree: PathResolver.canonical(wt), parentRef: nil) == nil)
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
                            worktreesRoot: PathResolver.canonical(root),
                            scratchRoot: PathResolver.canonical(root) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(root) + "/state")
        return (PathResolver.canonical(wt), Launcher(resolver: PathResolver(config: config)))
    }

    @Test("changedMarkdown returns only changed .md (across dirs, untracked included), excludes deletes & non-md")
    func changedMarkdownFiltering() throws {
        let (wt, launcher) = try makeNotesWorktree()
        // Vault-relative paths — the form workspace.json leaf `file` entries use.
        let got = Set(launcher.changedMarkdown(worktree: wt, parentRef: nil).map(\.path))
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

    @Test("changedMarkdown is empty for a non-git directory (no base)")
    func changedMarkdownNonGit() throws {
        let dir = IntegrationSupport.tempDir("ln0")
        let launcher = Launcher(resolver: PathResolver(allowedRoots: [dir]))
        #expect(launcher.changedMarkdown(worktree: PathResolver.canonical(dir), parentRef: nil).isEmpty)
    }



    /// A repo whose worktree is a CHILD branch stacked on a `parent` branch: main(base) →
    /// parent(+docs/parent.md) → child=worktree(+docs/child.md). With a parent ref the diff/notes
    /// baseline against the parent (child's own work only); with nil they baseline against main (both).
    /// Uses tracked `docs/` markdown — baseline honoring is a git concept, whereas notes/ is gitignored
    /// scratch enumerated off disk (baseline-agnostic), covered separately below.
    private func makeStackedWorktree() throws -> (worktree: String, launcher: Launcher) {
        let root = IntegrationSupport.tempDir("lst")
        let repo = root + "/repo"
        let fm = FileManager.default
        try fm.createDirectory(atPath: repo + "/docs", withIntermediateDirectories: true)
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "config", "user.email", "t@t.t")
        try git(repo, "config", "user.name", "T")
        try "base\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "commit", "-q", "-m", "base")
        // Parent branch with its OWN doc.
        try git(repo, "checkout", "-q", "-b", "parent")
        try "# parent\n".write(toFile: repo + "/docs/parent.md", atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "commit", "-q", "-m", "parent note")
        try git(repo, "checkout", "-q", "main")   // leave `parent` as a bare local branch for the worktree
        // Child worktree forked from parent, with its OWN doc.
        let wt = root + "/wt"
        try git(repo, "worktree", "add", "-q", "-b", "child", wt, "parent")
        try "# child\n".write(toFile: wt + "/docs/child.md", atomically: true, encoding: .utf8)
        try git(wt, "add", ".")
        try git(wt, "commit", "-q", "-m", "child note")

        let config = Config(reposRoot: PathResolver.canonical(root),
                            worktreesRoot: PathResolver.canonical(root),
                            scratchRoot: PathResolver.canonical(root) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(root) + "/state")
        return (PathResolver.canonical(wt), Launcher(resolver: PathResolver(config: config)))
    }

    @Test("a parentRef baselines changedMarkdown + branchDiffDirs against the parent (child's own work only)")
    func parentBaselineExcludesParentWork() throws {
        let (wt, launcher) = try makeStackedWorktree()

        // Parent baseline: only the child's own doc.
        #expect(Set(launcher.changedMarkdown(worktree: wt, parentRef: "parent").map(\.path)) == ["docs/child.md"])
        // Default (nil) baseline vs main: the parent's doc is included too.
        #expect(Set(launcher.changedMarkdown(worktree: wt, parentRef: nil).map(\.path))
                == ["docs/parent.md", "docs/child.md"])

        // Zed "View changes": the parent-baselined multi-diff carries only the child's file.
        let dirs = try #require(try launcher.branchDiffDirs(worktree: wt, parentRef: "parent"))
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dirs.new + "/docs/child.md"))
        #expect(!fm.fileExists(atPath: dirs.new + "/docs/parent.md"))   // parent's work excluded
    }

    /// A worktree whose gitignored `notes/` vault holds plans + a nested design vault — the production
    /// setup after notes/ was untracked. git's diff/ls-files never report ignored paths, so Open-notes /
    /// the phone must scan them off disk; a tracked `.md` change alongside confirms the git set still works.
    @Test("changedMarkdown surfaces gitignored notes/ files (incl. nested) that git's diff never reports")
    func gitignoredNotesScannedOffDisk() throws {
        let root = IntegrationSupport.tempDir("lgn")
        let repo = root + "/repo"
        let fm = FileManager.default
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "config", "user.email", "t@t.t")
        try git(repo, "config", "user.name", "T")
        try "/notes/\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        try "x\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "commit", "-q", "-m", "base")

        let wt = root + "/wt"
        try git(repo, "worktree", "add", "-q", "-b", "feature", wt)
        // A card writes plans + a nested design vault into its gitignored notes/ — git sees none of it.
        try fm.createDirectory(atPath: wt + "/notes/plans", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: wt + "/notes/designs/slug", withIntermediateDirectories: true)
        try "p\n".write(toFile: wt + "/notes/plans/p1.md", atomically: true, encoding: .utf8)
        try "d\n".write(toFile: wt + "/notes/designs/slug/01-design.md", atomically: true, encoding: .utf8)
        // A dotdir under notes/ (e.g. Obsidian's own) must be skipped, not opened as a note.
        try fm.createDirectory(atPath: wt + "/notes/.obsidian", withIntermediateDirectories: true)
        try "{}\n".write(toFile: wt + "/notes/.obsidian/app.md", atomically: true, encoding: .utf8)
        // A tracked doc change, to confirm the git set still works alongside the disk scan.
        try "spec\n".write(toFile: wt + "/spec.md", atomically: true, encoding: .utf8)

        let config = Config(reposRoot: PathResolver.canonical(root),
                            worktreesRoot: PathResolver.canonical(root),
                            scratchRoot: PathResolver.canonical(root) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(root) + "/state")
        let launcher = Launcher(resolver: PathResolver(config: config))
        let cwt = PathResolver.canonical(wt)

        let notes = Set(launcher.changedMarkdown(worktree: cwt, parentRef: nil).map(\.path))
        #expect(notes.contains("notes/plans/p1.md"))                    // gitignored plan, found off disk
        #expect(notes.contains("notes/designs/slug/01-design.md"))      // nested vault file, found
        #expect(notes.contains("spec.md"))                              // tracked git change still included
        #expect(!notes.contains("notes/.obsidian/app.md"))              // dot component skipped

        // The status decoration the document list uses sees the gitignored notes too — an off-disk
        // scan, since git's diff never reports them.
        let byPath = Dictionary(uniqueKeysWithValues:
            launcher.changedMarkdown(worktree: cwt, parentRef: nil).map { ($0.path, $0) })
        #expect(byPath["notes/plans/p1.md"]?.added == true)
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
