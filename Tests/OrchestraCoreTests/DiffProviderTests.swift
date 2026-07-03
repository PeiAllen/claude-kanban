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
