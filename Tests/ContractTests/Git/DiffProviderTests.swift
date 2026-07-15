import Foundation
import Testing
@testable import OrchestraCore

@Suite("GitDiffProvider — stat + render over fixture repos")
struct DiffProviderTests {
    let provider = GitDiffProvider()

    // MARK: fixtures

    /// A throwaway git repo on `main` with one base commit (`a.txt`). Returns its path.
    static func makeRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "orch-diff-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try git(dir, "init", "-q", "-b", "main")
        try git(dir, "config", "user.email", "t@t")
        try git(dir, "config", "user.name", "t")
        try write(dir, "a.txt", "one\ntwo\nthree\n")
        try git(dir, "add", "-A")
        try git(dir, "commit", "-q", "-m", "base")
        return dir
    }

    @discardableResult
    static func git(_ dir: String, _ args: String...) throws -> ProcResult {
        let r = try Proc.run(["git"] + args, cwd: dir)
        #expect(r.ok, "git \(args.joined(separator: " ")) failed: \(r.stderr)")
        return r
    }
    static func write(_ dir: String, _ rel: String, _ s: String) throws {
        try s.write(toFile: dir + "/" + rel, atomically: true, encoding: .utf8)
    }

    /// `makeRepo` extended with a parent branch that has its OWN commit, then a child forked from it.
    /// Layout: main(a.txt) → parent(+p.txt) → feat=HEAD(+c.txt). Returns the repo path on `feat`.
    static func makeParentChild() throws -> String {
        let dir = try makeRepo()
        try git(dir, "checkout", "-q", "-b", "parent")
        try write(dir, "p.txt", "parent work\n")
        try git(dir, "add", "-A"); try git(dir, "commit", "-q", "-m", "parent work")
        try git(dir, "checkout", "-q", "-b", "feat")
        try write(dir, "c.txt", "child work\n")
        try git(dir, "add", "-A"); try git(dir, "commit", "-q", "-m", "child work")
        return dir
    }

    // MARK: stat

    @Test("zero changes → nil stat")
    func statZero() throws {
        let dir = try Self.makeRepo()
        #expect(try provider.stat(worktree: dir, base: .working, parentBranch: nil) == nil)
    }

    @Test("a working-tree modification is counted")
    func statModification() throws {
        let dir = try Self.makeRepo()
        try Self.write(dir, "a.txt", "one\ntwo\nthree\nfour\n")   // +1 line
        let s = try #require(try provider.stat(worktree: dir, base: .working, parentBranch: nil))
        #expect(s.filesChanged == 1)
        #expect(s.insertions == 1)
        #expect(s.deletions == 0)
    }

    @Test("a binary change counts 1 file, 0/0 lines")
    func statBinary() throws {
        let dir = try Self.makeRepo()
        try Data([0x00, 0x01, 0x02, 0x00, 0xff]).write(to: URL(fileURLWithPath: dir + "/a.txt"))
        let s = try #require(try provider.stat(worktree: dir, base: .working, parentBranch: nil))
        #expect(s.filesChanged == 1)
        #expect(s.insertions == 0)
        #expect(s.deletions == 0)
    }

    @Test(".branch counts a committed change on a feature branch vs the merge-base")
    func statBranch() throws {
        let dir = try Self.makeRepo()
        try Self.git(dir, "checkout", "-q", "-b", "feat")
        try Self.write(dir, "a.txt", "one\ntwo\nthree\nfive\n")
        try Self.git(dir, "commit", "-q", "-am", "feat change")
        let s = try #require(try provider.stat(worktree: dir, base: .branch, parentBranch: nil))
        #expect(s.filesChanged == 1)
        #expect(s.insertions == 1)   // "three\n" → "three\nfive\n" style change vs base
    }

    // MARK: render

    @Test("render is non-empty for a change; degrades to empty for a non-repo dir")
    func render() throws {
        let dir = try Self.makeRepo()
        try Self.write(dir, "a.txt", "one\ntwo\nthree\nfour\n")
        #expect(try !provider.render(worktree: dir, base: .working, parentBranch: nil).isEmpty)

        let nonRepo = NSTemporaryDirectory() + "orch-nonrepo-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: nonRepo, withIntermediateDirectories: true)
        #expect(try provider.render(worktree: nonRepo, base: .working, parentBranch: nil).isEmpty)
    }

    @Test("non-repo dir → nil stat (degrade, never fabricate)")
    func statNonRepo() throws {
        let nonRepo = NSTemporaryDirectory() + "orch-nonrepo-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: nonRepo, withIntermediateDirectories: true)
        #expect(try provider.stat(worktree: nonRepo, base: .branch, parentBranch: nil) == nil)
    }

    // MARK: baseline

    @Test(".parent with nil parentBranch resolves like .branch")
    func parentFallsBackToBranch() throws {
        let dir = try Self.makeRepo()
        try Self.git(dir, "checkout", "-q", "-b", "feat")
        try Self.write(dir, "a.txt", "one\ntwo\nthree\nfive\n")
        try Self.git(dir, "commit", "-q", "-am", "feat change")
        let parent = try provider.stat(worktree: dir, base: .parent, parentBranch: nil)
        let branch = try provider.stat(worktree: dir, base: .branch, parentBranch: nil)
        #expect(parent == branch)
    }

    @Test(".parent excludes the parent's own work (merge-base baseline)")
    func parentExcludesParentWork() throws {
        let dir = try Self.makeParentChild()
        let parent = try #require(try provider.stat(worktree: dir, base: .parent, parentBranch: "parent"))
        #expect(parent.filesChanged == 1)   // c.txt only — NOT the parent's p.txt
        // vs .branch (against main), which sees BOTH the parent's and the child's files.
        let branch = try #require(try provider.stat(worktree: dir, base: .branch, parentBranch: "parent"))
        #expect(branch.filesChanged == 2)
    }

    @Test("after a merge-sync the parent merge-base advances; diff still shows only the child's work")
    func mergeSyncAdvancesMergeBase() throws {
        let dir = try Self.makeParentChild()
        // Parent gains a NEW commit; child merges parent down (sync). Triple-dot: the merge-base moves
        // forward to include the parent's new work, so it is never re-counted as the child's.
        try Self.git(dir, "checkout", "-q", "parent")
        try Self.write(dir, "p2.txt", "more parent work\n")
        try Self.git(dir, "add", "-A"); try Self.git(dir, "commit", "-q", "-m", "parent work 2")
        try Self.git(dir, "checkout", "-q", "feat")
        try Self.git(dir, "merge", "-q", "--no-edit", "parent")   // sync parent into child
        let s = try #require(try provider.stat(worktree: dir, base: .parent, parentBranch: "parent"))
        #expect(s.filesChanged == 1)   // still c.txt only; p.txt + p2.txt are the parent's, excluded
    }

    @Test(".branch bases on the LOCAL default branch, not a stale origin/main")
    func statBranchPrefersLocalDefault() throws {
        let dir = try Self.makeRepo()   // main @ C0 (a.txt)
        let c0 = try Self.git(dir, "rev-parse", "HEAD").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Simulate a remote whose default branch (origin/main) lags: it's pinned at C0.
        try Self.git(dir, "update-ref", "refs/remotes/origin/main", c0)
        try Self.git(dir, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        // Local main advances with a commit the CARD did not author.
        try Self.write(dir, "b.txt", "mainline\n")
        try Self.git(dir, "add", "-A")
        try Self.git(dir, "commit", "-q", "-m", "main advances")
        // The card branch forks from the NEW local main and makes exactly one change.
        try Self.git(dir, "checkout", "-q", "-b", "feat")
        try Self.write(dir, "a.txt", "one\ntwo\nthree\nfive\n")
        try Self.git(dir, "commit", "-q", "-am", "feat change")

        let s = try #require(try provider.stat(worktree: dir, base: .branch, parentBranch: nil))
        // Only the card's own change (a.txt, +1) — NOT main's own b.txt commit. A stale-origin
        // baseline would fork at C0 and wrongly count b.txt too (2 files).
        #expect(s.filesChanged == 1)
        #expect(s.insertions == 1)
    }

    @Test("repo with no commits does not crash and yields nil stat")
    func noCommits() throws {
        let dir = NSTemporaryDirectory() + "orch-empty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Self.git(dir, "init", "-q", "-b", "main")
        #expect(try provider.stat(worktree: dir, base: .branch, parentBranch: nil) == nil)
    }
}
