import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

/// `StoreGit`'s hermetic env prefix (`--attr-source=<sha>` + `StoreGit.configPins`) sits between
/// `"git"` and the actual subcommand in every checkout-git-dir call this file makes. `FakeProc`
/// matches by raw argv prefix, so registering `on(["git","rev-parse",…])` directly never fires —
/// `onGit`/`gitArgs` strip that prefix first. The two bootstrap calls (`git init --bare …`, and
/// `StoreGit.emptyTreeHashArgv`) carry no such prefix and still match plain `fake.on(...)`.
extension FakeProc {
    func onGit(_ subcommand: [String], _ respond: @escaping ([String]) -> ProcResult?) {
        on(["git"]) { argv in
            guard let stripped = FakeProc.strippedGitArgs(argv), stripped.starts(with: subcommand)
            else { return nil }
            return respond(argv)
        }
    }

    static func strippedGitArgs(_ argv: [String]) -> [String]? {
        guard argv.first == "git" else { return nil }
        var rest = Array(argv.dropFirst())
        if rest.first?.hasPrefix("--attr-source=") == true { rest.removeFirst() }
        if rest.starts(with: StoreGit.configPins) { rest.removeFirst(StoreGit.configPins.count) }
        return rest
    }
}

extension FakeProc.Call {
    /// What a test should assert against instead of raw `argv` for a hermetic call — `nil` for a
    /// non-hermetic (bootstrap) call.
    var gitArgs: [String]? { FakeProc.strippedGitArgs(argv) }
}

private extension FakeProc {
    /// Scripts a `diff` call — `SharedStore`'s private `diff()` helper always pins `--no-renames`
    /// right after the subcommand, so every scripted `diff` rule needs it too.
    func onGitDiff(_ rest: [String], _ respond: @escaping ([String]) -> ProcResult?) {
        onGit(["diff", "--no-renames"] + rest, respond)
    }
}

/// NUL-joins `records` the way `merge-tree --write-tree --name-only --no-messages -z` does: the
/// tree OID first, then one record per conflicted path, each NUL-terminated.
private func mergeTreeZ(_ records: [String]) -> String {
    records.map { $0 + "\0" }.joined()
}

private func freshRoot() -> String { NSTemporaryDirectory() + "orch-shared-store-\(UUID().uuidString)" }

/// Thread-safe accumulator for a `@Sendable` `noteNovel` callback under test.
private final class NotedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    func append(_ v: String) { lock.lock(); _values.append(v); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return _values }
}

@Suite("SharedStore — attach")
struct SharedStoreAttachTests {
    @Test("attach on a brand-new root inits the bare store and the checkout git dir")
    func attachInitsBareStoreAndCheckoutGitDir() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        fake.on(["git", "init"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.on(["git", "hash-object"]) { _ in ProcResult(stdout: "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "fatal: couldn't find remote ref main", exitCode: 1) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["diff", "--cached", "--quiet"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let handle = try await store.attach(checkout: root + "/checkout", repo: root + "/repo", declared: declared)

        #expect(fake.calls.contains { $0.argv.starts(with: ["git", "init", "--bare", "-b", "main"]) })
        #expect(fake.calls.contains { $0.argv.starts(with: ["git", "init", "--bare"]) && !$0.argv.contains("-b") })
        #expect(FileManager.default.fileExists(atPath: handle.checkoutGitDir + "/info/exclude"))
        #expect(try String(contentsOfFile: handle.checkoutGitDir + "/info/exclude", encoding: .utf8) == "/*\n")
        #expect(try String(contentsOfFile: handle.checkoutGitDir + "/orchestra-checkout", encoding: .utf8) == root + "/checkout")
        #expect(handle.emptyTreeHash == "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
    }

    @Test("first attach with nothing staged seeds no commit and no push")
    func seedWithNothingStagedPushesNothing() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        fake.on(["git", "init"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.on(["git", "hash-object", "-t", "tree"]) { _ in ProcResult(stdout: "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "fatal: couldn't find remote ref main", exitCode: 1) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["diff", "--cached", "--quiet"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) } // nothing staged

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        _ = try await store.attach(checkout: root + "/c", repo: root + "/r", declared: declared)

        #expect(!fake.calls.contains { $0.gitArgs?.starts(with: ["commit"]) == true })
        #expect(!fake.calls.contains { $0.gitArgs?.starts(with: ["push"]) == true })
    }

    @Test("first attach with store main present issues reset --mixed, never a checkout over an existing file")
    func firstAttachAdoptResetsMixedNeverClobbers() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        fake.on(["git", "init"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.on(["git", "hash-object", "-t", "tree"]) { _ in ProcResult(stdout: "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["reset", "-q", "--mixed", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["ls-files", "-z", "--modified"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["a.md"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in true })
        _ = try await store.attach(checkout: root + "/c", repo: root + "/r", declared: declared)

        #expect(fake.calls.contains { $0.gitArgs?.starts(with: ["reset", "-q", "--mixed", "refs/remotes/store/main"]) == true })
        #expect(!fake.calls.contains { $0.gitArgs?.starts(with: ["checkout"]) == true })
    }

    @Test("adopt checks out a stale local blob and leaves a novel one, calling noteNovel")
    func adoptStaleVsNovel() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        fake.on(["git", "init"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.on(["git", "hash-object", "-t", "tree"]) { _ in ProcResult(stdout: "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["reset", "-q", "--mixed", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        // Unsorted input on purpose — the implementation must sort before iterating.
        fake.onGit(["ls-files", "-z", "--modified"]) { _ in ProcResult(stdout: "novel.txt\0stale.txt", stderr: "", exitCode: 0) }
        fake.onGit(["hash-object", "stale.txt"]) { _ in ProcResult(stdout: "blobA\n", stderr: "", exitCode: 0) }
        fake.onGit(["log", "--all", "-n1", "--format=%H", "--find-object=blobA"]) { _ in ProcResult(stdout: "somesha\n", stderr: "", exitCode: 0) }
        fake.onGit(["hash-object", "novel.txt"]) { _ in ProcResult(stdout: "blobB\n", stderr: "", exitCode: 0) }
        fake.onGit(["log", "--all", "-n1", "--format=%H", "--find-object=blobB"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        // staleTest is only reached for a path that actually exists on disk (the normal case: a
        // file present in the index but absent from disk, the common shape on a checkout's very
        // first adopt, is skipped entirely and left for `receive` to materialize).
        try FileManager.default.createDirectory(atPath: root + "/c", withIntermediateDirectories: true)
        try "stale content".write(toFile: root + "/c/stale.txt", atomically: true, encoding: .utf8)
        try "novel content".write(toFile: root + "/c/novel.txt", atomically: true, encoding: .utf8)

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["stale.txt", "novel.txt"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in true })
        let noted = NotedBox()
        _ = try await store.attach(checkout: root + "/c", repo: root + "/r", declared: declared, noteNovel: { noted.append($0) })

        #expect(fake.calls.contains { $0.gitArgs?.starts(with: ["checkout", "--", "stale.txt"]) == true })
        #expect(!fake.calls.contains { $0.gitArgs?.starts(with: ["checkout", "--", "novel.txt"]) == true })
        #expect(noted.values == ["novel.txt"])
    }

    @Test("the first-attach decision runs under the per-repo seed key — two concurrent attaches on the same repo never both seed")
    func seedRaceSerializedPerRepo() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        fake.on(["git", "init"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.on(["git", "hash-object", "-t", "tree"]) { _ in ProcResult(stdout: "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["diff", "--cached", "--quiet"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        // Gate on the hermetic fetch call's exact argv prefix (Gate matches raw argv, not gitArgs).
        let hermeticFetchPrefix = ["git", "--attr-source=4b825dc642cb6eb9a060e54bf8d69288fbee4904"] + StoreGit.configPins + ["fetch"]
        let gate = fake.gate(on: hermeticFetchPrefix)

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })

        async let first: StoreHandle = store.attach(checkout: root + "/c1", repo: root + "/r", declared: declared)
        // Provably parked inside the first attach's seed-serialized closure (past the point where
        // seedChain[key] is already set to its Task) before starting the second — this is what
        // makes the ordering assertion below deterministic rather than a race itself.
        await gate.reached()

        // The SECOND attach's own responses (it runs only after the first's closure completes,
        // since both share the same seed-serialized key).
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["reset", "-q", "--mixed", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["ls-files", "-z", "--modified"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        async let second: StoreHandle = store.attach(checkout: root + "/c2", repo: root + "/r", declared: declared)

        // Release the first's fetch (exit 1 = absent main → it seeds; nothing staged → no push).
        gate.release(ProcResult(stdout: "", stderr: "fatal: couldn't find remote ref main", exitCode: 1))
        _ = try await first
        _ = try await second

        let pushIndex = fake.calls.firstIndex { $0.gitArgs?.starts(with: ["push"]) == true }
        let secondResetIndex = fake.calls.firstIndex { $0.gitArgs?.starts(with: ["reset", "-q", "--mixed"]) == true }
        // The second's `reset` call only exists because ITS OWN rev-parse saw store/main present —
        // which is only possible if the first's seed decision (which found store/main absent and
        // seeded, staging nothing) had already fully completed under the shared lock key. The
        // first seeded nothing (nothing was staged), so no push ever happened either.
        #expect(secondResetIndex != nil)
        #expect(pushIndex == nil)
    }

    @Test("a git call that fails to run (not merely exits non-zero) at a decision point throws, rather than being read as absent")
    func procFailureAtDecisionPointIsNotSilentlyAbsent() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        fake.on(["git", "init"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.on(["git", "hash-object", "-t", "tree"]) { _ in ProcResult(stdout: "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n", stderr: "", exitCode: 0) }
        // No rule for rev-parse HEAD — the throwing wrapper intercepts it before FakeProc sees it.
        let throwing = ThrowingOnPrefix(gitSubcommand: ["rev-parse", "--verify", "-q", "HEAD"], inner: fake)

        let store = SharedStore(root: root, proc: throwing)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })

        await #expect(throws: SharedStoreError.self) {
            _ = try await store.attach(checkout: root + "/c", repo: root + "/r", declared: declared)
        }
        #expect(!fake.calls.contains { $0.gitArgs?.starts(with: ["commit"]) == true })
        #expect(!fake.calls.contains { $0.gitArgs?.starts(with: ["push"]) == true })
    }
}

@Suite("SharedStore — a failed fetch is never read as an absent store main")
struct SharedStoreFetchFailureTests {
    @Test("receive throws gitFailed when fetch fails on a lock, instead of returning .upToDate")
    func receiveFetchLockThrows() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = StoreHandle(storeGitDir: root + "/store.git", checkoutGitDir: root + "/checkout.git",
                                 workTree: root + "/checkout", emptyTreeHash: "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "fatal: Unable to create '\(root)/checkout.git/refs/remotes/store/main.lock': File exists.", exitCode: 128) }
        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        await #expect(throws: SharedStoreError.self) {
            _ = try await store.receive(handle, paths: [], declared: declared)
        }
    }

    @Test("gitDirs is the one layout: store.git and checkouts/<hash>.git under the repo key")
    func gitDirsLayout() {
        let d = SharedStore.gitDirs(root: "/r", repo: "/repo", checkout: "/co")
        #expect(d.store == "/r/\(CardFileSpec.cwdHash("/repo"))/store.git")
        #expect(d.checkout == "/r/\(CardFileSpec.cwdHash("/repo"))/checkouts/\(CardFileSpec.cwdHash("/co")).git")
    }
}

/// Throws (rather than returning a `ProcResult`) for the one hermetic call whose stripped
/// subcommand matches `gitSubcommand`; delegates everything else to `inner`. Exists to prove a
/// genuine `proc.run` failure at a decision point is never silently read as "git said no".
private struct ThrowingOnPrefix: ProcRunning {
    let gitSubcommand: [String]
    let inner: FakeProc

    func run(_ argv: [String], cwd: String?, env: [String: String], timeout: Duration?) async throws -> ProcResult {
        if let stripped = FakeProc.strippedGitArgs(argv), stripped.starts(with: gitSubcommand) {
            throw OrchestraError.io("simulated proc failure")
        }
        return try await inner.run(argv, cwd: cwd, env: env, timeout: timeout)
    }
}

@Suite("SharedStore — receive")
struct SharedStoreReceiveTests {
    private func syntheticHandle(root: String) -> StoreHandle {
        StoreHandle(storeGitDir: root + "/store.git", checkoutGitDir: root + "/checkout.git",
                    workTree: root + "/checkout", emptyTreeHash: "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
    }

    @Test("receive on a merge-tree exit 1 returns the paths and store sha, and issues no checkout")
    func conflictChangesNothingOnDisk() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-base", "--is-ancestor", "Ssha", "Hsha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["merge-base", "--is-ancestor", "Hsha", "Ssha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", "Hsha", "Ssha"]) { _ in
            ProcResult(stdout: mergeTreeZ(["Tsha", "path1", "path2"]), stderr: "", exitCode: 1)
        }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.receive(handle, paths: [], declared: declared)

        if case .conflicted(let paths, let sha) = outcome {
            #expect(paths == ["path1", "path2"])
            #expect(sha == "Ssha")
        } else { Issue.record("expected .conflicted, got \(outcome)") }
        #expect(!fake.calls.contains { $0.gitArgs?.first == "checkout" })
    }

    @Test("receive writes out only leaves that are declared and ignored")
    func preMigrationCheckoutsStayClean() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-base", "--is-ancestor", "Ssha", "Hsha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["merge-base", "--is-ancestor", "Hsha", "Ssha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) } // fast-forward
        fake.onGit(["rev-parse", "Ssha^{tree}"]) { _ in ProcResult(stdout: "Tsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Tsha", "--", "tracked.md"]) { _ in ProcResult(stdout: "tracked.md\0", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Hsha", "--", "tracked.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        // IgnoreProbe.classify runs OUTSIDE StoreGit's hermetic env (plain `fake.on`, not `onGit`).
        fake.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        fake.on(["git", "check-ignore", "-q", "--", "tracked.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) } // still tracked, not ignored

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["tracked.md"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.receive(handle, paths: ["tracked.md"], declared: declared)

        if case .materialized(let written, let deleted) = outcome {
            #expect(written.isEmpty)
            #expect(deleted.isEmpty)
        } else { Issue.record("expected .materialized, got \(outcome)") }
        #expect(!fake.calls.contains { $0.gitArgs?.starts(with: ["checkout", "Tsha", "--", "tracked.md"]) == true })
    }

    @Test("receive with a dirty leaf issues no update-ref and no read-tree, and returns .partial")
    func headNeverMovesOverADirtyLeaf() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        // "dirty" must mean a REAL uncommitted local edit — a leaf differing from `h` only
        // because it's absent from disk is never dirty (see the `filter` comment in `writeOut`).
        try FileManager.default.createDirectory(atPath: handle.workTree, withIntermediateDirectories: true)
        try "uncommitted local edit".write(toFile: handle.workTree + "/a.md", atomically: true, encoding: .utf8)
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-base", "--is-ancestor", "Ssha", "Hsha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["merge-base", "--is-ancestor", "Hsha", "Ssha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "Ssha^{tree}"]) { _ in ProcResult(stdout: "Tsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Tsha", "--", "a.md"]) { _ in ProcResult(stdout: "a.md\0", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Hsha", "--", "a.md"]) { _ in ProcResult(stdout: "a.md\0", stderr: "", exitCode: 0) }
        fake.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        fake.on(["git", "check-ignore", "-q", "--", "a.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) } // ignored
        fake.onGitDiff(["--name-only", "-z", "Hsha", "--", "a.md"]) { _ in ProcResult(stdout: "a.md\0", stderr: "", exitCode: 0) } // dirty

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["a.md"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.receive(handle, paths: ["a.md"], declared: declared)

        if case .partial(let dirty) = outcome {
            #expect(dirty == ["a.md"])
        } else { Issue.record("expected .partial, got \(outcome)") }
        #expect(!fake.calls.contains { $0.gitArgs?.first == "update-ref" })
        #expect(!fake.calls.contains { $0.gitArgs?.first == "read-tree" })
    }

    @Test("receive issues update-ref HEAD only after every write-out call")
    func crashSafeOrder() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-base", "--is-ancestor", "Ssha", "Hsha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["merge-base", "--is-ancestor", "Hsha", "Ssha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "Ssha^{tree}"]) { _ in ProcResult(stdout: "Tsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Tsha", "--", "a.md", "b.md"]) { _ in ProcResult(stdout: "a.md\0b.md\0", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Hsha", "--", "a.md", "b.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        fake.on(["git", "check-ignore", "-q", "--", "a.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.on(["git", "check-ignore", "-q", "--", "b.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", "Hsha", "--"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) } // nothing dirty
        fake.onGitDiff(["--name-only", "-z", "Tsha", "--"]) { _ in ProcResult(stdout: "a.md\0b.md\0", stderr: "", exitCode: 0) }
        fake.onGit(["checkout", "Tsha", "--", "a.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["checkout", "Tsha", "--", "b.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["update-ref", "HEAD", "Ssha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["read-tree", "Tsha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["a.md", "b.md"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.receive(handle, paths: ["a.md", "b.md"], declared: declared)

        if case .materialized(let written, _) = outcome { #expect(Set(written) == ["a.md", "b.md"]) }
        else { Issue.record("expected .materialized, got \(outcome)") }
        let updateRefIndex = fake.calls.firstIndex { $0.gitArgs?.first == "update-ref" }
        let lastCheckoutIndex = fake.calls.lastIndex { $0.gitArgs?.first == "checkout" }
        #expect(updateRefIndex != nil && lastCheckoutIndex != nil && updateRefIndex! > lastCheckoutIndex!)
    }

    @Test("receive on unrelated histories re-adopts and retries once, then throws on a second 128")
    func lostSeedRaceReadoptsOnceThenThrows() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-base", "--is-ancestor", "Ssha", "Hsha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["merge-base", "--is-ancestor", "Hsha", "Ssha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", "Hsha", "Ssha"]) { _ in
            ProcResult(stdout: "", stderr: "fatal: refusing to merge unrelated histories", exitCode: 128)
        }
        fake.onGit(["reset", "-q", "--mixed", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        await #expect(throws: SharedStoreError.self) {
            _ = try await store.receive(handle, paths: [], declared: declared)
        }
        let mergeTreeCalls = fake.calls.filter { $0.gitArgs?.first == "merge-tree" }
        #expect(mergeTreeCalls.count == 2)
        #expect(fake.calls.contains { $0.gitArgs?.starts(with: ["reset", "-q", "--mixed"]) == true })
    }

    @Test("receive still materializes a leaf onto disk when HEAD already matches the store by history (the ADOPT-then-receive gap)")
    func materializesEvenWhenHistoryAlreadyUpToDate() async throws {
        // attach's ADOPT does `reset --mixed store/main`, which repoints HEAD to the store's
        // commit and updates the index — but never touches the working tree. A naive "S is
        // already an ancestor of H, therefore nothing to do" early return would then skip
        // write-out entirely, silently leaving the declared leaf absent from disk forever.
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        // HEAD already equals S (as ADOPT's reset --mixed leaves it).
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-base", "--is-ancestor", "Ssha", "Ssha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "Ssha^{tree}"]) { _ in ProcResult(stdout: "Tsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Tsha", "--", "a.md"]) { _ in ProcResult(stdout: "a.md\0", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Ssha", "--", "a.md"]) { _ in ProcResult(stdout: "a.md\0", stderr: "", exitCode: 0) }
        fake.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        fake.on(["git", "check-ignore", "-q", "--", "a.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", "Ssha", "--", "a.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) } // not dirty (absent, never edited)
        fake.onGitDiff(["--name-only", "-z", "Tsha", "--", "a.md"]) { _ in ProcResult(stdout: "a.md\0", stderr: "", exitCode: 0) } // missing from disk
        fake.onGit(["checkout", "Tsha", "--", "a.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["read-tree", "Tsha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["a.md"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.receive(handle, paths: ["a.md"], declared: declared)

        if case .materialized(let written, _) = outcome { #expect(written == ["a.md"]) }
        else { Issue.record("expected .materialized, got \(outcome)") }
        #expect(fake.calls.contains { $0.gitArgs?.starts(with: ["checkout", "Tsha", "--", "a.md"]) == true })
        // update-ref is skipped (M already equals HEAD), but read-tree still normalizes the index.
        #expect(!fake.calls.contains { $0.gitArgs?.first == "update-ref" })
        #expect(fake.calls.contains { $0.gitArgs?.first == "read-tree" })
    }

    @Test("receive returns .upToDate when history already matches AND the working tree already has everything")
    func trueUpToDateWhenDiskAlreadyMatches() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-base", "--is-ancestor", "Ssha", "Ssha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "Ssha^{tree}"]) { _ in ProcResult(stdout: "Tsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Tsha", "--", "a.md"]) { _ in ProcResult(stdout: "a.md\0", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Ssha", "--", "a.md"]) { _ in ProcResult(stdout: "a.md\0", stderr: "", exitCode: 0) }
        fake.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        fake.on(["git", "check-ignore", "-q", "--", "a.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", "Ssha", "--", "a.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", "Tsha", "--", "a.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) } // disk already matches T
        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["a.md"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.receive(handle, paths: ["a.md"], declared: declared)

        if case .upToDate = outcome {} else { Issue.record("expected .upToDate, got \(outcome)") }
        #expect(!fake.calls.contains { $0.gitArgs?.first == "update-ref" })
        #expect(!fake.calls.contains { $0.gitArgs?.first == "checkout" })
    }

    @Test("receive removes a declared, ignored leaf the merged tree deleted, keeping the index consistent")
    func storeSideDeletionsApplyAndIndexStaysConsistent() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        try FileManager.default.createDirectory(atPath: handle.workTree, withIntermediateDirectories: true)
        try "old content".write(toFile: handle.workTree + "/gone.md", atomically: true, encoding: .utf8)

        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-base", "--is-ancestor", "Ssha", "Hsha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["merge-base", "--is-ancestor", "Hsha", "Ssha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "Ssha^{tree}"]) { _ in ProcResult(stdout: "Tsha\n", stderr: "", exitCode: 0) }
        // gone.md is in H's tree but NOT in T's — the merge deleted it.
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Tsha", "--", "gone.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Hsha", "--", "gone.md"]) { _ in ProcResult(stdout: "gone.md\0", stderr: "", exitCode: 0) }
        fake.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        fake.on(["git", "check-ignore", "-q", "--", "gone.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", "Hsha", "--", "gone.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) } // clean
        fake.onGitDiff(["--name-only", "-z", "Tsha", "--", "gone.md"]) { _ in ProcResult(stdout: "gone.md\0", stderr: "", exitCode: 0) }
        fake.onGit(["update-ref", "HEAD", "Ssha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["read-tree", "Tsha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["gone.md"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.receive(handle, paths: ["gone.md"], declared: declared)

        if case .materialized(_, let deleted) = outcome { #expect(deleted == ["gone.md"]) }
        else { Issue.record("expected .materialized, got \(outcome)") }
        #expect(!FileManager.default.fileExists(atPath: handle.workTree + "/gone.md"))
        #expect(fake.calls.contains { $0.gitArgs?.starts(with: ["update-index", "--force-remove", "--", "gone.md"]) == true })
    }

    @Test("receive never runs ls-tree with no pathspec")
    func pollutedStoreCannotReachWorkingTree() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-base", "--is-ancestor", "Ssha", "Hsha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["merge-base", "--is-ancestor", "Hsha", "Ssha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "Ssha^{tree}"]) { _ in ProcResult(stdout: "Tsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Tsha", "--", "a.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Hsha", "--", "a.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["a.md"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        _ = try await store.receive(handle, paths: ["a.md"], declared: declared)

        let lsTreeCalls = fake.calls.filter { $0.gitArgs?.starts(with: ["ls-tree"]) == true }
        #expect(!lsTreeCalls.isEmpty)
        for call in lsTreeCalls {
            #expect(call.gitArgs?.contains("--") == true)
        }
    }
}

@Suite("SharedStore — send")
struct SharedStoreSendTests {
    private func syntheticHandle(root: String) -> StoreHandle {
        StoreHandle(storeGitDir: root + "/store.git", checkoutGitDir: root + "/checkout.git",
                    workTree: root + "/checkout", emptyTreeHash: "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
    }

    @Test("send with an out-of-set path in HEAD issues no push")
    func outOfSetGuardBlocksPush() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", handle.emptyTreeHash, "HEAD", "--"]) { _ in ProcResult(stdout: "rogue.md\0", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.send(handle, paths: [], declared: declared)

        #expect(!fake.calls.contains { $0.gitArgs?.first == "push" })
        if case .refusedOutOfSet(let p) = outcome { #expect(p == ["rogue.md"]) }
        else { Issue.record("expected .refusedOutOfSet, got \(outcome)") }
    }

    @Test("send with nothing committed returns .nothingToDo without pushing or querying out-of-set")
    func unbornHeadIsNothingToDoBeforeAnyGuardQuery() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.send(handle, paths: [], declared: declared)

        #expect(!fake.calls.contains { $0.gitArgs?.first == "push" })
        #expect(!fake.calls.contains { $0.gitArgs?.first == "diff" })
        if case .nothingToDo = outcome {} else { Issue.record("expected .nothingToDo, got \(outcome)") }
    }

    @Test("send retries a non-fast-forward rejection, then succeeds; stops after three")
    func retryThenSucceed() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", handle.emptyTreeHash, "HEAD", "--"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        var pushCount = 0
        fake.onGit(["push"]) { _ in
            pushCount += 1
            return pushCount == 1
                ? ProcResult(stdout: "", stderr: "! [rejected] main -> main (non-fast-forward)", exitCode: 1)
                : ProcResult(stdout: "", stderr: "", exitCode: 0)
        }
        // The internal receive() call must resolve .upToDate for the retry to proceed.
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-base", "--is-ancestor", "Hsha", "Hsha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) } // S == H → up to date

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.send(handle, paths: [], declared: declared)

        #expect(pushCount == 2)
        if case .pushed = outcome {} else { Issue.record("expected .pushed, got \(outcome)") }
    }

    @Test("send exhausts after three retries and throws")
    func retriesExhausted() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", handle.emptyTreeHash, "HEAD", "--"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["push"]) { _ in ProcResult(stdout: "", stderr: "! [rejected] main -> main (non-fast-forward)", exitCode: 1) }
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-base", "--is-ancestor", "Hsha", "Hsha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        await #expect(throws: SharedStoreError.self) {
            _ = try await store.send(handle, paths: [], declared: declared)
        }
        let pushCalls = fake.calls.filter { $0.gitArgs?.first == "push" }
        #expect(pushCalls.count == 3)
    }

    @Test("a push exiting 0 with Everything up-to-date is .nothingToDo, not .pushed")
    func pushNoopIsNothingToDo() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = syntheticHandle(root: root)
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", handle.emptyTreeHash, "HEAD", "--"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["push"]) { _ in ProcResult(stdout: "", stderr: "Everything up-to-date", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.send(handle, paths: [], declared: declared)

        if case .nothingToDo = outcome {} else { Issue.record("expected .nothingToDo, got \(outcome)") }
    }
}

@Suite("SharedStore — resolve")
struct SharedStoreResolveTests {
    private func syntheticHandle(root: String) throws -> StoreHandle {
        let handle = StoreHandle(storeGitDir: root + "/store.git", checkoutGitDir: root + "/checkout.git",
                                 workTree: root + "/checkout", emptyTreeHash: "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
        try FileManager.default.createDirectory(atPath: handle.checkoutGitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: handle.workTree, withIntermediateDirectories: true)
        return handle
    }

    @Test("resolve with no conflict returns .nothingToResolve and issues no commit-tree")
    func idempotentWhenNoConflict() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try syntheticHandle(root: root)
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", "Hsha", "Ssha"]) { _ in
            ProcResult(stdout: mergeTreeZ(["Tsha"]), stderr: "", exitCode: 0)
        }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.resolve(handle, paths: [], declared: declared)

        if case .nothingToResolve = outcome {} else { Issue.record("expected .nothingToResolve, got \(outcome)") }
        #expect(!fake.calls.contains { $0.gitArgs?.first == "commit-tree" })
    }

    @Test("resolve with no store/main yet returns .nothingToResolve without running merge-tree")
    func noStoreMainIsNothingToResolve() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try syntheticHandle(root: root)
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.resolve(handle, paths: [], declared: declared)

        if case .nothingToResolve = outcome {} else { Issue.record("expected .nothingToResolve, got \(outcome)") }
        #expect(!fake.calls.contains { $0.gitArgs?.first == "merge-tree" })
    }

    @Test("resolve refuses while ANY conflicted file holds a marker line, naming all offenders")
    func refusesUnresolvedMarkersCollectingAll() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try syntheticHandle(root: root)
        try "<<<<<<< HEAD\nmine\n=======\n".write(toFile: handle.workTree + "/a.md", atomically: true, encoding: .utf8)
        try ">>>>>>> store\ntheirs\n".write(toFile: handle.workTree + "/b.md", atomically: true, encoding: .utf8)
        try "clean content".write(toFile: handle.workTree + "/c.md", atomically: true, encoding: .utf8)
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", "Hsha", "Ssha"]) { _ in
            ProcResult(stdout: mergeTreeZ(["Tsha", "a.md", "b.md", "c.md"]), stderr: "", exitCode: 1)
        }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.resolve(handle, paths: [], declared: declared)

        if case .refusedMarkers(let paths) = outcome { #expect(paths == ["a.md", "b.md"]) }
        else { Issue.record("expected .refusedMarkers, got \(outcome)") }
        #expect(!fake.calls.contains { $0.gitArgs?.first == "commit-tree" })
    }

    @Test("resolve does not throw on a non-UTF8 conflicted file — scans bytes, not a UTF8 String read")
    func binaryConflictedFileDoesNotThrow() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try syntheticHandle(root: root)
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: URL(fileURLWithPath: handle.workTree + "/bin.dat"))
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", "Hsha", "Ssha"]) { _ in
            ProcResult(stdout: mergeTreeZ(["Tsha", "bin.dat"]), stderr: "", exitCode: 1)
        }
        fake.onGit(["read-tree"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["add", "-f"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["write-tree"]) { _ in ProcResult(stdout: "T2sha\n", stderr: "", exitCode: 0) }
        fake.onGit(["commit-tree"]) { _ in ProcResult(stdout: "Msha\n", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "T2sha", "--", "bin.dat"]) { _ in ProcResult(stdout: "bin.dat\0", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Hsha", "--", "bin.dat"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        fake.on(["git", "check-ignore", "-q", "--", "bin.dat"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", "Hsha", "--", "bin.dat"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["update-ref", "HEAD", "Msha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["read-tree", "T2sha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", handle.emptyTreeHash, "HEAD", "--"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["push"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["bin.dat"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        // Must not throw.
        _ = try await store.resolve(handle, paths: ["bin.dat"], declared: declared)
    }

    @Test("resolve does not read through a symlink at a conflicted path when checking for markers")
    func symlinkNotFollowedDuringMarkerCheck() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try syntheticHandle(root: root)
        let target = root + "/target-with-markers.md"
        try "<<<<<<< HEAD\nmarkers here\n".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: handle.workTree + "/link.md", withDestinationPath: target)

        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", "Hsha", "Ssha"]) { _ in
            ProcResult(stdout: mergeTreeZ(["Tsha", "link.md"]), stderr: "", exitCode: 1)
        }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        // Should NOT refuse on markers (the symlink itself has no text lines) — it should proceed
        // past the marker check to the temp-index step (whose calls aren't fully scripted here, so
        // just assert it did not take the refusedMarkers path).
        let outcome = try? await store.resolve(handle, paths: [], declared: declared)
        if case .refusedMarkers = outcome { Issue.record("must not refuse on markers found through a symlink") }
    }

    @Test("resolve excludes the conflicted paths from the dirty check — the always-dirty-by-construction fix")
    func conflictedPathsNeverCountAsDirty() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try syntheticHandle(root: root)
        try "reconciled content".write(toFile: handle.workTree + "/x.md", atomically: true, encoding: .utf8)
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", "Hsha", "Ssha"]) { _ in
            ProcResult(stdout: mergeTreeZ(["Tsha", "x.md"]), stderr: "", exitCode: 1)
        }
        fake.onGit(["read-tree"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["add", "-f"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["write-tree"]) { _ in ProcResult(stdout: "T2sha\n", stderr: "", exitCode: 0) }
        fake.onGit(["commit-tree"]) { _ in ProcResult(stdout: "Msha\n", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "T2sha", "--", "x.md"]) { _ in ProcResult(stdout: "x.md\0", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Hsha", "--", "x.md"]) { _ in ProcResult(stdout: "x.md\0", stderr: "", exitCode: 0) }
        fake.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        fake.on(["git", "check-ignore", "-q", "--", "x.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        // x.md IS dirty against H (by construction — the agent's uncommitted reconciliation edit).
        fake.onGitDiff(["--name-only", "-z", "Hsha", "--", "x.md"]) { _ in ProcResult(stdout: "x.md\0", stderr: "", exitCode: 0) }
        fake.onGit(["update-ref", "HEAD", "Msha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["read-tree", "T2sha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", handle.emptyTreeHash, "HEAD", "--"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["push"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["x.md"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.resolve(handle, paths: ["x.md"], declared: declared)

        // Must reach .resolved (step 6), NOT .sendOutcome(.partial(["x.md"])) — this is the
        // concrete proof the BLOCKER 3 fix works: x.md is genuinely dirty against H, but it's
        // EXCLUDED from the dirty check because it's a just-resolved conflicted path.
        if case .resolved = outcome {} else { Issue.record("expected .resolved, got \(outcome)") }
    }

    @Test("resolve stages every conflicted path into a temporary index and writes a commit with HEAD and store/main as parents, cleaning up the temp index")
    func resolutionIsARealMerge() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try syntheticHandle(root: root)
        try "clean a".write(toFile: handle.workTree + "/a.md", atomically: true, encoding: .utf8)
        try "clean b".write(toFile: handle.workTree + "/b.md", atomically: true, encoding: .utf8)
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", "Hsha", "Ssha"]) { _ in
            ProcResult(stdout: mergeTreeZ(["Tsha", "a.md", "b.md"]), stderr: "", exitCode: 1)
        }
        fake.onGit(["read-tree"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["add", "-f"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["write-tree"]) { _ in ProcResult(stdout: "T2sha\n", stderr: "", exitCode: 0) }
        fake.onGit(["commit-tree"]) { _ in ProcResult(stdout: "Msha\n", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "T2sha", "--", "a.md", "b.md"]) { _ in ProcResult(stdout: "a.md\0b.md\0", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Hsha", "--", "a.md", "b.md"]) { _ in ProcResult(stdout: "a.md\0b.md\0", stderr: "", exitCode: 0) }
        fake.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        fake.on(["git", "check-ignore", "-q", "--", "a.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.on(["git", "check-ignore", "-q", "--", "b.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", "Hsha", "--"]) { _ in ProcResult(stdout: "a.md\0b.md\0", stderr: "", exitCode: 0) }
        fake.onGit(["update-ref", "HEAD", "Msha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["read-tree", "T2sha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", handle.emptyTreeHash, "HEAD", "--"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["push"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["a.md", "b.md"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.resolve(handle, paths: ["a.md", "b.md"], declared: declared)

        if case .resolved = outcome {} else { Issue.record("expected .resolved, got \(outcome)") }
        #expect(fake.calls.contains { $0.gitArgs?.starts(with: ["commit-tree", "T2sha", "-p", "Hsha", "-p", "Ssha"]) == true })
        #expect(!FileManager.default.fileExists(atPath: handle.checkoutGitDir + "/resolve-index"))
    }

    @Test("resolve of a symlinked conflicted path never dereferences it itself before add -f")
    func symlinkStoredAsLinkNeverFollowed() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try syntheticHandle(root: root)
        let target = root + "/real-content.md"
        try "real secret content".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: handle.workTree + "/link.md", withDestinationPath: target)

        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "HEAD"]) { _ in ProcResult(stdout: "Hsha\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "Ssha\n", stderr: "", exitCode: 0) }
        fake.onGit(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", "Hsha", "Ssha"]) { _ in
            ProcResult(stdout: mergeTreeZ(["Tsha", "link.md"]), stderr: "", exitCode: 1)
        }
        fake.onGit(["read-tree"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["add", "-f"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["write-tree"]) { _ in ProcResult(stdout: "T2sha\n", stderr: "", exitCode: 0) }
        fake.onGit(["commit-tree"]) { _ in ProcResult(stdout: "Msha\n", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "T2sha", "--", "link.md"]) { _ in ProcResult(stdout: "link.md\0", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "Hsha", "--", "link.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        fake.on(["git", "check-ignore", "-q", "--", "link.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", "Hsha", "--", "link.md"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["update-ref", "HEAD", "Msha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["read-tree", "T2sha"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--name-only", "-z", handle.emptyTreeHash, "HEAD", "--"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["push"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["link.md"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        _ = try await store.resolve(handle, paths: ["link.md"], declared: declared)

        #expect(fake.calls.contains { $0.gitArgs?.starts(with: ["add", "-f", "--", "link.md"]) == true })
    }
}

@Suite("SharedStore — commitLocal")
struct SharedStoreCommitLocalTests {
    /// Attaches a fresh handle whose HEAD already exists (skips the seed/adopt branch entirely,
    /// so each commitLocal test only exercises commitLocal's own logic). `headExists` scripts the
    /// bootstrap rev-parse to succeed immediately.
    private func attachedHandle(root: String, fake: FakeProc, checkout: String = "/c", repo: String = "/r") async throws -> StoreHandle {
        fake.on(["git", "init"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.on(["git", "hash-object", "-t", "tree"]) { _ in ProcResult(stdout: "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        return try await store.attach(checkout: root + checkout, repo: root + repo, declared: declared)
    }

    @Test("commitLocal writes the current un-ignored leaves to orchestra-unignored")
    func commitLocalWritesUnignoredRecord() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try await attachedHandle(root: root, fake: fake)
        fake.onGitDiff(["--cached", "--name-only", "-z", "--diff-filter=D"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--cached", "--name-only", "-z"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["diff", "--cached", "--quiet"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        _ = try await store.commitLocal(handle, declared: declared, unignoredLeaves: ["b.md", "a.md"])

        let recorded = try String(contentsOfFile: handle.checkoutGitDir + "/orchestra-unignored", encoding: .utf8)
        #expect(recorded == "a.md\nb.md")
    }

    @Test("a leaf listed in orchestra-unignored and ignored now gets the stale test; a modified leaf not listed does not")
    func flipTestIsScoped() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try await attachedHandle(root: root, fake: fake)
        try "flip.md".write(toFile: handle.checkoutGitDir + "/orchestra-unignored", atomically: true, encoding: .utf8)
        // staleTest short-circuits false for a path absent from disk — the flip test must exercise
        // a leaf that genuinely exists in the working tree to reach the checkout it asserts below.
        try FileManager.default.createDirectory(atPath: handle.workTree, withIntermediateDirectories: true)
        try "stale local content".write(toFile: handle.workTree + "/flip.md", atomically: true, encoding: .utf8)
        fake.onGitDiff(["--name-only", "HEAD", "--", "flip.md"]) { _ in ProcResult(stdout: "flip.md\n", stderr: "", exitCode: 0) }
        fake.onGit(["hash-object", "flip.md"]) { _ in ProcResult(stdout: "blobF\n", stderr: "", exitCode: 0) }
        fake.onGit(["log", "--all", "-n1", "--format=%H", "--find-object=blobF"]) { _ in ProcResult(stdout: "somesha\n", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--cached", "--name-only", "-z", "--diff-filter=D"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--cached", "--name-only", "-z"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["diff", "--cached", "--quiet"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        _ = try await store.commitLocal(handle, declared: declared, unignoredLeaves: [])

        #expect(fake.calls.contains { $0.gitArgs?.starts(with: ["checkout", "--", "flip.md"]) == true })
        #expect(!fake.calls.contains { $0.gitArgs?.starts(with: ["diff", "--name-only", "HEAD", "--", "other.md"]) == true })
    }

    @Test("the flip test is skipped entirely when HEAD is unborn")
    func flipTestSkippedOnUnbornHead() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        fake.on(["git", "init"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.on(["git", "hash-object", "-t", "tree"]) { _ in ProcResult(stdout: "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "--verify", "-q", "HEAD"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["fetch"]) { _ in ProcResult(stdout: "", stderr: "fatal: couldn't find remote ref main", exitCode: 1) }
        fake.onGit(["rev-parse", "--verify", "-q", "refs/remotes/store/main"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["diff", "--cached", "--quiet"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        let store0 = SharedStore(root: root, proc: fake)
        let declared0 = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let handle = try await store0.attach(checkout: root + "/c", repo: root + "/r", declared: declared0)
        try "flip.md".write(toFile: handle.checkoutGitDir + "/orchestra-unignored", atomically: true, encoding: .utf8)

        // rev-parse HEAD still fails (unborn) for the commitLocal call that follows.
        fake.onGitDiff(["--cached", "--name-only", "-z", "--diff-filter=D"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--cached", "--name-only", "-z"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        _ = try await store0.commitLocal(handle, declared: declared0, unignoredLeaves: [])

        #expect(!fake.calls.contains { $0.gitArgs?.starts(with: ["diff", "--name-only", "HEAD"]) == true })
        #expect(!fake.calls.contains { $0.gitArgs?.starts(with: ["hash-object", "flip.md"]) == true })
    }

    @Test("commitLocal preserves a deletion made by removing the file and staging it")
    func deliberateDeletionPreserved() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try await attachedHandle(root: root, fake: fake)
        // The outside-query call (a LONGER prefix with a trailing "--") must be registered before
        // the bare staged-list rule, or FakeProc's prefix match would apply the staged-list's
        // "gone.md" answer to the outside-query too, wrongly flagging it as stray.
        fake.onGitDiff(["--cached", "--name-only", "-z", "--", ":(top)"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--cached", "--name-only", "-z", "--diff-filter=D"]) { _ in ProcResult(stdout: "gone.md\0", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--cached", "--name-only", "-z"]) { _ in ProcResult(stdout: "gone.md\0", stderr: "", exitCode: 0) }
        fake.onGit(["diff", "--cached", "--quiet"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        fake.onGit(["commit", "-q", "-m"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["rev-parse", "HEAD"]) { _ in ProcResult(stdout: "deadbeef\n", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        _ = try await store.commitLocal(handle, declared: declared, unignoredLeaves: [])

        #expect(!fake.calls.contains { $0.gitArgs?.starts(with: ["restore", "--staged", "--", "gone.md"]) == true })
    }

    @Test("commitLocal unstages and re-materializes a deletion add -f introduced")
    func noInferredDeletion() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try await attachedHandle(root: root, fake: fake)
        var callCount = 0
        fake.onGitDiff(["--cached", "--name-only", "-z", "--diff-filter=D"]) { _ in            callCount += 1
            // pre (before add -f): empty. new (after add -f): "absent.md" — the declared positive
            // didn't exist, so `add -f` staged its removal.
            return ProcResult(stdout: callCount == 1 ? "" : "absent.md\0", stderr: "", exitCode: 0)
        }
        fake.onGit(["add", "-f"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--cached", "--name-only", "-z"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["diff", "--cached", "--quiet"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        // unstage() queries HEAD membership to pick restore vs force-remove — absent.md IS in HEAD.
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "HEAD", "--", "absent.md"]) { _ in ProcResult(stdout: "absent.md\0", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["absent.md"], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in true })
        _ = try await store.commitLocal(handle, declared: declared, unignoredLeaves: [])

        #expect(fake.calls.contains { $0.gitArgs?.starts(with: ["restore", "--staged", "--", "absent.md"]) == true })
        #expect(fake.calls.contains { $0.gitArgs?.starts(with: ["checkout", "--", "absent.md"]) == true })
    }

    @Test("commitLocal unstages a staged path outside the declared set, and one inside an exclusion")
    func strayUnstaged() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try await attachedHandle(root: root, fake: fake)
        fake.onGitDiff(["--cached", "--name-only", "-z", "--diff-filter=D"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--cached", "--name-only", "-z", "--"]) { argv in            // Distinguish the outside-query call from the holes-query call by inspecting argv tail.
            if argv.contains(":(top)") { return ProcResult(stdout: "rogue.md\0", stderr: "", exitCode: 0) }
            if argv.contains("hole.md") { return ProcResult(stdout: "hole.md\0", stderr: "", exitCode: 0) }
            return nil
        }
        fake.onGitDiff(["--cached", "--name-only", "-z"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["diff", "--cached", "--quiet"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        // unstage() queries HEAD membership — both stray paths are already in HEAD, so both go
        // through `restore --staged`, not `update-index --force-remove`.
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "HEAD", "--", "hole.md", "rogue.md"]) { _ in ProcResult(stdout: "hole.md\0rogue.md\0", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: ["dir"], exclusions: ["hole.md"], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in true })
        let outcome = try await store.commitLocal(handle, declared: declared, unignoredLeaves: [])

        #expect(fake.calls.contains { call in
            guard let g = call.gitArgs, g.starts(with: ["restore", "--staged", "--"]) else { return false }
            return Set(g.dropFirst(3)) == ["hole.md", "rogue.md"]
        })
        if case .nothingToCommit(let warnings) = outcome {
            #expect(warnings.contains { if case .strayUnstaged(let p) = $0 { return Set(p) == ["hole.md", "rogue.md"] } else { return false } })
        } else {
            Issue.record("expected .nothingToCommit")
        }
    }

    @Test("commitLocal unstages a file over 5 MiB and drops a gitlink")
    func sizeAndGitlinkGuards() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try await attachedHandle(root: root, fake: fake)
        try FileManager.default.createDirectory(atPath: handle.workTree, withIntermediateDirectories: true)
        let bigData = Data(repeating: 0, count: 6_000_000)
        try bigData.write(to: URL(fileURLWithPath: handle.workTree + "/big.bin"))

        fake.onGitDiff(["--cached", "--name-only", "-z", "--diff-filter=D"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        // The outside-query call must be registered before the bare staged-list rule (see the
        // deliberateDeletionPreserved test's comment for why) — otherwise big.bin/link would be
        // wrongly flagged as stray and restored before ever reaching the size/gitlink guards.
        fake.onGitDiff(["--cached", "--name-only", "-z", "--", ":(top)"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--cached", "--name-only", "-z"]) { _ in ProcResult(stdout: "big.bin\0link\0", stderr: "", exitCode: 0) }
        fake.onGit(["ls-files", "--stage", "--", "link"]) { _ in ProcResult(stdout: "160000 abc123 0\tlink\n", stderr: "", exitCode: 0) }
        fake.onGit(["ls-files", "--stage", "--", "big.bin"]) { _ in ProcResult(stdout: "100644 def456 0\tbig.bin\n", stderr: "", exitCode: 0) }
        fake.onGit(["diff", "--cached", "--quiet"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        // unstage() queries HEAD membership per path: big.bin is already in HEAD (restore --staged
        // resets it back); link is a gitlink just staged and never committed (not in HEAD — `git rm
        // --cached`/`restore --staged` both refuse there, so it goes through force-remove instead).
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "HEAD", "--", "big.bin"]) { _ in ProcResult(stdout: "big.bin\0", stderr: "", exitCode: 0) }
        fake.onGit(["ls-tree", "-r", "--name-only", "-z", "HEAD", "--", "link"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.commitLocal(handle, declared: declared, unignoredLeaves: [])

        #expect(fake.calls.contains { $0.gitArgs?.starts(with: ["restore", "--staged", "--", "big.bin"]) == true })
        #expect(fake.calls.contains { $0.gitArgs?.starts(with: ["update-index", "--force-remove", "--", "link"]) == true })
        if case .nothingToCommit(let warnings) = outcome {
            #expect(warnings.contains { if case .oversized(let p) = $0 { return p == "big.bin" } else { return false } })
            #expect(warnings.contains { if case .gitlink(let p) = $0 { return p == "link" } else { return false } })
        } else {
            Issue.record("expected .nothingToCommit")
        }
    }

    @Test("commit only when diff --cached --quiet exits non-zero")
    func noCommitWhenNothingStaged() async throws {
        let root = freshRoot()
        let fake = FakeProc()
        let handle = try await attachedHandle(root: root, fake: fake)
        fake.onGitDiff(["--cached", "--name-only", "-z", "--diff-filter=D"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGitDiff(["--cached", "--name-only", "-z"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        fake.onGit(["diff", "--cached", "--quiet"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let store = SharedStore(root: root, proc: fake)
        let declared = DeclaredSet.build(paths: [], exclusions: [], unignoredLeaves: [], existsInWorkingTreeOrIndex: { _ in false })
        let outcome = try await store.commitLocal(handle, declared: declared, unignoredLeaves: [])

        #expect(!fake.calls.contains { $0.gitArgs?.starts(with: ["commit"]) == true })
        if case .nothingToCommit = outcome {} else { Issue.record("expected .nothingToCommit") }
    }
}
