import Foundation
import Testing
@testable import OrchestraCore

@Suite("Config.defaultReposRoot — home directory")
struct DefaultReposRootTests {
    @Test("defaults to the home directory itself (setup-agnostic)")
    func isHome() {
        #expect(Config.defaultReposRoot == Config.home)
    }

    @Test("no longer hardcodes ~/Documents/Projects")
    func notDocumentsProjects() {
        #expect(!Config.defaultReposRoot.contains("/Documents/Projects"))
    }
}

@Suite("RepoScanner — pruning rules")
struct RepoScannerPruneTests {
    @Test("prunes hidden dot-directories")
    func hidden() {
        #expect(RepoScanner.shouldPrune(".git"))
        #expect(RepoScanner.shouldPrune(".worktrees"))
        #expect(RepoScanner.shouldPrune(".config"))
    }

    @Test("prunes known heavy / irrelevant directories")
    func heavy() {
        for name in ["Library", "node_modules", ".build", "DerivedData", "Pods"] {
            #expect(RepoScanner.shouldPrune(name), "expected \(name) to be pruned")
        }
    }

    @Test("does not prune ordinary project directories")
    func ordinary() {
        for name in ["Projects", "work", "src", "orchestra", "my-repo"] {
            #expect(!RepoScanner.shouldPrune(name), "expected \(name) not to be pruned")
        }
    }
}

@Suite("RepoScanner.scan — recursive walk")
struct RepoScannerScanTests {
    /// In-memory tree: `dirs[path]` = child directory names; `repos` = paths that contain `.git`.
    struct FakeTree {
        var dirs: [String: [String]] = [:]
        var repos: Set<String> = []

        func scan(root: String, maxDepth: Int) -> [String] {
            RepoScanner.scan(root: root, maxDepth: maxDepth,
                             isRepo: { repos.contains($0) },
                             subdirs: { dirs[$0] ?? [] })
        }
    }

    /// A representative $HOME layout with repos at various depths plus heavy/hidden noise.
    func sampleTree() -> FakeTree {
        var t = FakeTree()
        t.dirs["/home"] = ["Documents", "Library", "node_modules", ".config", "work", "alpha", "repoA"]
        t.dirs["/home/Documents"] = ["Projects"]
        t.dirs["/home/Documents/Projects"] = ["proj1", "proj2"]
        t.dirs["/home/Library"] = ["heavy"]
        t.dirs["/home/work"] = ["deep"]
        t.dirs["/home/work/deep"] = ["gamma"]
        t.dirs["/home/repoA"] = [".worktrees"]
        t.dirs["/home/repoA/.worktrees"] = ["wt"]
        t.repos = [
            "/home/Documents/Projects/proj1",
            "/home/Documents/Projects/proj2",
            "/home/work/deep/gamma",       // depth 3
            "/home/alpha",                 // depth 1
            "/home/repoA",                 // depth 1
            "/home/repoA/.worktrees/wt",   // inside a repo + hidden — must NOT be listed
            "/home/Library/heavy",         // under a pruned dir — must NOT be listed
        ]
        return t
    }

    @Test("finds repos nested at any depth under the root")
    func findsNested() {
        let found = Set(sampleTree().scan(root: "/home", maxDepth: 6))
        #expect(found.contains("/home/Documents/Projects/proj1"))
        #expect(found.contains("/home/Documents/Projects/proj2"))
        #expect(found.contains("/home/work/deep/gamma"))
        #expect(found.contains("/home/alpha"))
        #expect(found.contains("/home/repoA"))
    }

    @Test("stops descending once a repo is found (skips its .worktrees)")
    func stopsAtRepo() {
        let found = sampleTree().scan(root: "/home", maxDepth: 6)
        #expect(!found.contains("/home/repoA/.worktrees/wt"))
    }

    @Test("does not descend into pruned directories")
    func prunesHeavy() {
        let found = sampleTree().scan(root: "/home", maxDepth: 6)
        #expect(!found.contains("/home/Library/heavy"))
    }

    @Test("respects the max depth bound")
    func respectsMaxDepth() {
        // gamma lives at depth 3 (work=1, deep=2, gamma=3): unreachable at maxDepth 2.
        let shallow = sampleTree().scan(root: "/home", maxDepth: 2)
        #expect(!shallow.contains("/home/work/deep/gamma"))
        #expect(shallow.contains("/home/alpha"))   // depth-1 repo still found
    }

    @Test("returns results sorted by directory name, case-insensitively")
    func sorted() {
        var t = FakeTree()
        t.dirs["/r"] = ["Zed", "apple", "Beta"]
        t.repos = ["/r/Zed", "/r/apple", "/r/Beta"]
        let found = t.scan(root: "/r", maxDepth: 4)
        #expect(found == ["/r/apple", "/r/Beta", "/r/Zed"])
    }
}

@Suite("RepoScanner.discover — real filesystem")
struct RepoScannerDiscoverTests {
    /// Builds a temp tree, runs `discover`, and cleans up. Verifies the FileManager wiring: `.git`
    /// detection (dir or file), hidden/heavy pruning, stop-at-repo, and that symlinks aren't followed.
    @Test("discovers nested repos on disk while pruning noise and not following symlinks")
    func realTree() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reposcan-\(UUID().uuidString)")
        func mkdir(_ path: String) throws {
            try fm.createDirectory(at: base.appendingPathComponent(path),
                                   withIntermediateDirectories: true)
        }
        func mkrepo(_ path: String, gitIsFile: Bool = false) throws {
            try mkdir(path)
            let git = base.appendingPathComponent("\(path)/.git")
            if gitIsFile {
                try "gitdir: /elsewhere".write(to: git, atomically: true, encoding: .utf8)
            } else {
                try fm.createDirectory(at: git, withIntermediateDirectories: true)
            }
        }
        defer { try? fm.removeItem(at: base) }

        try mkrepo("Documents/Projects/alpha")               // depth 3, .git dir
        try mkrepo("Documents/Projects/beta", gitIsFile: true) // .git FILE (worktree-style)
        try mkrepo("work/deep/gamma")                        // depth 3
        try mkrepo("repoA")                                  // depth 1
        try mkdir("repoA/.worktrees/wt/.git")                // inside a repo — must be skipped
        try mkdir("Library/heavy/.git")                      // pruned dir — must be skipped
        try mkdir("node_modules/pkg/.git")                   // pruned dir — must be skipped
        // A symlink that loops back to the root must not be followed (would otherwise recurse forever).
        try fm.createSymbolicLink(at: base.appendingPathComponent("loop"), withDestinationURL: base)

        let found = Set(RepoScanner.discover(root: base.path, maxDepth: 6))
        let rel = Set(found.map { $0.replacingOccurrences(of: base.path + "/", with: "") })

        #expect(rel.contains("Documents/Projects/alpha"))
        #expect(rel.contains("Documents/Projects/beta"))
        #expect(rel.contains("work/deep/gamma"))
        #expect(rel.contains("repoA"))
        #expect(!rel.contains("repoA/.worktrees/wt"))   // stop-at-repo
        #expect(!rel.contains("Library/heavy"))         // pruned
        #expect(!rel.contains("node_modules/pkg"))      // pruned
        #expect(!found.contains { $0.contains("/loop/") }) // symlink not followed
    }
}
