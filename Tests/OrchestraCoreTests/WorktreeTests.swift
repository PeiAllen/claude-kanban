import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

@Suite("WorktreeRegistry — bounded git (3.2, driven via the registry post-privatization)")
struct WorktreeBoundedTests {

    /// Records every (argv, timeout) the manager runs, and returns a canned result per argv.
    /// `timeout` is a non-optional `Duration` (the seam forbids unbounded git by type).
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(argv: [String], timeout: Duration)] = []
        var respond: @Sendable (_ argv: [String]) -> ProcResult
        init(respond: @escaping @Sendable (_ argv: [String]) -> ProcResult) { self.respond = respond }
        func run(_ argv: [String], _ timeout: Duration) throws -> ProcResult {
            lock.lock(); _calls.append((argv, timeout)); lock.unlock()
            return respond(argv)
        }
        var calls: [(argv: [String], timeout: Duration)] { lock.lock(); defer { lock.unlock() }; return _calls }
        func first(where pred: ([String]) -> Bool) -> (argv: [String], timeout: Duration)? {
            calls.first { pred($0.argv) }
        }
    }

    // `static` so they can be referenced from `@Sendable` respond closures without capturing `self`.
    static func ok(_ stdout: String = "") -> ProcResult { ProcResult(stdout: stdout, stderr: "", exitCode: 0) }
    static func fail(_ stderr: String) -> ProcResult { ProcResult(stdout: "", stderr: stderr, exitCode: 1) }
    static func isAdd(_ argv: [String]) -> Bool { argv.contains("worktree") && argv.contains("add") }
    static func isRemove(_ argv: [String]) -> Bool { argv.contains("worktree") && argv.contains("remove") }
    static func isPrune(_ argv: [String]) -> Bool { argv.contains("worktree") && argv.contains("prune") }

    /// A unique base under the temp dir + its allowlisted roots. Caller passes `cleanup` to a
    /// `defer` so the unit tests don't leak dirs (mirrors IntegrationSupport.tempDir hygiene).
    private func config() -> (cfg: Config, cleanup: () -> Void) {
        let base = NSTemporaryDirectory() + "wt-bound-\(UUID().uuidString)"
        let cfg = Config(reposRoot: base, worktreesRoot: base + "/wt",
                         allowlist: [base, base + "/wt"],
                         worktreeAddTimeout: 600, controlTimeout: 15,
                         scratchRoot: base + "/scratch", runtimeStateDir: base + "/state")
        return (cfg, { try? FileManager.default.removeItem(atPath: base) })
    }

    /// The registry's run-seam init (test-only, internal) — injects the timed `run` closure into the
    /// fileprivate manager without naming the concrete type. `base`-relative markers/borrows so a
    /// bounded-git assertion never touches real `~/.orchestra` state.
    private func registry(_ cfg: Config, base: String, run: @escaping @Sendable ([String], Duration) throws -> ProcResult) -> WorktreeRegistry {
        WorktreeRegistry(config: cfg, run: run, borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
    }

    @Test("every `git worktree add` — ensure(new), ensure(existing), borrow — is bounded by worktreeAddTimeout")
    func test_worktreeAddIsBounded() async throws {
        // ensure, NEW branch: rev-parse fails → `-b` add
        do {
            let (cfg, cleanup) = config(); defer { cleanup() }
            let rec = Recorder { argv in
                if argv.contains("rev-parse") { return Self.fail("no branch") }
                return Self.ok()
            }
            let reg = registry(cfg, base: cfg.reposRoot, run: { try rec.run($0, $1) })
            _ = try await reg.ensure(repo: cfg.reposRoot, branch: "feat-new", cardId: UUID())
            let add = try #require(rec.first(where: Self.isAdd))
            #expect(add.timeout == .seconds(cfg.worktreeAddTimeout))   // 600s
        }
        // ensure, EXISTING branch: rev-parse ok → existing-branch add
        do {
            let (cfg, cleanup) = config(); defer { cleanup() }
            let rec = Recorder { argv in
                if argv.contains("rev-parse") { return Self.ok() }
                return Self.ok()
            }
            let reg = registry(cfg, base: cfg.reposRoot, run: { try rec.run($0, $1) })
            _ = try await reg.ensure(repo: cfg.reposRoot, branch: "feat-existing", cardId: UUID())
            let add = try #require(rec.first(where: Self.isAdd))
            #expect(add.timeout == .seconds(cfg.worktreeAddTimeout))
        }
        // borrow: branch must exist → borrow add
        do {
            let (cfg, cleanup) = config(); defer { cleanup() }
            let rec = Recorder { argv in
                if argv.contains("rev-parse") { return Self.ok() }
                return Self.ok()
            }
            let reg = registry(cfg, base: cfg.reposRoot, run: { try rec.run($0, $1) })
            _ = try await reg.ensureBorrow(repo: cfg.reposRoot, parentBranch: "feat-borrow", borrowerCardId: UUID())
            let add = try #require(rec.first(where: Self.isAdd))
            #expect(add.timeout == .seconds(cfg.worktreeAddTimeout))
        }
    }

    @Test("the `worktree remove` and its fallback `worktree prune` are bounded by controlTimeout")
    func test_pruneIsBounded() async throws {
        let (cfg, cleanup) = config(); defer { cleanup() }
        let id = UUID()
        // Precompute the worktree path (pure — doesn't need `run`) so the recorder can reference it
        // without capturing a `var` across the `@Sendable` closure boundary.
        let wt = cfg.worktreePath(repo: cfg.reposRoot, branch: "victim")
        // A recorder that answers `worktree add` ok (so `ensure` "cuts" a tree without physically
        // creating the dir — the run-seam doesn't touch the filesystem) then, on `worktree remove`,
        // deletes the dir it's told to remove and returns non-ok so the fallback `prune` fires.
        let rec = Recorder { argv in
            if Self.isRemove(argv) {
                try? FileManager.default.removeItem(atPath: wt)   // dir gone after the remove attempt
                return Self.fail("remove failed")
            }
            return Self.ok()
        }
        let reg = registry(cfg, base: cfg.reposRoot, run: { try rec.run($0, $1) })
        let ensured = try await reg.ensure(repo: cfg.reposRoot, branch: "victim", cardId: id)
        #expect(ensured.path == wt)
        // The run-seam `ensure` records `git worktree add` but does NOT physically create `wt` on disk
        // (the canned `run` closure never touches the filesystem) — and `release`'s `guard
        // fileExists(wt)` short-circuits before ever reaching `manager.remove`. So, exactly like the
        // pre-privatization test, mkdir the dir so `release` reaches the bounded remove+prune this
        // coverage is about. `ensure` already wrote the marker (unconditionally, regardless of whether
        // the dir physically exists), so `release`'s `created`(≡marker) guard is already satisfied.
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)

        let card = Task(id: id, title: "t", repo: cfg.reposRoot, branch: "victim", cwd: wt,
                        origin: .worktree, model: AgentModel(id: "m"), startIn: .impl, column: .impl,
                        order: 0, phase: .live(.running), initialPrompt: "")
        try await reg.release(cardId: id, cards: [card], force: true)   // force skips the isDirty status query

        let removeCall = try #require(rec.first(where: Self.isRemove))
        #expect(removeCall.timeout == .seconds(cfg.controlTimeout))   // the `worktree remove` itself, 15s
        let prune = try #require(rec.first(where: Self.isPrune))
        #expect(prune.timeout == .seconds(cfg.controlTimeout))        // the fallback prune, 15s
    }

    // Real wall-clock enforcement lives in `Proc.run(timeout:)` (covered by Proc's own tests) and
    // `Proc` is untouched here (constraint). So this proves the two things the manager is responsible
    // for: (1) the add is invoked WITH `worktreeAddTimeout`, and (2) a timeout-shaped failure — the
    // non-ok result `Proc.run` returns after it SIGTERMs a process that blew the wall clock — is
    // surfaced as a thrown error instead of a hang. Not just generic error propagation: it asserts the
    // bound was actually passed on the timing-out call.
    @Test("a bounded add whose bound trips surfaces as a throw (not a hang), and the add was bounded")
    func test_worktreeAddTimesOut() async throws {
        let (cfg, cleanup) = config(); defer { cleanup() }
        let rec = Recorder { argv in
            if argv.contains("rev-parse") { return Self.fail("no branch") }
            if Self.isAdd(argv) { return ProcResult(stdout: "", stderr: "terminated: timed out", exitCode: 15) }
            return Self.ok()
        }
        let reg = registry(cfg, base: cfg.reposRoot, run: { try rec.run($0, $1) })
        await #expect(throws: OrchestraError.self) {
            _ = try await reg.ensure(repo: cfg.reposRoot, branch: "slow", cardId: UUID())
        }
        let add = try #require(rec.first(where: Self.isAdd))
        #expect(add.timeout == .seconds(cfg.worktreeAddTimeout))   // the timing-out add WAS bounded
    }
}
