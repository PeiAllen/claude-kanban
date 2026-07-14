import Testing
import TestSupport
@testable import OrchestraCore

@Suite("FakeProc — scripting, fall-through, recording, gates")
struct FakeProcTests {
    @Test("first matching rule wins; nil falls through; default answers the rest")
    func scripting() async throws {
        let proc = FakeProc()
        proc.on(["git"]) { argv in                       // a broad rule that only handles config
            argv.count > 3 && argv[3] == "config"
                ? ProcResult(stdout: "main\n", stderr: "", exitCode: 0) : nil
        }
        proc.on(["git", "fetch"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 0) }
        let r = try await proc.run(["git", "-C", "/r", "config", "--get", "k"], cwd: nil, env: [:], timeout: nil)
        #expect(r.stdout == "main\n")
        let f = try await proc.run(["git", "fetch"], cwd: nil, env: [:], timeout: nil)   // fell through the broad rule
        #expect(f.ok)
        #expect(proc.calls.count == 2)
        #expect(proc.calls[1].argv == ["git", "fetch"])
    }

    @Test("a gated call suspends until release — no thread is blocked")
    func gates() async throws {
        let proc = FakeProc()
        let gate = proc.gate(on: ["git", "worktree", "add"])
        async let r = proc.run(["git", "worktree", "add", "/w", "-b", "b"], cwd: "/r", env: [:], timeout: nil)
        await gate.reached()                              // provably parked inside "git worktree add"
        gate.release(ProcResult(stdout: "", stderr: "", exitCode: 0))
        #expect(try await r.ok)
    }

    @Test("release with a failure makes the parked call return that failure")
    func gateFailure() async throws {
        let proc = FakeProc()
        let gate = proc.gate(on: ["git", "fetch"])
        async let r = proc.run(["git", "fetch"], cwd: nil, env: [:], timeout: nil)
        await gate.reached()
        gate.release(ProcResult(stdout: "", stderr: "fatal: no remote", exitCode: 128))
        #expect(try await r.exitCode == 128)
    }

    @Test("release before the call arrives still satisfies it (no ordering trap)")
    func earlyRelease() async throws {
        let proc = FakeProc()
        let gate = proc.gate(on: ["git", "fetch"])
        gate.release(ProcResult(stdout: "late\n", stderr: "", exitCode: 0))
        let r = try await proc.run(["git", "fetch"], cwd: nil, env: [:], timeout: nil)
        #expect(r.stdout == "late\n")
    }
}
