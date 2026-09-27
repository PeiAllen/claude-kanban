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

    @Test("a `dir/` pattern does not match the bare name of a directory that does not exist, but matches its child")
    func dirPatternNeedsAChildWhenTheDirIsAbsent() throws {
        let (repo, _) = try makeRepo()
        try ".obsidian/\n.trash/\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        // Why the Obsidian guard probes `<dir>/.orchestra-probe`: the bare name reports "not ignored".
        for dir in [".obsidian", ".trash"] {
            let bare = try Proc.run(["git", "-C", repo] + IgnoreProbe.classifyArgv(dir).dropFirst())
            #expect(bare.exitCode == 1)
            let child = try Proc.run(["git", "-C", repo] + IgnoreProbe.classifyArgv(dir + "/.orchestra-probe").dropFirst())
            #expect(child.exitCode == 0)
        }
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

    // MARK: - PR3 rows: SharedStore end to end, real git (see 04-tests.md's Contract-tier list;
    // notes/plans/2026-09-22-shared-store.md Task 8 numbers these steps 1-13).

    /// A real git repo standing in for a checkout's working tree — `.gitignore` marks
    /// `sharedPaths` ignored so the store's write-out (which writes only declared+ignored leaves)
    /// actually has something to write. `trackedPaths` stay tracked (unignored), for the
    /// pre-migration scenario.
    private func makeCheckoutRepo(_ base: String, name: String, sharedPaths: [String] = ["CLAUDE.md"], trackedPaths: [String] = []) throws -> String {
        let dir = base + "/" + name
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Proc.checked(["git", "-C", dir, "init", "-q", "-b", "main"])
        try Proc.checked(["git", "-C", dir, "config", "user.email", "t@t.t"])
        try Proc.checked(["git", "-C", dir, "config", "user.name", "T"])
        try "hi".write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
        for path in trackedPaths { try "tracked".write(toFile: dir + "/" + path, atomically: true, encoding: .utf8) }
        if !sharedPaths.isEmpty {
            try (sharedPaths.map { $0 + "\n" }.joined()).write(toFile: dir + "/.gitignore", atomically: true, encoding: .utf8)
        }
        try Proc.checked(["git", "-C", dir, "add", "."])
        try Proc.checked(["git", "-C", dir, "commit", "-q", "-m", "init"])
        return dir
    }

    /// `unignored` must match whatever's passed as `commitLocal`'s OWN `unignoredLeaves:` — it's
    /// what excludes a currently-tracked leaf from `stagingPositives`/`stagingPathspec` (so
    /// `commitLocal`'s `add -f` never stages it), not just the flip-test bookkeeping.
    private func declaredSet(paths: [String], exclusions: [String] = [], unignored: Set<String> = [], in checkout: String) -> DeclaredSet.Result {
        DeclaredSet.build(paths: paths, exclusions: exclusions, unignoredLeaves: unignored,
                          existsInWorkingTreeOrIndex: { FileManager.default.fileExists(atPath: checkout + "/" + $0) })
    }

    private func projectStatus(_ repo: String) throws -> (head: String, status: String, tree: String) {
        let head = try Proc.checked(["git", "-C", repo, "rev-parse", "HEAD"]).stdout
        let status = try Proc.checked(["git", "-C", repo, "status", "--porcelain"]).stdout
        let tree = try Proc.checked(["git", "-C", repo, "rev-parse", "HEAD^{tree}"]).stdout
        return (head, status, tree)
    }

    // Step 1: first-attach ADOPT never clobbers an existing file.
    @Test("first-attach ADOPT never clobbers an existing local file with novel content")
    func firstAttachAdoptNeverClobbers() async throws {
        let root = IntegrationSupport.tempDir("shared-store-e2e")
        let repo = root + "/repo"
        let a = try makeCheckoutRepo(root, name: "a")
        let b = try makeCheckoutRepo(root, name: "b")
        let store = SharedStore(root: root + "/store", proc: RealProc())

        try "v1".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        let handleA = try await store.attach(checkout: a, repo: repo, declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))

        try "v2-local-novel".write(toFile: b + "/CLAUDE.md", atomically: true, encoding: .utf8)
        _ = try await store.attach(checkout: b, repo: repo, declared: declaredSet(paths: ["CLAUDE.md"], in: b))

        // The novel local content must survive UNCHANGED — never silently overwritten by adopt.
        let content = try String(contentsOfFile: b + "/CLAUDE.md", encoding: .utf8)
        #expect(content == "v2-local-novel")
    }

    // Step 2 (THE most important test in this PR): the dirty race, end to end.
    @Test("the dirty race: HEAD kept while a leaf is dirty, so the next sync's store holds both edits")
    func dirtyRaceEndToEnd() async throws {
        let root = IntegrationSupport.tempDir("shared-store-e2e")
        let repo = root + "/repo"
        let a = try makeCheckoutRepo(root, name: "a")
        let b = try makeCheckoutRepo(root, name: "b")
        let store = SharedStore(root: root + "/store", proc: RealProc())
        // `declaredSet` snapshots working-tree existence at CALL time — it must be recomputed at
        // every use site, never cached across a write/delete, or a stale "doesn't exist yet" (or
        // "still exists") snapshot silently skips staging or throws on a since-removed path.

        // Seed from A: "line1\nline2\nline3\n".
        try "line1\nline2\nline3\n".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        let handleA = try await store.attach(checkout: a, repo: repo, declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))

        // B adopts the seed. This exercises the ADOPT-then-immediately-receive gap: attach's
        // `reset --mixed store/main` repoints HEAD/index to the store's commit without ever
        // touching the working tree, so receive must still materialize CLAUDE.md onto disk even
        // though HEAD already matches the store "by history".
        let handleB = try await store.attach(checkout: b, repo: repo, declared: declaredSet(paths: ["CLAUDE.md"], in: b))
        _ = try await store.receive(handleB, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: b))
        #expect(try String(contentsOfFile: b + "/CLAUDE.md", encoding: .utf8) == "line1\nline2\nline3\n")

        // A changes line 1 and sends.
        try "LINE1-A\nline2\nline3\n".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))

        // B, mid-receive, has an uncommitted edit to line 3 — write it to disk BEFORE calling
        // receive (simulating an edit landing during the write-out window is indistinguishable
        // from one already on disk when receive starts, for this property: HEAD must stay at B's
        // old HEAD either way, so the next commitLocal treats the dirty edit as real content to
        // merge, not as something to discard).
        try "line1\nline2\nLINE3-B\n".write(toFile: b + "/CLAUDE.md", atomically: true, encoding: .utf8)
        let firstReceive = try await store.receive(handleB, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: b))
        guard case .partial(let dirty) = firstReceive else {
            Issue.record("expected .partial, got \(firstReceive)"); return
        }
        #expect(dirty == ["CLAUDE.md"])
        // The dirty edit is untouched on disk.
        #expect(try String(contentsOfFile: b + "/CLAUDE.md", encoding: .utf8) == "line1\nline2\nLINE3-B\n")

        // The NEXT sync: commitLocal commits B's dirty edit (now identical-to-store for lines
        // 1-2), then receive merges A's line-1 change with B's line-3 change.
        _ = try await store.commitLocal(handleB, declared: declaredSet(paths: ["CLAUDE.md"], in: b), unignoredLeaves: [])
        let secondReceive = try await store.receive(handleB, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: b))
        guard case .materialized = secondReceive else {
            Issue.record("expected .materialized, got \(secondReceive)"); return
        }
        let finalContent = try String(contentsOfFile: b + "/CLAUDE.md", encoding: .utf8)
        #expect(finalContent == "LINE1-A\nline2\nLINE3-B\n", "both edits must survive — the store must never have reverted A's change")
    }

    // Step 3: the flip test.
    @Test("the flip test: a leaf that stood down with a stale local copy is not committed over the store's newer content")
    func flipTestEndToEnd() async throws {
        let root = IntegrationSupport.tempDir("shared-store-e2e")
        let repo = root + "/repo"
        let a = try makeCheckoutRepo(root, name: "a")
        // b starts with CLAUDE.md ignored (the default), so the FIRST receive below can actually
        // materialize "v1" — the ignore rule is removed for the stand-down phase, then re-added
        // to simulate the untrack step.
        let b = try makeCheckoutRepo(root, name: "b")
        let store = SharedStore(root: root + "/store", proc: RealProc())

        // Seed "v1", then "v1a", through A, and have B genuinely sync BOTH — this is what puts
        // two distinct commits into B's OWN shadow checkout history, which `staleTest` (via
        // `--find-object`) needs to correctly classify a later stale copy as "stale" rather than
        // "novel". A leaf whose content was never part of the shadow history at all is novel, not
        // stale — a different case, covered by `attach`'s own adopt tests.
        try "v1".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        let handleA = try await store.attach(checkout: a, repo: repo, declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        let handleB = try await store.attach(checkout: b, repo: repo, declared: declaredSet(paths: ["CLAUDE.md"], in: b))
        _ = try await store.receive(handleB, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: b))
        #expect(try String(contentsOfFile: b + "/CLAUDE.md", encoding: .utf8) == "v1")

        try "v1a".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        _ = try await store.receive(handleB, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: b))
        #expect(try String(contentsOfFile: b + "/CLAUDE.md", encoding: .utf8) == "v1a", "B's shadow HEAD now sits at v1a, with v1 reachable in its own history")

        // B stands down: CLAUDE.md becomes tracked in B's real project repo (simulating a branch
        // where the untrack migration hasn't landed). `declared` here excludes CLAUDE.md from the
        // staging pathspec (unignored: ["CLAUDE.md"]), matching what a real caller's DeclaredSet
        // would look like for a currently-tracked leaf — required, or `commitLocal`'s `add -f`
        // would stage and commit B's real tracked file over the shadow history.
        try "".write(toFile: b + "/.gitignore", atomically: true, encoding: .utf8)  // drop the CLAUDE.md ignore rule
        try Proc.checked(["git", "-C", b, "add", ".gitignore", "CLAUDE.md"])
        try Proc.checked(["git", "-C", b, "commit", "-q", "-m", "track CLAUDE.md"])
        _ = try await store.commitLocal(handleB, declared: declaredSet(paths: ["CLAUDE.md"], unignored: ["CLAUDE.md"], in: b), unignoredLeaves: ["CLAUDE.md"])

        // While tracked, the PROJECT's own history reverts the file's content to "v1" — the
        // OLDER, now-stale value, distinct from B's shadow HEAD ("v1a"). This is the case the
        // flip test exists for: a genuine divergence between disk and shadow HEAD, where the
        // on-disk content happens to be something the shadow checkout has already seen before.
        try "v1".write(toFile: b + "/CLAUDE.md", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", b, "add", "CLAUDE.md"])
        try Proc.checked(["git", "-C", b, "commit", "-q", "-m", "revert to v1 upstream"])

        // Meanwhile A advances the store to "v2" — B's shadow checkout never sees it, since
        // PropagationService (a later PR) would never call SharedStore for a tracked item.
        try "v2".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))

        // The project untracks it (git rm --cached; the file stays on disk holding "v1") and adds
        // an ignore rule — simulating the post-migration state.
        try Proc.checked(["git", "-C", b, "rm", "-q", "--cached", "CLAUDE.md"])
        try "CLAUDE.md\n".write(toFile: b + "/.gitignore", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", b, "add", ".gitignore"])
        try Proc.checked(["git", "-C", b, "commit", "-q", "-m", "untrack"])

        // CLAUDE.md is ignored now. The flip test must catch the stale "v1" on disk — genuinely
        // different from shadow HEAD's "v1a" — and revert it to HEAD's committed content BEFORE
        // any sync runs. Without this, `receive` below would read "v1" as a local edit (it
        // differs from shadow HEAD and the file exists), refuse to overwrite it, and never reach
        // "v2" at all — proving this step actually exercises `staleTest`, not just `receive`.
        _ = try await store.commitLocal(handleB, declared: declaredSet(paths: ["CLAUDE.md"], in: b), unignoredLeaves: [])
        #expect(try String(contentsOfFile: b + "/CLAUDE.md", encoding: .utf8) == "v1a",
                "the flip test recognized v1 as stale (seen in B's own shadow history) and reverted it to shadow HEAD's v1a")

        _ = try await store.receive(handleB, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: b))
        _ = try await store.send(handleB, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: b))

        #expect(try String(contentsOfFile: b + "/CLAUDE.md", encoding: .utf8) == "v2", "B must have received the store's newer content, not kept its stale v1")
        let show = try Proc.checked(["git", "--git-dir=\(handleA.storeGitDir)", "show", "main:CLAUDE.md"])
        #expect(show.stdout == "v2", "the store must never have been overwritten with B's stale v1")
    }

    // Step 4: merge-tree conflict classification vs unrelated histories vs fast-forward.
    @Test("merge-tree classification: conflict exits 1 with paths and no MERGE_HEAD; unrelated roots exit 128")
    func mergeTreeClassification() async throws {
        let root = IntegrationSupport.tempDir("shared-store-e2e")
        let repo = root + "/repo"
        let a = try makeCheckoutRepo(root, name: "a")
        let b = try makeCheckoutRepo(root, name: "b")
        let store = SharedStore(root: root + "/store", proc: RealProc())

        try "base".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        let handleA = try await store.attach(checkout: a, repo: repo, declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        let handleB = try await store.attach(checkout: b, repo: repo, declared: declaredSet(paths: ["CLAUDE.md"], in: b))
        _ = try await store.receive(handleB, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: b))

        // Both sides edit the SAME line differently → a genuine conflict.
        try "A-edit".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        try "B-edit".write(toFile: b + "/CLAUDE.md", atomically: true, encoding: .utf8)
        _ = try await store.commitLocal(handleB, declared: declaredSet(paths: ["CLAUDE.md"], in: b), unignoredLeaves: [])
        let outcome = try await store.receive(handleB, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: b))
        guard case .conflicted(let paths, _) = outcome else { Issue.record("expected .conflicted, got \(outcome)"); return }
        #expect(paths == ["CLAUDE.md"])
        #expect(!FileManager.default.fileExists(atPath: handleB.checkoutGitDir + "/MERGE_HEAD"))

        // Unrelated histories: a SECOND, independently-seeded store forced against B's checkout
        // git dir directly proves the raw git classification (SharedStore itself re-adopts and
        // retries on this exit code, so exercising the bare git call is the honest way to pin it).
        let otherStore = root + "/other-store.git"
        try Proc.checked(["git", "init", "--bare", "-q", "-b", "main", otherStore])
        let scratch = root + "/scratch-seed"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        try Proc.checked(["git", "-C", scratch, "init", "-q", "-b", "main"])
        try Proc.checked(["git", "-C", scratch, "config", "user.email", "t@t.t"])
        try Proc.checked(["git", "-C", scratch, "config", "user.name", "T"])
        try "x".write(toFile: scratch + "/x.txt", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", scratch, "add", "."])
        try Proc.checked(["git", "-C", scratch, "commit", "-q", "-m", "unrelated root"])
        try Proc.checked(["git", "-C", scratch, "push", otherStore, "HEAD:main"])
        let unrelatedSha = try Proc.checked(["git", "-C", scratch, "rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // merge-tree needs BOTH commits resolvable in the SAME object database — fetch the
        // unrelated commit into B's checkout git dir first, or git reports "unknown revision"
        // instead of ever reaching the unrelated-histories classification.
        try Proc.checked(["git", "--git-dir=\(handleB.checkoutGitDir)", "fetch", otherStore, "main:refs/remotes/other/main"])
        let bHead = try Proc.checked([
            "git", "--git-dir=\(handleB.checkoutGitDir)", "--work-tree=\(b)", "rev-parse", "HEAD",
        ]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let mt = try Proc.run([
            "git", "--git-dir=\(handleB.checkoutGitDir)", "--work-tree=\(b)",
            "merge-tree", "--write-tree", "--name-only", "--no-messages", bHead, unrelatedSha,
        ])
        #expect(mt.exitCode == 128)
        #expect(mt.stderr.contains("unrelated histories"))
    }

    // Step 5: resolve end to end, including the symlink-as-data case.
    @Test("resolve end to end: the other checkout fast-forwards to the resolution, and a later sync does not conflict; a symlinked resolution stores mode 120000")
    func resolveEndToEnd() async throws {
        let root = IntegrationSupport.tempDir("shared-store-e2e")
        let repo = root + "/repo"
        let a = try makeCheckoutRepo(root, name: "a", sharedPaths: ["CLAUDE.md", "link.md"])
        let b = try makeCheckoutRepo(root, name: "b", sharedPaths: ["CLAUDE.md", "link.md"])
        let store = SharedStore(root: root + "/store", proc: RealProc())

        // link.md must ALSO be a genuine conflict (both sides commit different plain content to
        // it) for the symlink-as-data proof to mean anything — resolve() only ever processes the
        // paths merge-tree actually reports as conflicting; placing a symlink at a path that was
        // never part of the conflict wouldn't be resolved at all, it would just sit unstaged.
        try "base".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        try "base-link".write(toFile: a + "/link.md", atomically: true, encoding: .utf8)
        let handleA = try await store.attach(checkout: a, repo: repo, declared: declaredSet(paths: ["CLAUDE.md", "link.md"], in: a))
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md", "link.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md", "link.md"], declared: declaredSet(paths: ["CLAUDE.md", "link.md"], in: a))
        let handleB = try await store.attach(checkout: b, repo: repo, declared: declaredSet(paths: ["CLAUDE.md", "link.md"], in: b))
        _ = try await store.receive(handleB, paths: ["CLAUDE.md", "link.md"], declared: declaredSet(paths: ["CLAUDE.md", "link.md"], in: b))

        try "A-edit".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        try "A-edit-link".write(toFile: a + "/link.md", atomically: true, encoding: .utf8)
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md", "link.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md", "link.md"], declared: declaredSet(paths: ["CLAUDE.md", "link.md"], in: a))
        try "B-edit".write(toFile: b + "/CLAUDE.md", atomically: true, encoding: .utf8)
        try "B-edit-link".write(toFile: b + "/link.md", atomically: true, encoding: .utf8)
        _ = try await store.commitLocal(handleB, declared: declaredSet(paths: ["CLAUDE.md", "link.md"], in: b), unignoredLeaves: [])
        let conflict = try await store.receive(handleB, paths: ["CLAUDE.md", "link.md"], declared: declaredSet(paths: ["CLAUDE.md", "link.md"], in: b))
        guard case .conflicted(let conflictedPaths, _) = conflict else { Issue.record("setup failed to conflict: \(conflict)"); return }
        #expect(Set(conflictedPaths) == ["CLAUDE.md", "link.md"])

        // Resolve: the agent reconciles CLAUDE.md with a plain edit, and resolves link.md with a
        // SYMLINK pointing at a file with real content — it must be stored as a link, never the
        // target's content.
        try "reconciled".write(toFile: b + "/CLAUDE.md", atomically: true, encoding: .utf8)
        let secretTarget = root + "/secret.md"
        try "secret target content".write(toFile: secretTarget, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: b + "/link.md")
        try FileManager.default.createSymbolicLink(atPath: b + "/link.md", withDestinationPath: secretTarget)

        let resolveOutcome = try await store.resolve(handleB, paths: ["CLAUDE.md", "link.md"], declared: declaredSet(paths: ["CLAUDE.md", "link.md"], in: b))
        guard case .resolved = resolveOutcome else { Issue.record("expected .resolved, got \(resolveOutcome)"); return }

        let storeGitDir = handleB.storeGitDir
        let lsTree = try Proc.checked(["git", "--git-dir=\(storeGitDir)", "ls-tree", "main", "--", "link.md"]).stdout
        #expect(lsTree.contains("120000"), "link.md must be stored as a symlink (mode 120000)")
        let blob = try Proc.checked(["git", "--git-dir=\(storeGitDir)", "show", "main:link.md"]).stdout
        #expect(blob.trimmingCharacters(in: .whitespacesAndNewlines) == secretTarget, "the blob must hold the link TEXT, never the target's content")
        #expect(!blob.contains("secret target content"))

        // A fast-forwards to the resolution.
        let aReceive = try await store.receive(handleA, paths: ["CLAUDE.md", "link.md"], declared: declaredSet(paths: ["CLAUDE.md", "link.md"], in: a))
        guard case .materialized = aReceive else { Issue.record("expected A to fast-forward, got \(aReceive)"); return }
        #expect(try String(contentsOfFile: a + "/CLAUDE.md", encoding: .utf8) == "reconciled")

        // A later sync on either side does not conflict again.
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md", "link.md"], in: a), unignoredLeaves: [])
        let laterReceive = try await store.receive(handleA, paths: ["CLAUDE.md", "link.md"], declared: declaredSet(paths: ["CLAUDE.md", "link.md"], in: a))
        if case .conflicted = laterReceive { Issue.record("must not conflict again after a clean resolution") }
    }

    // Step 6: non-fast-forward push rejection matches the patterns send() looks for.
    @Test("a non-fast-forward push rejection matches the patterns send checks for")
    func nonFastForwardPushRejectionPattern() async throws {
        let root = IntegrationSupport.tempDir("shared-store-e2e")
        let repo = root + "/repo"
        let a = try makeCheckoutRepo(root, name: "a")
        let b = try makeCheckoutRepo(root, name: "b")
        let store = SharedStore(root: root + "/store", proc: RealProc())

        try "base".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        let handleA = try await store.attach(checkout: a, repo: repo, declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        let handleB = try await store.attach(checkout: b, repo: repo, declared: declaredSet(paths: ["CLAUDE.md"], in: b))
        _ = try await store.receive(handleB, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: b))

        try "A-edit".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))

        try "B-edit-disjoint".write(toFile: b + "/other.md", atomically: true, encoding: .utf8) // no-op, just to differ
        try "B-edit".write(toFile: b + "/CLAUDE.md", atomically: true, encoding: .utf8)
        _ = try await store.commitLocal(handleB, declared: declaredSet(paths: ["CLAUDE.md"], in: b), unignoredLeaves: [])
        // B's raw push, without going through receive first, against a HEAD that's now behind A's push.
        let raw = try Proc.run(["git", "--git-dir=\(handleB.checkoutGitDir)", "--work-tree=\(b)", "push", handleB.storeGitDir, "HEAD:main"])
        #expect(raw.exitCode != 0)
        #expect(raw.stderr.contains("[rejected]"))
        #expect(raw.stderr.contains("fetch first") || raw.stderr.contains("non-fast-forward"))
    }

    // Step 7: a push with nothing committed fails "src refspec HEAD does not match any".
    @Test("a push with nothing committed (unborn HEAD) fails src refspec HEAD does not match any")
    func pushWithNothingCommittedFails() throws {
        let root = IntegrationSupport.tempDir("shared-store-e2e")
        let bareDir = root + "/bare.git"
        try Proc.checked(["git", "init", "--bare", "-q", "-b", "main", bareDir])
        let checkoutDir = root + "/unborn-checkout.git"
        try Proc.checked(["git", "init", "--bare", "-q", checkoutDir])
        let workTree = root + "/unborn-work"
        try FileManager.default.createDirectory(atPath: workTree, withIntermediateDirectories: true)
        let raw = try Proc.run(["git", "--git-dir=\(checkoutDir)", "--work-tree=\(workTree)", "push", bareDir, "HEAD:main"])
        #expect(raw.exitCode != 0)
        #expect(raw.stderr.contains("src refspec HEAD does not match any"))
    }

    // Step 8: the agent-facing read path — fetch, then a read-only `show` from a separate process.
    @Test("fetch main:refs/remotes/store/main makes show store/main:<path> work read-only from a separate process")
    func agentFacingReadPath() async throws {
        let root = IntegrationSupport.tempDir("shared-store-e2e")
        let repo = root + "/repo"
        let a = try makeCheckoutRepo(root, name: "a")
        let store = SharedStore(root: root + "/store", proc: RealProc())
        try "agent-readable".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        let handleA = try await store.attach(checkout: a, repo: repo, declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))

        // A separate, read-only process — no SharedStore, no daemon-owned checkout git dir.
        let readerDir = root + "/reader.git"
        try Proc.checked(["git", "init", "--bare", "-q", readerDir])
        try Proc.checked(["git", "--git-dir=\(readerDir)", "fetch", handleA.storeGitDir, "main:refs/remotes/store/main"])
        let content = try Proc.checked(["git", "--git-dir=\(readerDir)", "show", "store/main:CLAUDE.md"], env: ["GIT_OPTIONAL_LOCKS": "0"])
        #expect(content.stdout == "agent-readable")
    }

    // Step 9: --find-object finds a root-commit blob and an older blob.
    @Test("--find-object finds a root-commit blob and an older blob several commits back")
    func findObjectFindsRootAndOlderBlobs() async throws {
        let root = IntegrationSupport.tempDir("shared-store-e2e")
        let repo = root + "/repo"
        let a = try makeCheckoutRepo(root, name: "a")
        let store = SharedStore(root: root + "/store", proc: RealProc())

        try "root-content".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        let rootBlob = try Proc.checked(["git", "-C", a, "hash-object", "CLAUDE.md"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let handleA = try await store.attach(checkout: a, repo: repo, declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))

        for i in 1...3 {
            try "edit-\(i)".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
            _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
            _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        }
        let olderBlob = try Proc.checked(["git", "-C", a, "hash-object", "CLAUDE.md"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let rootFound = try Proc.checked(["git", "--git-dir=\(handleA.checkoutGitDir)", "log", "--all", "-n1", "--format=%H", "--find-object=\(rootBlob)"]).stdout
        #expect(!rootFound.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let olderFound = try Proc.checked(["git", "--git-dir=\(handleA.checkoutGitDir)", "log", "--all", "-n1", "--format=%H", "--find-object=\(olderBlob)"]).stdout
        #expect(!olderFound.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // Step 10: two checkouts, full cycle.
    @Test("two checkouts, full cycle: disjoint edits merge; a deletion propagates; a missing file is written back to a fresh third checkout")
    func twoCheckoutsFullCycle() async throws {
        let root = IntegrationSupport.tempDir("shared-store-e2e")
        let repo = root + "/repo"
        let a = try makeCheckoutRepo(root, name: "a", sharedPaths: ["one.md", "two.md"])
        let b = try makeCheckoutRepo(root, name: "b", sharedPaths: ["one.md", "two.md"])
        let c = try makeCheckoutRepo(root, name: "c", sharedPaths: ["one.md", "two.md"])
        let store = SharedStore(root: root + "/store", proc: RealProc())

        try "one-v1".write(toFile: a + "/one.md", atomically: true, encoding: .utf8)
        try "two-v1".write(toFile: a + "/two.md", atomically: true, encoding: .utf8)
        let handleA = try await store.attach(checkout: a, repo: repo, declared: declaredSet(paths: ["one.md", "two.md"], in: a))
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["one.md", "two.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["one.md", "two.md"], declared: declaredSet(paths: ["one.md", "two.md"], in: a))
        let handleB = try await store.attach(checkout: b, repo: repo, declared: declaredSet(paths: ["one.md", "two.md"], in: b))
        _ = try await store.receive(handleB, paths: ["one.md", "two.md"], declared: declaredSet(paths: ["one.md", "two.md"], in: b))

        // Disjoint edits: A edits one.md, B deletes two.md (staged on purpose).
        try "one-v2-from-A".write(toFile: a + "/one.md", atomically: true, encoding: .utf8)
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["one.md", "two.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["one.md", "two.md"], declared: declaredSet(paths: ["one.md", "two.md"], in: a))

        try Proc.checked(["git", "--git-dir=\(handleB.checkoutGitDir)", "--work-tree=\(b)", "rm", "-q", "--", "two.md"])
        // two.md no longer exists in the working tree (nor the index) — `declaredSet` computed
        // from THIS point on correctly omits it from stagingPositives, so `add -f` never sees an
        // absent positive (which would exit 128).
        let bCommit = try await store.commitLocal(handleB, declared: declaredSet(paths: ["one.md", "two.md"], in: b), unignoredLeaves: [])
        guard case .committed = bCommit else { Issue.record("expected B's deletion to commit, got \(bCommit)"); return }
        let bReceive = try await store.receive(handleB, paths: ["one.md", "two.md"], declared: declaredSet(paths: ["one.md", "two.md"], in: b))
        guard case .materialized = bReceive else { Issue.record("expected disjoint merge, got \(bReceive)"); return }
        _ = try await store.send(handleB, paths: ["one.md", "two.md"], declared: declaredSet(paths: ["one.md", "two.md"], in: b))

        #expect(try String(contentsOfFile: b + "/one.md", encoding: .utf8) == "one-v2-from-A")
        #expect(!FileManager.default.fileExists(atPath: b + "/two.md"))

        // A fresh third checkout receives one.md (present) and never had two.md (deleted).
        let handleC = try await store.attach(checkout: c, repo: repo, declared: declaredSet(paths: ["one.md", "two.md"], in: c))
        let cReceive = try await store.receive(handleC, paths: ["one.md", "two.md"], declared: declaredSet(paths: ["one.md", "two.md"], in: c))
        guard case .materialized = cReceive else { Issue.record("expected C to materialize, got \(cReceive)"); return }
        #expect(try String(contentsOfFile: c + "/one.md", encoding: .utf8) == "one-v2-from-A")
        #expect(!FileManager.default.fileExists(atPath: c + "/two.md"))
    }

    // Step 11: pre-migration full cycle — a still-tracked leaf is untouched, an ignored leaf updates.
    @Test("pre-migration full cycle: a store update leaves a still-tracked leaf and project status unchanged, and updates the ignored leaf")
    func preMigrationFullCycle() async throws {
        let root = IntegrationSupport.tempDir("shared-store-e2e")
        let repo = root + "/repo"
        // a: both paths ignored (post-migration). b: CLAUDE.md still TRACKED, settings.json ignored (pre-migration).
        let a = try makeCheckoutRepo(root, name: "a", sharedPaths: ["CLAUDE.md", "settings.json"])
        let b = try makeCheckoutRepo(root, name: "b", sharedPaths: ["settings.json"], trackedPaths: ["CLAUDE.md"])
        let store = SharedStore(root: root + "/store", proc: RealProc())

        try "claude-content".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        try "settings-content".write(toFile: a + "/settings.json", atomically: true, encoding: .utf8)
        let handleA = try await store.attach(checkout: a, repo: repo, declared: declaredSet(paths: ["CLAUDE.md", "settings.json"], in: a))
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md", "settings.json"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md", "settings.json"], declared: declaredSet(paths: ["CLAUDE.md", "settings.json"], in: a))

        let handleB = try await store.attach(checkout: b, repo: repo, declared: declaredSet(paths: ["CLAUDE.md", "settings.json"], in: b))
        let (headBefore, statusBefore, treeBefore) = try projectStatus(b)

        let outcome = try await store.receive(handleB, paths: ["CLAUDE.md", "settings.json"], declared: declaredSet(paths: ["CLAUDE.md", "settings.json"], in: b))
        guard case .materialized(let written, _) = outcome else { Issue.record("expected .materialized, got \(outcome)"); return }

        let (headAfter, statusAfter, treeAfter) = try projectStatus(b)
        #expect(headBefore == headAfter)
        #expect(statusBefore == statusAfter)
        #expect(treeBefore == treeAfter)
        #expect(written == ["settings.json"], "the still-tracked CLAUDE.md must never be written")
        #expect(try String(contentsOfFile: b + "/settings.json", encoding: .utf8) == "settings-content")
        #expect(try String(contentsOfFile: b + "/CLAUDE.md", encoding: .utf8) == "tracked", "the project's own tracked copy is untouched")
    }

    // Step 12: non-interference — after a full cycle, the project repo is byte-identical.
    @Test("non-interference: after a full propagation cycle, the project repo's HEAD, status, tree and tracked set are unchanged")
    func nonInterferenceAfterFullCycle() async throws {
        let root = IntegrationSupport.tempDir("shared-store-e2e")
        let repo = root + "/repo"
        let a = try makeCheckoutRepo(root, name: "a")
        let store = SharedStore(root: root + "/store", proc: RealProc())

        let (headBefore, statusBefore, treeBefore) = try projectStatus(a)
        try "content".write(toFile: a + "/CLAUDE.md", atomically: true, encoding: .utf8)
        let handleA = try await store.attach(checkout: a, repo: repo, declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        _ = try await store.commitLocal(handleA, declared: declaredSet(paths: ["CLAUDE.md"], in: a), unignoredLeaves: [])
        _ = try await store.send(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))
        _ = try await store.receive(handleA, paths: ["CLAUDE.md"], declared: declaredSet(paths: ["CLAUDE.md"], in: a))

        let (headAfter, statusAfter, treeAfter) = try projectStatus(a)
        #expect(headBefore == headAfter)
        #expect(statusBefore == statusAfter)
        #expect(treeBefore == treeAfter)
    }

    // Step 13: attach crash recovery — interrupted after `git init --bare` on the checkout git dir,
    // before info/exclude and orchestra-checkout are written.
    @Test("attach interrupted after the checkout git dir's bare init completes on the next call")
    func attachCrashRecovery() async throws {
        let root = IntegrationSupport.tempDir("shared-store-e2e")
        let repo = root + "/repo"
        let a = try makeCheckoutRepo(root, name: "a")
        let storeRoot = root + "/store"
        let repoKey = CardFileSpec.cwdHash(repo)
        let checkoutKey = CardFileSpec.cwdHash(a)
        let checkoutGitDir = "\(storeRoot)/\(repoKey)/checkouts/\(checkoutKey).git"

        // Simulate the crash window: the bare git dir exists (init completed — which, verified
        // against real git, already pre-populates info/exclude with ITS OWN commented-out
        // template, never "/*") but orchestra-checkout was never written and info/exclude was
        // never overwritten with Orchestra's own content.
        try Proc.checked(["git", "init", "--bare", "-q", checkoutGitDir])
        let gitsOwnTemplate = try String(contentsOfFile: checkoutGitDir + "/info/exclude", encoding: .utf8)
        #expect(gitsOwnTemplate != "/*\n")
        #expect(!FileManager.default.fileExists(atPath: checkoutGitDir + "/orchestra-checkout"))

        let store = SharedStore(root: storeRoot, proc: RealProc())
        let handle = try await store.attach(checkout: a, repo: repo, declared: declaredSet(paths: [], in: a))

        #expect(FileManager.default.fileExists(atPath: handle.checkoutGitDir + "/info/exclude"))
        #expect(try String(contentsOfFile: handle.checkoutGitDir + "/info/exclude", encoding: .utf8) == "/*\n")
        #expect(FileManager.default.fileExists(atPath: handle.checkoutGitDir + "/orchestra-checkout"))
        #expect(try String(contentsOfFile: handle.checkoutGitDir + "/orchestra-checkout", encoding: .utf8) == a)
    }

    // PR4: the lock rule keys on git's own stderr wording, so it is pinned against real git.
    @Test("a held index.lock and a held ref lock produce stderr the service's matcher reads, and a stale lock lets git through once removed")
    func lockStderrMatcherReadsRealGit() async throws {
        let root = IntegrationSupport.tempDir("shared-store-lock")
        let a = try makeCheckoutRepo(root, name: "a")
        let dotGit = PathResolver.canonical(a) + "/.git"
        try "changed".write(toFile: a + "/README.md", atomically: true, encoding: .utf8)
        try "".write(toFile: dotGit + "/index.lock", atomically: true, encoding: .utf8)
        let add = try Proc.run(["git", "-C", a, "add", "--", "README.md"], env: ["LC_ALL": "C"])
        #expect(add.exitCode != 0)
        #expect(PropagationService.lockPath(fromStderr: add.stderr) == dotGit + "/index.lock")
        try FileManager.default.removeItem(atPath: dotGit + "/index.lock")
        #expect(try Proc.run(["git", "-C", a, "add", "--", "README.md"]).exitCode == 0)

        try "0000000000000000000000000000000000000000\n".write(toFile: dotGit + "/refs/heads/x.lock", atomically: true, encoding: .utf8)
        let branch = try Proc.run(["git", "-C", a, "branch", "x"], env: ["LC_ALL": "C"])
        #expect(branch.exitCode != 0)
        #expect(PropagationService.lockPath(fromStderr: branch.stderr) == dotGit + "/refs/heads/x.lock")
    }

    @Test("a crash-left refs/remotes/store/main.lock makes receive throw instead of reading as an absent store main")
    func fetchLockThrowsNotUpToDate() async throws {
        let root = IntegrationSupport.tempDir("shared-store-fetchlock")
        let repo = root + "/repo"
        let a = try makeCheckoutRepo(root, name: "a", sharedPaths: ["one.md"])
        let store = SharedStore(root: root + "/store", proc: RealProc())
        try "v1".write(toFile: a + "/one.md", atomically: true, encoding: .utf8)
        let declared = declaredSet(paths: ["one.md"], in: a)
        let handle = try await store.attach(checkout: a, repo: repo, declared: declared)
        _ = try await store.commitLocal(handle, declared: declared, unignoredLeaves: [])
        _ = try await store.send(handle, paths: ["one.md"], declared: declared)

        try FileManager.default.createDirectory(atPath: handle.checkoutGitDir + "/refs/remotes/store", withIntermediateDirectories: true)
        try "".write(toFile: handle.checkoutGitDir + "/refs/remotes/store/main.lock", atomically: true, encoding: .utf8)
        do {
            _ = try await store.receive(handle, paths: ["one.md"], declared: declared)
            Issue.record("expected receive to throw on a held ref lock")
        } catch let SharedStoreError.gitFailed(_, _, stderr) {
            #expect(PropagationService.lockPath(fromStderr: stderr) == handle.checkoutGitDir + "/refs/remotes/store/main.lock")
        }
    }
}
