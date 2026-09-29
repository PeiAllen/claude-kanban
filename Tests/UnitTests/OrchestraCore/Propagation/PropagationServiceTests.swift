import Foundation
import Testing
import TestSupport
import OrchestraKit
@testable import OrchestraCore

// MARK: - Fakes

/// Records every store call in order and lets a test park one at a gate. Scripted per op.
private final class FakeStore: SharedStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _receivePaths: [[String]] = []
    private var _declared: [DeclaredSet.Result] = []
    private var gates: [String: Gate] = [:]
    var commit: @Sendable (Int) throws -> CommitOutcome = { _ in .nothingToCommit(warnings: []) }
    var receive: @Sendable (String) throws -> ReceiveOutcome = { _ in .upToDate }
    var send: @Sendable (String) throws -> SendOutcome = { _ in .nothingToDo }
    var resolveResult: @Sendable () throws -> ResolveOutcome = { .resolved }
    private var commitCalls = 0

    var log: [String] { lock.withLock { _log } }
    var receivePaths: [[String]] { lock.withLock { _receivePaths } }
    var declaredSeen: [DeclaredSet.Result] { lock.withLock { _declared } }
    func gate(_ key: String) -> Gate { let g = Gate(); lock.withLock { gates[key] = g }; return g }
    private func enter(_ key: String) async {
        let g: Gate? = lock.withLock { _log.append(key); return gates[key] }
        if let g { _ = await g.park() }
    }

    func attach(checkout: String, repo: String, declared: DeclaredSet.Result, noteNovel: (@Sendable (String) -> Void)?) async throws -> StoreHandle {
        await enter("attach:" + last(checkout))
        let d = SharedStore.gitDirs(root: "/fake", repo: repo, checkout: checkout)
        return StoreHandle(storeGitDir: d.store, checkoutGitDir: d.checkout, workTree: checkout, emptyTreeHash: "e")
    }
    func commitLocal(_ handle: StoreHandle, declared: DeclaredSet.Result, unignoredLeaves: Set<String>) async throws -> CommitOutcome {
        lock.withLock { _declared.append(declared) }
        await enter("commit:" + last(handle.workTree))
        let n = lock.withLock { commitCalls += 1; return commitCalls }
        return try commit(n)
    }
    func receive(_ handle: StoreHandle, paths: [String], declared: DeclaredSet.Result) async throws -> ReceiveOutcome {
        lock.withLock { _receivePaths.append(paths) }
        await enter("receive:" + last(handle.workTree))
        return try receive(handle.workTree)
    }
    func send(_ handle: StoreHandle, paths: [String], declared: DeclaredSet.Result) async throws -> SendOutcome {
        await enter("send:" + last(handle.workTree))
        return try send(handle.workTree)
    }
    func resolve(_ handle: StoreHandle, paths: [String], declared: DeclaredSet.Result) async throws -> ResolveOutcome {
        await enter("resolve:" + last(handle.workTree))
        return try resolveResult()
    }
    private func last(_ p: String) -> String { (p as NSString).lastPathComponent }
}

private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var _warnings: [String] = []
    private var _notices: [(UUID, String, String)] = []
    var warnings: [String] { lock.withLock { _warnings } }
    var notices: [(UUID, String, String)] { lock.withLock { _notices } }
    func warn(_ t: String) { lock.withLock { _warnings.append(t) } }
    func notify(_ c: UUID, _ t: String, _ k: String) { lock.withLock { _notices.append((c, t, k)) } }
}

private let claudeItem = PropagationItem(name: "claude", paths: ["CLAUDE.md"], exclusions: [])
private let codexItem = PropagationItem(name: "codex", paths: ["AGENTS.md"], exclusions: [])

/// A private world per test: temp base (canonical), store root, policy file, a primary repo dir and worktrees.
private final class Env: @unchecked Sendable {
    let base: String, root: String, policyPath: String, primary: String
    let proc = FakeProc()
    let store = FakeStore()
    let sink = Sink()
    let service: PropagationService

    init(items: [PropagationItem] = [claudeItem]) async throws {
        base = PathResolver.canonical(NSTemporaryDirectory() + "orch-prop-svc-\(UUID().uuidString)")
        root = base + "/shared"
        policyPath = base + "/propagation.json"
        primary = base + "/repo"
        try FileManager.default.createDirectory(atPath: primary, withIntermediateDirectories: true)
        proc.on(["git", "version"]) { _ in ProcResult(stdout: "git version 2.50.1\n", stderr: "", exitCode: 0) }
        proc.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        let s = store
        service = PropagationService(store: s, proc: proc, resolver: PathResolver(allowedRoots: [base]),
                                     root: root, policyPath: policyPath, adapterItems: { items })
        let sink = self.sink
        await service.setSinks(notify: { sink.notify($0, $1, $2) }, warn: { sink.warn($0) })
    }

    func worktree(_ name: String, files: [String] = ["CLAUDE.md"]) throws -> String {
        let wt = base + "/" + name
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        for f in files {
            let path = wt + "/" + f
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
        }
        return wt
    }

    func card(_ cwd: String, origin: CardOrigin = .worktree, access: CardAccess = .readWrite, epoch: Int = 1) -> OrchestraKit.Task {
        OrchestraKit.Task(title: "c", repo: primary, branch: "b", cwd: cwd, origin: origin, access: access,
                          model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0,
                          sessionEpoch: epoch, initialPrompt: "")
    }

    func gitDir(for checkout: String) -> String { SharedStore.gitDirs(root: root, repo: primary, checkout: checkout).checkout }

    func setPolicy(_ policy: PropagationRepoPolicy) {
        #expect(PropagationStore.save([primary: policy], path: policyPath))
    }

    func cardCalls() -> [FakeProc.Call] { proc.calls.filter { $0.cwd != nil } }
}

// MARK: - Serialization

@Suite("PropagationService — serialization")
struct PropagationServiceSerializationTests {
    @Test("a second sync on the same checkout issues no store call until the first is released")
    func perCheckoutSerialization() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let gate = env.store.gate("commit:wt")
        let card = env.card(wt)
        let first = _Concurrency.Task { await env.service.sync(wt, card, .full) }
        await gate.reached()
        let second = _Concurrency.Task { await env.service.sync(wt, card, .full) }
        await yieldBriefly()
        #expect(env.store.log.filter { $0 == "attach:wt" }.count == 1)
        gate.release()
        _ = await first.value; _ = await second.value
        #expect(env.store.log.filter { $0 == "attach:wt" }.count == 2)
    }

    @Test("syncs on two checkouts proceed while one is parked — no global lock")
    func noGlobalLock() async throws {
        let env = try await Env()
        let wt1 = try env.worktree("wt1"), wt2 = try env.worktree("wt2")
        let gate = env.store.gate("commit:wt1")
        let t1 = _Concurrency.Task { await env.service.sync(wt1, env.card(wt1), .full) }
        await gate.reached()
        let outcome = await env.service.sync(wt2, env.card(wt2), .full)
        #expect(outcome == .completed(receive: .upToDate, send: .nothingToDo))
        gate.release()
        _ = await t1.value
    }

    @Test("a second checkout's store work waits behind the first checkout's parked send — one store chain per repo")
    func storeChainSerializesSends() async throws {
        let env = try await Env()
        let wt1 = try env.worktree("wt1"), wt2 = try env.worktree("wt2")
        let gate = env.store.gate("send:wt1")
        let t1 = _Concurrency.Task { await env.service.sync(wt1, env.card(wt1), .full) }
        await gate.reached()
        let t2 = _Concurrency.Task { await env.service.sync(wt2, env.card(wt2), .full) }
        await yieldBriefly()
        #expect(!env.store.log.contains("send:wt2"))
        gate.release()
        _ = await t1.value; _ = await t2.value
        #expect(env.store.log.contains("send:wt2"))
    }

    @Test("the generation counter never resets: an entry cleared and recreated gets a fresh, larger generation")
    func monotonicGeneration() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let gate = env.store.gate("commit:wt")
        let a = _Concurrency.Task { await env.service.sync(wt, env.card(wt), .full) }
        await gate.reached()
        let b = _Concurrency.Task { await env.service.sync(wt, env.card(wt), .full) }
        await yieldBriefly()
        let during = await env.service.chainSnapshot()
        #expect(during.keys.contains("checkout:" + wt))
        gate.release()
        _ = await a.value; _ = await b.value
        let after = await env.service.chainSnapshot()
        #expect(after.keys.isEmpty)
        _ = await env.service.sync(wt, env.card(wt), .full)
        let later = await env.service.chainSnapshot()
        #expect(later.keys.isEmpty)
        #expect(later.nextGeneration > after.nextGeneration)
        #expect(after.nextGeneration >= 2)
    }
}

// MARK: - sync

@Suite("PropagationService — sync")
struct PropagationServiceSyncTests {
    @Test("every primary git call precedes the card's first git call on a launch sync")
    func primaryFirst() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        _ = await env.service.sync(wt, env.card(wt), .receiveOnly)
        let calls = env.cardCalls()
        let firstPrimary = calls.firstIndex { $0.cwd == env.primary }
        let firstCard = calls.firstIndex { $0.cwd == wt }
        #expect(firstPrimary != nil && firstCard != nil)
        #expect(try #require(firstPrimary) < (try #require(firstCard)))
        let log = env.store.log
        #expect(try #require(log.firstIndex(of: "attach:repo")) < (try #require(log.firstIndex(of: "attach:wt"))))
        #expect(!log.contains("send:wt"))   // launch sync is receive-only for the card
    }

    @Test("a git dir holding MERGE_HEAD issues no store call — a merge in progress is never committed")
    func mergeHeadStandDown() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let dir = env.gitDir(for: wt)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "x".write(toFile: dir + "/MERGE_HEAD", atomically: true, encoding: .utf8)
        let outcome = await env.service.sync(wt, env.card(wt), .full)
        #expect(outcome == .standDown(.mergeInProgress))
        #expect(env.store.log.isEmpty)
    }

    @Test("a .partial receive issues no send")
    func partialNoSend() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        env.store.receive = { _ in .partial(dirty: ["CLAUDE.md"]) }
        let outcome = await env.service.sync(wt, env.card(wt), .full)
        #expect(outcome == .partial(dirty: ["CLAUDE.md"]))
        #expect(!env.store.log.contains("send:wt"))
        #expect(env.sink.warnings.contains { $0.contains("CLAUDE.md") })
    }

    @Test("a read-only card receives and never sends")
    func readOnlyNoSend() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let outcome = await env.service.sync(wt, env.card(wt, access: .readOnly), .full)
        #expect(outcome == .completed(receive: .upToDate, send: nil))
        #expect(!env.store.log.contains("send:wt"))
    }

    @Test("a refused out-of-set send warns naming the paths")
    func refusedOutOfSetWarns() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        env.store.send = { _ in .refusedOutOfSet(paths: ["secret.txt"]) }
        let outcome = await env.service.sync(wt, env.card(wt), .full)
        #expect(outcome == .refusedOutOfSet(paths: ["secret.txt"]))
        #expect(env.sink.warnings.contains { $0.contains("secret.txt") })
    }

    @Test("receive/send get the declared paths of every shared item, from ALL adapters; none shared means no store call")
    func pathsArgument() async throws {
        let env = try await Env(items: [claudeItem, codexItem])
        let wt = try env.worktree("wt", files: ["CLAUDE.md", "AGENTS.md"])
        _ = await env.service.sync(wt, env.card(wt), .full)
        #expect(env.store.receivePaths == [["AGENTS.md", "CLAUDE.md"]])

        let empty = try await Env(items: [])
        let wt2 = try empty.worktree("wt")
        let outcome = await empty.service.sync(wt2, empty.card(wt2), .full)
        #expect(outcome == .nothingShared)
        #expect(empty.store.log.isEmpty)
    }

    @Test("a scratch card and a directory outside any repo are skipped without a store call")
    func ineligibleSkipped() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        #expect(await env.service.sync(wt, env.card(wt, origin: .scratch), .full) == .skipped(.ineligible))
        env.proc.on(["git", "rev-parse", "--show-toplevel"]) { _ in ProcResult(stdout: "", stderr: "fatal", exitCode: 128) }
        #expect(await env.service.sync(wt, env.card(wt, origin: .borrowed), .full) == .skipped(.ineligible))
        #expect(env.store.log.isEmpty)
    }

    @Test("a borrowed card in a secondary worktree resolves its primary from the git common dir")
    func borrowedResolvesPrimary() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        env.proc.on(["git", "rev-parse", "--show-toplevel"]) { _ in
            ProcResult(stdout: "\(wt)\n\(env.primary)/.git\n", stderr: "", exitCode: 0)
        }
        let outcome = await env.service.sync(wt, env.card(wt, origin: .borrowed), .full)
        #expect(outcome == .completed(receive: .upToDate, send: .nothingToDo))
    }

    @Test("an un-ignored leaf notices once per launch; one absent from checkout and store is silent")
    func unignoredNoticeOncePerLaunch() async throws {
        let env = try await Env()
        env.proc.on(["git", "check-ignore"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        let wt = try env.worktree("wt")
        _ = await env.service.sync(wt, env.card(wt, epoch: 1), .full)
        _ = await env.service.sync(wt, env.card(wt, epoch: 1), .full)
        #expect(env.sink.notices.count == 1)
        _ = await env.service.sync(wt, env.card(wt, epoch: 2), .full)
        #expect(env.sink.notices.count == 2)

        let quiet = try await Env()
        quiet.proc.on(["git", "check-ignore"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        let bare = try quiet.worktree("bare", files: [])
        _ = await quiet.service.sync(bare, quiet.card(bare), .full)
        #expect(quiet.sink.notices.isEmpty)
    }

    @Test("a declared directory is never itself un-ignored: its ignored children stay staged, only the un-ignored child stands down")
    func directoryChildrenStandDownIndividually() async throws {
        let dirItem = PropagationItem(name: "claude", paths: [".claude"], exclusions: [])
        let env = try await Env(items: [dirItem])
        env.proc.on(["git", "check-ignore"]) { argv in
            argv.last == ".claude/b.md" ? ProcResult(stdout: "", stderr: "", exitCode: 1) : nil
        }
        let wt = try env.worktree("wt", files: [".claude/a.md", ".claude/b.md"])
        _ = await env.service.sync(wt, env.card(wt), .full)
        let spec = try #require(env.store.declaredSeen.last).stagingPathspec
        #expect(spec.contains(".claude"))
        #expect(spec.contains(":(exclude).claude/b.md"))
        #expect(!spec.contains(":(exclude).claude"))
    }

    @Test("a tracked item that git does not track produces one warning per launch and no store call")
    func trackedVerified() async throws {
        let env = try await Env()
        env.setPolicy(PropagationRepoPolicy(overrides: ["claude": .tracked]))
        env.proc.on(["git", "ls-files", "--error-unmatch"]) { _ in ProcResult(stdout: "", stderr: "error", exitCode: 1) }
        let wt = try env.worktree("wt")
        _ = await env.service.sync(wt, env.card(wt), .full)
        _ = await env.service.sync(wt, env.card(wt), .full)
        #expect(env.sink.warnings.filter { $0.contains("tracked") }.count == 1)
        #expect(env.store.log.isEmpty)
    }

    @Test("a corrupt policy table produces zero git calls in the checkout, zero store calls and one warning")
    func corruptPolicyStandsDown() async throws {
        let env = try await Env()
        try "{not json".write(toFile: env.policyPath, atomically: true, encoding: .utf8)
        let wt = try env.worktree("wt")
        #expect(await env.service.sync(wt, env.card(wt), .full) == .standDown(.policyLoadFailed))
        #expect(await env.service.sync(wt, env.card(wt), .full) == .standDown(.policyLoadFailed))
        #expect(env.store.log.isEmpty)
        #expect(env.cardCalls().isEmpty)
        #expect(env.sink.warnings.count == 1)
    }

    @Test("below git 2.40 the service issues no store call and warns once")
    func gitVersionFloor() async throws {
        let old = try await OldGitEnv.make()
        let wt = try old.worktree("wt")
        #expect(await old.service.sync(wt, old.card(wt), .full) == .standDown(.gitTooOld))
        #expect(await old.service.sync(wt, old.card(wt), .full) == .standDown(.gitTooOld))
        #expect(old.store.log.isEmpty)
        #expect(old.sink.warnings.count == 1)
        #expect(await old.service.checkGitVersion() == false)
    }

    @Test("an unreadable git version is unknown, not old: flush keeps the tree")
    func gitVersionUnreadableKeepsTree() async throws {
        let bad = try await OldGitEnv.make(version: ProcResult(stdout: "", stderr: "boom", exitCode: 1))
        let wt = try bad.worktree("wt")
        let card = bad.card(wt)
        #expect(await bad.service.sync(wt, card, .full) == .standDown(.probeUnknown(detail: "git version unreadable")))
        #expect(await bad.service.flush(card) == false)
        #expect(bad.store.log.isEmpty)
    }
}

/// An environment whose `git version` answers 2.39 (`Env` registers 2.50 first, and the first rule wins).
private enum OldGitEnv {
    static func make(version: ProcResult = ProcResult(stdout: "git version 2.39.2\n", stderr: "", exitCode: 0)) async throws -> OldEnv {
        try await OldEnv(version: version)
    }
}
private final class OldEnv: @unchecked Sendable {
    let base: String
    let proc = FakeProc()
    let store = FakeStore()
    let sink = Sink()
    let service: PropagationService
    let primary: String
    init(version: ProcResult) async throws {
        base = PathResolver.canonical(NSTemporaryDirectory() + "orch-prop-old-\(UUID().uuidString)")
        primary = base + "/repo"
        try FileManager.default.createDirectory(atPath: primary, withIntermediateDirectories: true)
        proc.on(["git", "version"]) { _ in version }
        service = PropagationService(store: store, proc: proc, resolver: PathResolver(allowedRoots: [base]),
                                     root: base + "/shared", policyPath: base + "/p.json", adapterItems: { [claudeItem] })
        let sink = self.sink
        await service.setSinks(notify: { sink.notify($0, $1, $2) }, warn: { sink.warn($0) })
    }
    func worktree(_ n: String) throws -> String {
        let wt = base + "/" + n
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        return wt
    }
    func card(_ cwd: String) -> OrchestraKit.Task {
        OrchestraKit.Task(title: "c", repo: primary, branch: "b", cwd: cwd, model: AgentModel(id: "m"),
                          startIn: .impl, column: .impl, order: 0, initialPrompt: "")
    }
}

// MARK: - Notices

@Suite("PropagationService — conflict notices")
struct PropagationServiceConflictTests {
    @Test("the same conflict on consecutive syncs notifies once; a new store sha notifies again; a clean sync clears")
    func noNoticeLoop() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let current = SvcBox("S1")
        env.store.receive = { _ in
            if current.value == "clean" { return .upToDate }
            return .conflicted(paths: ["b", "a"], storeSha: current.value)
        }
        _ = await env.service.sync(wt, env.card(wt), .full)
        _ = await env.service.sync(wt, env.card(wt), .full)
        #expect(env.sink.notices.count == 1)
        #expect(env.sink.notices[0].1.contains("a, b"))
        #expect(env.sink.notices[0].1.contains("orchestra shared resolve"))
        current.value = "S2"
        _ = await env.service.sync(wt, env.card(wt), .full)
        #expect(env.sink.notices.count == 2)
        current.value = "clean"
        _ = await env.service.sync(wt, env.card(wt), .full)
        current.value = "S2"
        _ = await env.service.sync(wt, env.card(wt), .full)
        #expect(env.sink.notices.count == 3)
    }

    @Test("a teardown flush warns every time — the session is dead, the inbox cannot carry it")
    func flushWarnsNotNotifies() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        env.store.receive = { _ in .conflicted(paths: ["a"], storeSha: "S1") }
        #expect(await env.service.flush(env.card(wt)) == false)
        #expect(await env.service.flush(env.card(wt)) == false)
        #expect(env.sink.notices.isEmpty)
        #expect(env.sink.warnings.filter { $0.contains("conflict") }.count == 2)
    }
}

private final class SvcBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: String
    init(_ v: String) { self.v = v }
    var value: String { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

// MARK: - Lock rule

@Suite("PropagationService — the lock rule")
struct PropagationServiceLockTests {
    private func lockError(_ path: String) -> SharedStoreError {
        .gitFailed(argv: ["add"], exitCode: 128, stderr: "fatal: Unable to create '\(path)': File exists.\n\nAnother git process seems to be running")
    }

    private func makeLock(_ env: Env, under wt: String, name: String = "index.lock") throws -> String {
        let dir = env.gitDir(for: wt)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/" + name
        try "".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("the matcher reads index locks and ref locks")
    func matcher() {
        #expect(PropagationService.lockPath(fromStderr: "fatal: Unable to create '/r/x/index.lock': File exists.") == "/r/x/index.lock")
        #expect(PropagationService.lockPath(fromStderr: "error: cannot lock ref 'r': Unable to create '/r/refs/a.lock': File exists.") == "/r/refs/a.lock")
        #expect(PropagationService.lockPath(fromStderr: "fatal: not a git repository") == nil)
    }

    @Test("a lock with a holder returns .busy and removes nothing")
    func heldLockIsBusy() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let lock = try makeLock(env, under: wt)
        env.proc.on(["lsof", "-t"]) { _ in ProcResult(stdout: "4242\n", stderr: "", exitCode: 0) }
        env.store.commit = { _ in throw self.lockError(lock) }
        #expect(await env.service.sync(wt, env.card(wt), .full) == .busy)
        #expect(FileManager.default.fileExists(atPath: lock))
    }

    @Test("a probe that did not complete is .busy, never proof of no holder")
    func unprovenIsBusy() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let lock = try makeLock(env, under: wt)
        env.proc.on(["lsof", "-t"]) { _ in ProcResult(stdout: "", stderr: "lsof: WARNING", exitCode: 1) }
        env.store.commit = { _ in throw self.lockError(lock) }
        #expect(await env.service.sync(wt, env.card(wt), .full) == .busy)
        #expect(FileManager.default.fileExists(atPath: lock))
    }

    @Test("a lock with no holder is removed once with a warning, and the store method is retried once")
    func staleLockRemovedAndRetried() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let lock = try makeLock(env, under: wt)
        env.store.commit = { n in
            if n == 1 { throw self.lockError(lock) }
            return .nothingToCommit(warnings: [])
        }
        let outcome = await env.service.sync(wt, env.card(wt), .full)
        #expect(outcome == .completed(receive: .upToDate, send: .nothingToDo))
        #expect(!FileManager.default.fileExists(atPath: lock))
        #expect(env.store.log.filter { $0 == "commit:wt" }.count == 2)
        #expect(env.sink.warnings.contains { $0.contains("stale git lock") })
    }

    @Test("a lock path spelled through a symlink alias of the store root is still recognized as inside it")
    func aliasedLockPathIsRemovable() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let lock = try makeLock(env, under: wt)
        let alias = lock.hasPrefix("/private/") ? String(lock.dropFirst("/private".count)) : lock
        env.store.commit = { n in
            if n == 1 { throw self.lockError(alias) }
            return .nothingToCommit(warnings: [])
        }
        #expect(await env.service.sync(wt, env.card(wt), .full) == .completed(receive: .upToDate, send: .nothingToDo))
        #expect(!FileManager.default.fileExists(atPath: lock))
    }

    @Test("a second lock failure after the retry is .busy — no loop")
    func retryOnlyOnce() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let lock = try makeLock(env, under: wt)
        env.store.commit = { _ in throw self.lockError(lock) }
        #expect(await env.service.sync(wt, env.card(wt), .full) == .busy)
        #expect(env.store.log.filter { $0 == "commit:wt" }.count == 2)
    }

    @Test("a lock file outside the store root is never removed")
    func outsideRootUntouched() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let outside = env.base + "/project.git.lock"
        try "".write(toFile: outside, atomically: true, encoding: .utf8)
        env.store.commit = { _ in throw self.lockError(outside) }
        #expect(await env.service.sync(wt, env.card(wt), .full) == .busy)
        #expect(FileManager.default.fileExists(atPath: outside))
    }

    @Test("a non-lock store error is .failed, and a thrown ignore-probe failure leaves the conflict record alone")
    func otherErrorsFail() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        env.store.receive = { _ in .conflicted(paths: ["a"], storeSha: "S1") }
        _ = await env.service.sync(wt, env.card(wt), .full)
        env.store.receive = { _ in throw SharedStoreError.ignoreProbeFailed(detail: "boom") }
        guard case .failed = await env.service.sync(wt, env.card(wt), .full) else { Issue.record("expected .failed"); return }
        #expect(env.sink.warnings.contains { $0.contains("sync failed") && $0.contains("boom") })
        env.store.receive = { _ in .conflicted(paths: ["a"], storeSha: "S1") }
        _ = await env.service.sync(wt, env.card(wt), .full)
        #expect(env.sink.notices.count == 1)   // record survived the failure, so no re-notice
    }
}

// MARK: - flush / reap / resolve / status

@Suite("PropagationService — flush, reap, resolve, status")
struct PropagationServiceEntryPointTests {
    @Test("flush is true for a missing cwd without any git call")
    func flushMissingCwd() async throws {
        let env = try await Env()
        #expect(await env.service.flush(env.card(env.base + "/gone")))
        #expect(env.proc.calls.isEmpty)
        #expect(env.store.log.isEmpty)
    }

    @Test("sync of a missing checkout makes no git or store call — a late idle sync cannot re-create a reaped git dir")
    func syncMissingCheckout() async throws {
        let env = try await Env()
        let gone = env.base + "/gone"
        #expect(await env.service.sync(gone, env.card(gone), .full) == .skipped(.notARepo))
        #expect(env.proc.calls.isEmpty)
        #expect(env.store.log.isEmpty)
    }

    @Test("flush truth table: true on pushed, nothing-to-do, ineligible; false on everything that can lose data")
    func flushMatrix() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let card = env.card(wt)

        env.store.send = { _ in .pushed }
        #expect(await env.service.flush(card))
        env.store.send = { _ in .nothingToDo }
        #expect(await env.service.flush(card))
        #expect(await env.service.flush(env.card(wt, origin: .scratch)))
        #expect(await env.service.flush(env.card(wt, access: .readOnly)))

        env.store.send = { _ in .refusedOutOfSet(paths: ["x"]) }
        #expect(await env.service.flush(card) == false)
        env.store.send = { _ in .partial(dirty: ["x"]) }
        #expect(await env.service.flush(card) == false)
        env.store.send = { _ in .conflicted(paths: ["x"], storeSha: "S") }
        #expect(await env.service.flush(card) == false)
        env.store.send = { _ in throw SharedStoreError.sendRetriesExhausted }
        #expect(await env.service.flush(card) == false)
        env.store.send = { _ in .pushed }
        env.store.receive = { _ in .partial(dirty: ["x"]) }
        #expect(await env.service.flush(card) == false)
        env.store.receive = { _ in .upToDate }

        let dir = env.gitDir(for: wt)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "x".write(toFile: dir + "/MERGE_HEAD", atomically: true, encoding: .utf8)
        #expect(await env.service.flush(card) == false)
    }

    @Test("an over-5-MiB edit left out of the commit keeps the tree at flush, even when the store has nothing to send")
    func flushKeepsOversizedEdit() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let card = env.card(wt)
        env.store.commit = { _ in .nothingToCommit(warnings: [.oversized(path: "CLAUDE.md")]) }
        env.store.send = { _ in .nothingToDo }
        #expect(await env.service.sync(wt, card, .flush) == .unsent(paths: ["CLAUDE.md"]))
        #expect(await env.service.flush(card) == false)
        // An ordinary idle sync is unchanged: the warning is logged, the outcome stays completed.
        if case .completed = await env.service.sync(wt, card, .full) {} else { Issue.record("expected .completed") }
    }

    @Test("reap removes only its own checkout git dir, and only after the checkout's chain drains")
    func reapAfterDrain() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let mine = env.gitDir(for: wt)
        let other = env.gitDir(for: env.base + "/other")
        for d in [mine, other] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let gate = env.store.gate("commit:wt")
        let syncTask = _Concurrency.Task { await env.service.sync(wt, env.card(wt), .full) }
        await gate.reached()
        let reapTask = _Concurrency.Task { await env.service.reap(env.card(wt)) }
        await yieldBriefly()
        #expect(FileManager.default.fileExists(atPath: mine))
        gate.release()
        _ = await syncTask.value
        await reapTask.value
        #expect(!FileManager.default.fileExists(atPath: mine))
        #expect(FileManager.default.fileExists(atPath: other))
    }

    @Test("resolve rides the checkout's chain and clears the standing conflict")
    func resolveOnChain() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        env.store.receive = { _ in .conflicted(paths: ["a"], storeSha: "S1") }
        let gate = env.store.gate("commit:wt")
        let syncTask = _Concurrency.Task { await env.service.sync(wt, env.card(wt), .full) }
        await gate.reached()
        let resolveTask = _Concurrency.Task { try await env.service.resolve(env.card(wt)) }
        await yieldBriefly()
        #expect(!env.store.log.contains("resolve:wt"))
        gate.release()
        _ = await syncTask.value
        #expect(try await resolveTask.value == .resolved)
        #expect(env.store.log.contains("resolve:wt"))
        let status = try await env.service.status(env.card(wt))
        #expect(status.conflict == nil)
    }

    @Test("status is read-only: it never attaches, and reports items, policies and the read command once the git dir exists")
    func statusReadOnly() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        var status = try await env.service.status(env.card(wt))
        #expect(env.store.log.isEmpty)
        #expect(status.readCommand == nil)
        #expect(status.items == [ItemStatus(name: "claude", policy: .shared, paths: ["CLAUDE.md"])])
        try FileManager.default.createDirectory(atPath: env.gitDir(for: wt), withIntermediateDirectories: true)
        try "ref".write(toFile: env.gitDir(for: wt) + "/HEAD", atomically: true, encoding: .utf8)
        status = try await env.service.status(env.card(wt))
        #expect(status.readCommand == "GIT_OPTIONAL_LOCKS=0 git --git-dir=\(env.gitDir(for: wt))")
    }
}

// MARK: - adopt

@Suite("PropagationService — adopt")
struct PropagationServiceAdoptTests {
    private let item = PropagationItem(name: "notes", paths: ["CLAUDE.md"], exclusions: [])

    @discardableResult
    private func script(_ env: Env, matchedAfterAppend: Bool = true, tracked: String = "CLAUDE.md\0") -> SvcBox {
        let trackedBox = SvcBox(tracked)
        let hasPattern = SvcBox(matchedAfterAppend ? "" : "never")
        env.proc.on(["git", "check-ignore", "--no-index"]) { _ in
            let gitignore = (try? String(contentsOfFile: env.base + "/wt/.gitignore", encoding: .utf8)) ?? ""
            let matched = gitignore.contains("/CLAUDE.md") && hasPattern.value != "never"
            return ProcResult(stdout: "", stderr: "", exitCode: matched ? 0 : 1)
        }
        env.proc.on(["git", "ls-files", "-z"]) { _ in ProcResult(stdout: trackedBox.value, stderr: "", exitCode: 0) }
        return trackedBox
    }

    @Test("adopt syncs the primary first, then appends the pattern, untracks with an explicit file list, never commits, and persists shared")
    func adoptFlow() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        script(env)
        let outcome = await env.service.adopt(items: [item], from: env.card(wt))
        #expect(outcome == .adopted(untracked: ["CLAUDE.md"]))
        #expect(env.store.log.first == "attach:repo")
        #expect(env.store.log.contains("send:repo"))
        let gitignore = try String(contentsOfFile: wt + "/.gitignore", encoding: .utf8)
        #expect(gitignore.contains("/CLAUDE.md"))
        let rm = try #require(env.proc.calls.first { $0.argv.starts(with: ["git", "rm"]) })
        #expect(rm.argv == ["git", "rm", "--cached", "-q", "--", "CLAUDE.md"])
        #expect(!env.proc.calls.contains { $0.argv.starts(with: ["git", "commit"]) })
        let row = try #require(PropagationStore.load(path: env.policyPath).table[env.primary])
        #expect(row.overrides["notes"] == .shared)
        #expect(row.userItems["notes"] == item)
    }

    @Test("adopt run twice re-sends the primary and repeats nothing else")
    func adoptRerun() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        let trackedBox = script(env)
        _ = await env.service.adopt(items: [item], from: env.card(wt))
        let ignoreAfterFirst = try String(contentsOfFile: wt + "/.gitignore", encoding: .utf8)
        trackedBox.value = ""   // git no longer tracks it after the first run
        let rmBefore = env.proc.calls.filter { $0.argv.starts(with: ["git", "rm"]) }.count
        let second = await env.service.adopt(items: [item], from: env.card(wt))
        #expect(second == .adopted(untracked: []))
        #expect(env.store.log.filter { $0 == "send:repo" }.count == 2)
        #expect(try String(contentsOfFile: wt + "/.gitignore", encoding: .utf8) == ignoreAfterFirst)
        #expect(env.proc.calls.filter { $0.argv.starts(with: ["git", "rm"]) }.count == rmBefore)
    }

    @Test("adopt stops before rm --cached when a negation still re-includes a leaf, and persists nothing")
    func adoptNegationStops() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        script(env, matchedAfterAppend: false)
        let outcome = await env.service.adopt(items: [item], from: env.card(wt))
        #expect(outcome == .stopped(.negationRemains(paths: ["CLAUDE.md"])))
        #expect(!env.proc.calls.contains { $0.argv.starts(with: ["git", "rm"]) })
        #expect(PropagationStore.load(path: env.policyPath).table.isEmpty)
    }

    @Test("adopt stopping at the negation check leaves the appended pattern in place — steps 2-3 are the documented exception")
    func adoptNegationLeavesPattern() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        script(env, matchedAfterAppend: false)
        _ = await env.service.adopt(items: [item], from: env.card(wt))
        #expect(try String(contentsOfFile: wt + "/.gitignore", encoding: .utf8).contains("/CLAUDE.md"))
    }

    @Test("an item with exclusions gets per-leaf patterns, never a root line that would also ignore its excluded subtrees")
    func adoptExclusionsNoRootPattern() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt", files: [".claude/commands/ship.md", ".claude/skills/s/SKILL.md"])
        let dirItem = PropagationItem(name: "claude", paths: [".claude"], exclusions: [".claude/skills"])
        env.proc.on(["git", "check-ignore", "--no-index"]) { argv in
            let gitignore = (try? String(contentsOfFile: wt + "/.gitignore", encoding: .utf8)) ?? ""
            return ProcResult(stdout: "", stderr: "", exitCode: gitignore.contains("/" + (argv.last ?? "?")) ? 0 : 1)
        }
        env.proc.on(["git", "ls-files", "-z"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        _ = await env.service.adopt(items: [dirItem], from: env.card(wt))
        let lines = try String(contentsOfFile: wt + "/.gitignore", encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == ["/.claude/commands/ship.md"])
    }

    @Test("adopt for a declared path that does not exist yet still adds its pattern")
    func adoptMissingDeclaredPath() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt", files: [])
        script(env, tracked: "")
        let outcome = await env.service.adopt(items: [item], from: env.card(wt))
        #expect(outcome == .adopted(untracked: []))
        #expect(try String(contentsOfFile: wt + "/.gitignore", encoding: .utf8).contains("/CLAUDE.md"))
    }

    @Test("adopt stops, touching nothing in the project, when the primary's sync fails")
    func adoptPrimaryFailureStops() async throws {
        let env = try await Env()
        let wt = try env.worktree("wt")
        script(env)
        env.store.receive = { _ in .conflicted(paths: ["CLAUDE.md"], storeSha: "S") }
        let outcome = await env.service.adopt(items: [item], from: env.card(wt))
        guard case .stopped(.primarySyncFailed) = outcome else { Issue.record("expected primarySyncFailed, got \(outcome)"); return }
        #expect(!FileManager.default.fileExists(atPath: wt + "/.gitignore"))
        #expect(!env.proc.calls.contains { $0.argv.starts(with: ["git", "rm"]) })
    }
}

// MARK: - sweep

@Suite("PropagationService — boot sweep")
struct PropagationServiceSweepTests {
    private func plant(_ env: Env, recorded: String, name: String) throws -> String {
        let dir = "\(env.root)/r1/checkouts/\(name).git"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try recorded.write(toFile: dir + "/orchestra-checkout", atomically: true, encoding: .utf8)
        return dir
    }

    @Test("removes a git dir whose path is gone, and one nothing references; keeps a referenced one and a primary's")
    func sweepMatrix() async throws {
        let env = try await Env()
        let live = try env.worktree("live"), orphan = try env.worktree("orphan")
        let gone = try plant(env, recorded: env.base + "/gone", name: "a")
        let kept = try plant(env, recorded: live, name: "b")
        let orphaned = try plant(env, recorded: orphan, name: "c")
        let primaryDir = try plant(env, recorded: env.primary, name: "d")
        let removed = await env.service.sweep(referencedCwds: [live], primaries: [env.primary])
        #expect(Set(removed) == [gone, orphaned])
        #expect(FileManager.default.fileExists(atPath: kept))
        #expect(FileManager.default.fileExists(atPath: primaryDir))
    }

    @Test("an empty referenced set only removes git dirs whose path is gone — the card set is not known yet")
    func emptyReferencedIsSafe() async throws {
        let env = try await Env()
        let live = try env.worktree("live")
        let gone = try plant(env, recorded: env.base + "/gone", name: "a")
        let kept = try plant(env, recorded: live, name: "b")
        let removed = await env.service.sweep(referencedCwds: [], primaries: [])
        #expect(removed == [gone])
        #expect(FileManager.default.fileExists(atPath: kept))
    }

    @Test("an unknown card set keeps every live checkout even when primaries are known: only the path-gone arm runs")
    func emptyReferencedWithPrimariesIsSafe() async throws {
        let env = try await Env()
        let live = try env.worktree("live")
        let gone = try plant(env, recorded: env.base + "/gone", name: "a")
        let kept = try plant(env, recorded: live, name: "b")
        // An incompletely loaded board passes no cards but still derives primaries from the cards that loaded.
        let removed = await env.service.sweep(referencedCwds: [], primaries: [env.primary])
        #expect(removed == [gone])
        #expect(FileManager.default.fileExists(atPath: kept))
    }

    @Test("path spelling is canonicalized on both sides")
    func aliasSpelling() async throws {
        let env = try await Env()
        let live = try env.worktree("live")
        let alias = live.hasPrefix("/private/") ? String(live.dropFirst("/private".count)) : live
        let kept = try plant(env, recorded: alias, name: "b")
        let removed = await env.service.sweep(referencedCwds: [live], primaries: [env.primary])
        #expect(removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: kept))
    }

    @Test("a live borrowed card whose cwd is a subdirectory of the recorded work tree keeps its git dir; reap never touches a borrowed card's")
    func borrowedSubdirectoryKept() async throws {
        let env = try await Env()
        let top = try env.worktree("top", files: ["sub/x"])
        let kept = try plant(env, recorded: top, name: "b")
        let orphanPath = try env.worktree("orphan")
        let orphaned = try plant(env, recorded: orphanPath, name: "c")
        let removed = await env.service.sweep(referencedCwds: [top + "/sub"], primaries: [])
        #expect(removed == [orphaned])
        #expect(FileManager.default.fileExists(atPath: kept))
        await env.service.reap(env.card(top, origin: .borrowed))
        #expect(FileManager.default.fileExists(atPath: kept))
    }

    @Test("a git dir created after the sweep began is kept: its card attached after the caller's snapshot")
    func newerThanSweepStartKept() async throws {
        let env = try await Env()
        let orphan = try env.worktree("orphan")
        let dir = try plant(env, recorded: orphan, name: "c")
        let other = try env.worktree("other")
        // The sweep started a minute ago; `dir` was created just now. Only a referenced-elsewhere set exists.
        let removed = await env.service.sweep(referencedCwds: [other], primaries: [], startedAt: Date(timeIntervalSinceNow: -60))
        #expect(removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir))
    }

    @Test("a recorded primary repo root (a .git directory) is never swept, even when no card names the repo")
    func primaryRootKept() async throws {
        let env = try await Env()
        let root = try env.worktree("primary2", files: [".git/HEAD"])
        let other = try env.worktree("other")
        let dir = try plant(env, recorded: root, name: "p")
        let removed = await env.service.sweep(referencedCwds: [other], primaries: [])
        #expect(removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir))
    }

    @Test("a git dir with no readable record is left alone")
    func unreadableRecordKept() async throws {
        let env = try await Env()
        let dir = "\(env.root)/r1/checkouts/z.git"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        #expect(await env.service.sweep(referencedCwds: [], primaries: []).isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir))
    }
}
