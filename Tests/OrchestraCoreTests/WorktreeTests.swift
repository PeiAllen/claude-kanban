import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

@Suite("WorktreeManager — bounded git (3.2)")
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
                         worktreeAddTimeout: 600, controlTimeout: 15)
        return (cfg, { try? FileManager.default.removeItem(atPath: base) })
    }

    /// Drive one code path with `branchExists` controlling the `rev-parse` probe, then assert its
    /// recorded `worktree add` carried `worktreeAddTimeout`. (Wrapping `rec.run` in a closure literal
    /// makes it reliably inferred `@Sendable`.)
    private func assertAddBounded(branchExists: Bool,
                                  _ drive: (WorktreeManager, Config) throws -> Void) throws {
        let (cfg, cleanup) = config(); defer { cleanup() }
        let rec = Recorder { argv in
            if argv.contains("rev-parse") { return branchExists ? Self.ok() : Self.fail("no branch") }
            return Self.ok()   // everything else (incl. the add) succeeds
        }
        let wm = WorktreeManager(config: cfg, resolver: nil, run: { try rec.run($0, $1) })
        try drive(wm, cfg)
        let add = try #require(rec.first(where: Self.isAdd))
        #expect(add.timeout == .seconds(cfg.worktreeAddTimeout))   // 600s
    }

    @Test("every `git worktree add` — ensure(new), ensure(existing), borrow — is bounded by worktreeAddTimeout")
    func test_worktreeAddIsBounded() throws {
        // ensure, NEW branch: rev-parse fails → `-b` add (WorktreeManager.swift:41→65)
        try assertAddBounded(branchExists: false) { wm, cfg in
            _ = try wm.ensure(repo: cfg.reposRoot, branch: "feat-new")
        }
        // ensure, EXISTING branch: rev-parse ok → existing-branch add (WorktreeManager.swift:39→65)
        try assertAddBounded(branchExists: true) { wm, cfg in
            _ = try wm.ensure(repo: cfg.reposRoot, branch: "feat-existing")
        }
        // borrow: branch must exist → borrow add (WorktreeManager.swift:102)
        try assertAddBounded(branchExists: true) { wm, cfg in
            _ = try wm.borrow(repo: cfg.reposRoot, branch: "feat-borrow")
        }
    }

    @Test("the `worktree remove` and its fallback `worktree prune` are bounded by controlTimeout")
    func test_pruneIsBounded() throws {
        let (cfg, cleanup) = config(); defer { cleanup() }
        // Make a real dir so remove() passes its fileExists guard, then have the stub delete it
        // when it sees `worktree remove` and return non-ok → the fallback prune fires; the dir is
        // then gone so remove() returns without throwing.
        let wt = cfg.worktreesRoot + "/repo/victim"
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        let rec = Recorder { argv in
            if Self.isRemove(argv) {
                try? FileManager.default.removeItem(atPath: wt)   // dir gone after the remove attempt
                return Self.fail("remove failed")
            }
            return Self.ok()
        }
        let wm = WorktreeManager(config: cfg, resolver: nil, run: { try rec.run($0, $1) })
        try wm.remove(worktree: wt, force: true)   // force skips the isDirty status query

        let removeCall = try #require(rec.first(where: Self.isRemove))
        #expect(removeCall.timeout == .seconds(cfg.controlTimeout))   // the `worktree remove` itself, 15s
        let prune = try #require(rec.first(where: Self.isPrune))
        #expect(prune.timeout == .seconds(cfg.controlTimeout))        // the fallback prune, 15s
    }

    // Real wall-clock enforcement lives in `Proc.run(timeout:)` (covered by Proc's own tests) and
    // `Proc` is untouched here (constraint). So this proves the two things WorktreeManager is
    // responsible for: (1) the add is invoked WITH `worktreeAddTimeout`, and (2) a timeout-shaped
    // failure — the non-ok result `Proc.run` returns after it SIGTERMs a process that blew the wall
    // clock — is surfaced as a thrown error instead of a hang. Not just generic error propagation:
    // it asserts the bound was actually passed on the timing-out call.
    @Test("a bounded add whose bound trips surfaces as a throw (not a hang), and the add was bounded")
    func test_worktreeAddTimesOut() throws {
        let (cfg, cleanup) = config(); defer { cleanup() }
        let rec = Recorder { argv in
            if argv.contains("rev-parse") { return Self.fail("no branch") }
            if Self.isAdd(argv) { return ProcResult(stdout: "", stderr: "terminated: timed out", exitCode: 15) }
            return Self.ok()
        }
        let wm = WorktreeManager(config: cfg, resolver: nil, run: { try rec.run($0, $1) })
        #expect(throws: OrchestraError.self) {
            try wm.ensure(repo: cfg.reposRoot, branch: "slow")
        }
        let add = try #require(rec.first(where: Self.isAdd))
        #expect(add.timeout == .seconds(cfg.worktreeAddTimeout))   // the timing-out add WAS bounded
    }
}
