import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

@Suite("IgnoreProbe — classify and re-probe by pattern")
struct IgnoreProbeTests {
    private func tmpCheckout() -> String {
        let path = NSTemporaryDirectory() + "ignoreprobe-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// A `ProcRunning` that always throws — FakeProc's `run` never throws, so this is the only way
    /// to pin the "the probe itself never completed" branch without widening the shared fake.
    private struct ThrowingProc: ProcRunning {
        struct Boom: Error {}
        func run(_ argv: [String], cwd: String?, env: [String: String], timeout: Duration?) async throws -> ProcResult {
            throw Boom()
        }
    }

    private func revParseTrue() -> FakeProc {
        let proc = FakeProc()
        proc.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
        return proc
    }

    @Test("rev-parse exiting 128 (not a repo) yields .notARepo without running check-ignore")
    func revParseFatalYieldsNotARepoWithoutCheckIgnore() async {
        let checkout = tmpCheckout()
        let proc = FakeProc()
        proc.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "", stderr: "fatal: not a git repository", exitCode: 128) }
        proc.on(["git", "check-ignore"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let result = await IgnoreProbe.classify(["CLAUDE.md"], inCheckout: checkout, proc: proc)
        #expect(result == .notARepo)
        #expect(!proc.calls.contains { $0.argv.starts(with: ["git", "check-ignore"]) })
    }

    @Test("rev-parse failing for any other reason (bad config, killed) is .unknown, never .notARepo")
    func revParseOtherFailureIsUnknown() async {
        let checkout = tmpCheckout()
        let proc = FakeProc()
        proc.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "", stderr: "fatal: bad config line 1 in file .git/config", exitCode: 128) }

        let result = await IgnoreProbe.classify(["CLAUDE.md"], inCheckout: checkout, proc: proc)
        guard case .unknown = result else { Issue.record("expected .unknown, got \(result)"); return }
    }

    @Test("a bare repository (stdout 'false', exit 0) yields .notARepo — exit code alone can't tell them apart")
    func bareRepoYieldsNotARepo() async {
        let checkout = tmpCheckout()
        let proc = FakeProc()
        proc.on(["git", "rev-parse", "--is-inside-work-tree"]) { _ in ProcResult(stdout: "false\n", stderr: "", exitCode: 0) }
        proc.on(["git", "check-ignore"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let result = await IgnoreProbe.classify(["CLAUDE.md"], inCheckout: checkout, proc: proc)
        #expect(result == .notARepo)
        #expect(!proc.calls.contains { $0.argv.starts(with: ["git", "check-ignore"]) })
    }

    @Test("a rev-parse call that never completes yields .unknown, never .notARepo")
    func revParseThrowYieldsUnknownNeverNotARepo() async {
        let result = await IgnoreProbe.classify(["CLAUDE.md"], inCheckout: tmpCheckout(), proc: ThrowingProc())
        guard case .unknown = result else {
            Issue.record("a probe that never completed must never be classified as .notARepo, got \(result)")
            return
        }
    }

    @Test("check-ignore exit 0 marks a path ignored; exit 1 does not")
    func exitCodesParseIntoIgnoredSubset() async {
        let checkout = tmpCheckout()
        let proc = revParseTrue()
        proc.on(["git", "check-ignore"]) { argv in
            ProcResult(stdout: "", stderr: "", exitCode: argv.last == "CLAUDE.md" ? 0 : 1)
        }

        let result = await IgnoreProbe.classify(["CLAUDE.md", "tracked.md"], inCheckout: checkout, proc: proc)
        #expect(result == .repo(ignored: ["CLAUDE.md"]))
    }

    @Test("nothing ignored parses into an empty ignored subset, not .unknown")
    func nothingIgnoredIsEmptySubset() async {
        let checkout = tmpCheckout()
        let proc = revParseTrue()
        proc.on(["git", "check-ignore"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }

        let result = await IgnoreProbe.classify(["tracked.md"], inCheckout: checkout, proc: proc)
        #expect(result == .repo(ignored: []))
    }

    @Test("check-ignore exit 128 on any path yields .unknown, never .notARepo")
    func checkIgnoreFatalYieldsUnknownNeverNotARepo() async {
        let checkout = tmpCheckout()
        let proc = revParseTrue()
        proc.on(["git", "check-ignore"]) { _ in ProcResult(stdout: "", stderr: "fatal: boom", exitCode: 128) }

        let result = await IgnoreProbe.classify(["CLAUDE.md"], inCheckout: checkout, proc: proc)
        #expect(result == .unknown(detail: "fatal: boom"))
    }

    @Test("a check-ignore call that never completes yields .unknown")
    func checkIgnoreThrowYieldsUnknown() async {
        struct RevParseTrueThenThrow: ProcRunning {
            func run(_ argv: [String], cwd: String?, env: [String: String], timeout: Duration?) async throws -> ProcResult {
                if argv.starts(with: ["git", "rev-parse"]) { return ProcResult(stdout: "true\n", stderr: "", exitCode: 0) }
                throw ThrowingProc.Boom()
            }
        }
        let result = await IgnoreProbe.classify(["CLAUDE.md"], inCheckout: tmpCheckout(), proc: RevParseTrueThenThrow())
        guard case .unknown = result else {
            Issue.record("expected .unknown, got \(result)")
            return
        }
    }

    @Test("a path with a symlinked ancestor is pruned before probing — never sent to check-ignore at all")
    func symlinkedAncestorIsPruned() async throws {
        let checkout = tmpCheckout()
        let target = tmpCheckout()
        try FileManager.default.createSymbolicLink(atPath: checkout + "/linked", withDestinationPath: target)

        let proc = revParseTrue()
        proc.on(["git", "check-ignore"]) { argv in
            // If the implementation forgot to prune "linked/file.txt", this rule would still only
            // ever answer for the exact path it's asked about — real git can't report on a path it
            // was never given, so this deliberately does NOT special-case the pruned path.
            ProcResult(stdout: "", stderr: "", exitCode: argv.last == "safe.md" ? 0 : 1)
        }

        let result = await IgnoreProbe.classify(["linked/file.txt", "safe.md"], inCheckout: checkout, proc: proc)
        #expect(result == .repo(ignored: ["safe.md"]))
        #expect(!proc.calls.contains { $0.argv.contains("linked/file.txt") })
    }

    @Test("a directory item is probed via <dir>/.orchestra-probe, folded back onto the declared path")
    func directoryItemProbedViaSyntheticChild() async throws {
        let checkout = tmpCheckout()
        try FileManager.default.createDirectory(atPath: checkout + "/.claude", withIntermediateDirectories: true)

        let proc = revParseTrue()
        proc.on(["git", "check-ignore"]) { argv in
            // The `dir/*`-style pattern matches only the synthetic child, never the bare directory.
            ProcResult(stdout: "", stderr: "", exitCode: argv.last == ".claude/.orchestra-probe" ? 0 : 1)
        }

        let result = await IgnoreProbe.classify([".claude"], inCheckout: checkout, proc: proc)
        #expect(result == .repo(ignored: [".claude"]))
        let checkIgnoreCalls = proc.calls.filter { $0.argv.starts(with: ["git", "check-ignore"]) }
        #expect(checkIgnoreCalls.contains { $0.argv.last == ".claude" })
        #expect(checkIgnoreCalls.contains { $0.argv.last == ".claude/.orchestra-probe" })
    }

    @Test("a plain file item is probed exactly once, never through a synthetic child")
    func fileItemProbedOnce() async throws {
        let checkout = tmpCheckout()
        let proc = revParseTrue()
        proc.on(["git", "check-ignore"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }

        _ = await IgnoreProbe.classify(["CLAUDE.md"], inCheckout: checkout, proc: proc)
        let checkIgnoreCalls = proc.calls.filter { $0.argv.starts(with: ["git", "check-ignore"]) }
        #expect(checkIgnoreCalls.count == 1)
        #expect(checkIgnoreCalls[0].argv == ["git", "check-ignore", "-q", "--", "CLAUDE.md"])
    }

    @Test("ignoredByPatterns passes --no-index")
    func ignoredByPatternsPassesNoIndex() async throws {
        let checkout = tmpCheckout()
        let proc = FakeProc()
        proc.on(["git", "check-ignore", "--no-index"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }

        let result = await IgnoreProbe.ignoredByPatterns(["CLAUDE.md"], inCheckout: checkout, proc: proc)
        #expect(result == ["CLAUDE.md"])
        let call = try #require(proc.calls.first)
        #expect(call.argv == ["git", "check-ignore", "--no-index", "-q", "--", "CLAUDE.md"])
    }

    @Test("ignoredByPatterns returns empty on a fatal check-ignore failure")
    func ignoredByPatternsFailsSafeOnFatal() async {
        let checkout = tmpCheckout()
        let proc = FakeProc()
        proc.on(["git", "check-ignore", "--no-index"]) { _ in ProcResult(stdout: "", stderr: "fatal", exitCode: 128) }

        let result = await IgnoreProbe.ignoredByPatterns(["CLAUDE.md"], inCheckout: checkout, proc: proc)
        #expect(result.isEmpty)
    }

    @Test("ignoredByPatterns fails the WHOLE result, not just one path, when a later path's probe fails")
    func ignoredByPatternsFailsWholeResultOnPartialFailure() async {
        // adopt (PR4) reads an incomplete match as "stop before rm --cached" — a partial success
        // that silently drops the failed path would let adopt proceed on a false negative.
        let checkout = tmpCheckout()
        let proc = FakeProc()
        proc.on(["git", "check-ignore", "--no-index"]) { argv in
            ProcResult(stdout: "", stderr: argv.last == "second.md" ? "fatal" : "", exitCode: argv.last == "second.md" ? 128 : 0)
        }

        let result = await IgnoreProbe.ignoredByPatterns(["first.md", "second.md"], inCheckout: checkout, proc: proc)
        #expect(result.isEmpty)
    }
}
