// Real git behaviors the propagation pure/probe pieces (StoreGit, DeclaredSet, IgnoreProbe,
// LockProbe) assume, pinned against real git — never FakeProc. PR2 owns the seven rows below;
// PR3 and PR4 append their own rows to this same file in later waves (see 04-tests.md).
import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("SharedStore — real git contract (PR2: pure pieces + probes)", .enabled(if: IntegrationSupport.gitAvailable))
struct SharedStoreContractTests {
    /// A throwaway repo with one commit, mirroring `WorktreeRegistryIntegrationTests.makeRepo` —
    /// no shared helper exists to reuse, so this is its own private copy.
    private func makeRepo() throws -> (repo: String, base: String) {
        let base = IntegrationSupport.tempDir("shared-store")
        let repo = base + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try Proc.checked(["git", "-C", repo, "init", "-q", "-b", "main"])
        try Proc.checked(["git", "-C", repo, "config", "user.email", "t@t.t"])
        try Proc.checked(["git", "-C", repo, "config", "user.name", "T"])
        try "hi".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "init"])
        return (repo, base)
    }

    private func emptyTree(_ repo: String) throws -> String {
        try Proc.checked(["git", "-C", repo, "hash-object", "-t", "tree", "/dev/null"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Row 1: ls-tree rejects :(exclude); in diff, an exclude cancels a positive hole path.

    @Test("ls-tree rejects :(exclude) outright — exit 128")
    func lsTreeRejectsExcludeMagic() throws {
        let (repo, _) = try makeRepo()
        try FileManager.default.createDirectory(atPath: repo + "/dir", withIntermediateDirectories: true)
        try "h".write(toFile: repo + "/dir/hole.txt", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "second"])

        let result = try Proc.run(["git", "-C", repo, "ls-tree", "-r", "--name-only", "HEAD", "--", "README.md", ":(exclude)dir/hole.txt"])
        #expect(result.exitCode == 128)
    }

    @Test("in diff, an exclude pathspec cancels a positive path that falls inside it")
    func diffExcludeCancelsPositiveHole() throws {
        let (repo, _) = try makeRepo()
        try FileManager.default.createDirectory(atPath: repo + "/dir", withIntermediateDirectories: true)
        try "h".write(toFile: repo + "/dir/hole.txt", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "second"])
        let empty = try emptyTree(repo)

        // A single query trying to say "everything outside dir, PLUS dir/hole.txt itself" fails:
        // dir/hole.txt is listed as a positive AND falls under the ":(exclude)dir" pathspec, so the
        // exclude wins and it never appears — exactly why the two-query split exists.
        let result = try Proc.checked(
            ["git", "-C", repo, "diff", "--name-only", empty, "HEAD", "--", ":(top)", ":(exclude)dir", "dir/hole.txt"])
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "README.md")
    }

    // MARK: - Row 2: ls-tree given two tree-ishes lists a hole present only in the second tree as missing.

    @Test("ls-tree given two tree-ishes silently reads the second as a path, so a hole unique to it goes missing")
    func lsTreeTwoTreeIshesLosesTheHole() throws {
        let (repo, _) = try makeRepo()
        let tree1 = try Proc.checked(["git", "-C", repo, "rev-parse", "HEAD^{tree}"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.createDirectory(atPath: repo + "/dir", withIntermediateDirectories: true)
        try "h".write(toFile: repo + "/dir/hole.txt", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "second"])
        let tree2 = try Proc.checked(["git", "-C", repo, "rev-parse", "HEAD^{tree}"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let twoTreeIsh = try Proc.checked(["git", "-C", repo, "ls-tree", "-r", "--name-only", tree1, tree2, "--", "dir/hole.txt"])
        #expect(twoTreeIsh.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // The same call with exactly one tree-ish finds it — proving the hole was real, not just
        // absent from the fixture.
        let oneTreeIsh = try Proc.checked(["git", "-C", repo, "ls-tree", "-r", "--name-only", tree2, "--", "dir/hole.txt"])
        #expect(oneTreeIsh.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "dir/hole.txt")
    }

    // MARK: - Row 3: the outside-query and holes-query together list exactly the out-of-set files, hole included.

    @Test("outside-query plus holes-query together list exactly the out-of-set files, including the hole")
    func outsideAndHolesQueriesTogetherAreExact() throws {
        let (repo, _) = try makeRepo()
        try FileManager.default.createDirectory(atPath: repo + "/dir", withIntermediateDirectories: true)
        try "hole".write(toFile: repo + "/dir/hole.txt", atomically: true, encoding: .utf8)
        try "other".write(toFile: repo + "/dir/other.txt", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "second"])
        let empty = try emptyTree(repo)

        // declared = ["dir"], exclusions = ["dir/hole.txt"]
        let outside = try Proc.checked(["git", "-C", repo, "diff", "--name-only", empty, "HEAD", "--", ":(top)", ":(exclude)dir"])
            .stdout.split(separator: "\n").map(String.init)
        let holes = try Proc.checked(["git", "-C", repo, "ls-tree", "-r", "--name-only", "HEAD", "--", "dir/hole.txt"])
            .stdout.split(separator: "\n").map(String.init)

        #expect(Set(outside) == ["README.md"])
        #expect(Set(holes) == ["dir/hole.txt"])
        // dir/other.txt — in scope, not a hole — is in neither query's output.
        #expect(!outside.contains("dir/other.txt"))
        #expect(!holes.contains("dir/other.txt"))
    }

    // MARK: - Row 4: add -f exits 128 on an absent positive, succeeds (no-op) on an absent exclude.

    @Test("add -f exits 128 on a positive matching nothing")
    func addForceFailsOnAbsentPositive() throws {
        let (repo, _) = try makeRepo()
        let result = try Proc.run(["git", "-C", repo, "add", "-f", "--", "absent.txt"])
        #expect(result.exitCode == 128)
    }

    @Test("add -f succeeds, as a no-op, when only an exclude matches nothing")
    func addForceSucceedsOnAbsentExclude() throws {
        let (repo, _) = try makeRepo()
        let result = try Proc.run(["git", "-C", repo, "add", "-f", "--", "README.md", ":(exclude)absent.txt"])
        #expect(result.exitCode == 0)
    }

    // MARK: - Row 5: check-ignore exits 128 for a path beyond a symlink; --no-index matches a still-tracked path.

    @Test("check-ignore exits 128 for a path beyond a symlink")
    func checkIgnoreFailsBeyondSymlink() throws {
        let (repo, _) = try makeRepo()
        let target = repo + "-target"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: repo + "/linked", withDestinationPath: target)

        // Bound to IgnoreProbe.classifyArgv's actual output, not a hand-copied literal — a future
        // change to that argv shape breaks this test instead of silently drifting out of sync with it.
        let result = try Proc.run(["git", "-C", repo] + IgnoreProbe.classifyArgv("linked/inside.txt").dropFirst())
        #expect(result.exitCode == 128)
    }

    @Test("--no-index matches a still-tracked path once a pattern covers it; the default mode does not")
    func noIndexMatchesTrackedPathPatternNowCovers() throws {
        let (repo, _) = try makeRepo()
        try "README.md\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)

        let tracked = try Proc.run(["git", "-C", repo] + IgnoreProbe.classifyArgv("README.md").dropFirst())
        #expect(tracked.exitCode == 1, "still-tracked, so the default mode reports it as not ignored")

        let noIndex = try Proc.run(["git", "-C", repo] + IgnoreProbe.ignoredByPatternsArgv("README.md").dropFirst())
        #expect(noIndex.exitCode == 0, "--no-index reports the pattern match regardless of tracking state")
    }

    // MARK: - Row 6: while git holds index.lock, lsof -t lists its PID; after kill -9, the lock stays
    // with no holder and the next call exits 128.

    @Test("lsof -t finds the PID holding index.lock; after kill -9 the lock stays with no holder and the next call exits 128")
    func lockHolderProofAndOrphanResidue() async throws {
        let (repo, _) = try makeRepo()
        let fifoPath = repo + "/.orch-test.fifo"
        #expect(mkfifo(fifoPath, 0o600) == 0)

        // `git update-index --stdin` takes the index lock immediately and blocks reading commands
        // from the FIFO, which nothing writes to — holding the lock open until killed.
        //
        // Opening a FIFO read-only blocks the OPENING call itself until a writer opens the other
        // end — which would deadlock this test, since nothing ever writes. Opening O_RDWR sidesteps
        // that (the fd is its own writer, so `open` returns immediately) while still giving git a
        // fd whose `read(2)` genuinely blocks, since nothing ever writes to it either.
        let fifoFd = open(fifoPath, O_RDWR)
        #expect(fifoFd >= 0)
        let fifoHandle = FileHandle(fileDescriptor: fifoFd, closeOnDealloc: true)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        holder.arguments = ["git", "-C", repo, "update-index", "--stdin"]
        holder.standardInput = fifoHandle
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }

        let lockPath = repo + "/.git/index.lock"
        try await pollUntil("index.lock appears") { FileManager.default.fileExists(atPath: lockPath) }

        let holders = await LockProbe.holders(lockPath, proc: RealProc())
        #expect(holders?.contains(holder.processIdentifier) == true)

        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()

        try await pollUntil("lock has no holder after kill -9") {
            await LockProbe.holders(lockPath, proc: RealProc())?.isEmpty == true
        }
        let residual = await LockProbe.holders(lockPath, proc: RealProc())
        #expect(residual == [])
        // The lock FILE itself is not auto-removed — that's LockProbe's caller's job, only after
        // confirming no holder.
        #expect(FileManager.default.fileExists(atPath: lockPath))

        let next = try Proc.run(["git", "-C", repo, "add", "-f", "--", "README.md"])
        #expect(next.exitCode == 128)
        #expect(next.stderr.contains("index.lock"))

        try? FileManager.default.removeItem(atPath: lockPath)
    }

    // MARK: - Row 7: an agent-written .gitattributes filter attribute does not run under
    // --attr-source=<empty tree>.

    @Test("an agent-written .gitattributes filter attribute does not run under --attr-source=<empty tree>")
    func gitattributesFilterNeutralizedByAttrSource() throws {
        let (repo, _) = try makeRepo()
        try Proc.checked(["git", "-C", repo, "config", "filter.orch-test-sentinel.clean", "touch \(repo)/SENTINEL && cat"])
        try "* filter=orch-test-sentinel\n".write(toFile: repo + "/.gitattributes", atomically: true, encoding: .utf8)
        try "secret".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        let empty = try emptyTree(repo)

        try? FileManager.default.removeItem(atPath: repo + "/SENTINEL")
        try Proc.checked(["git", "-C", repo, "--attr-source=\(empty)", "add", "--", "f.txt"])
        #expect(!FileManager.default.fileExists(atPath: repo + "/SENTINEL"), "the filter must not have run")
    }
}
