import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

@Suite("LockProbe — is anybody holding this lock file open")
struct LockProbeTests {
    @Test("lsof -t output parses into a PID set")
    func parsesPIDs() {
        #expect(LockProbe.parsePIDs("1234\n5678\n") == [1234, 5678])
    }

    @Test("empty lsof output parses into an empty set — safe to remove")
    func emptyOutputIsEmptySet() {
        #expect(LockProbe.parsePIDs("").isEmpty)
    }

    @Test("parsePIDs drops unparseable/blank lines rather than trapping")
    func dropsUnparseableLines() {
        #expect(LockProbe.parsePIDs("1234\n\nnot-a-pid\n5678\n") == [1234, 5678])
    }

    @Test("holders() via a fake proc: non-empty lsof output means busy")
    func holdersBusyViaFakeProc() async {
        let proc = FakeProc()
        proc.on(["lsof", "-t"]) { _ in ProcResult(stdout: "4242\n", stderr: "", exitCode: 0) }
        let holders = await LockProbe.holders("/repo/.git/index.lock", proc: proc)
        #expect(holders == [4242])
        #expect(proc.calls.first?.argv == ["lsof", "-t", "/repo/.git/index.lock"])
    }

    @Test("holders() via a fake proc: empty lsof output means no holder, safe to remove")
    func holdersEmptyViaFakeProc() async {
        let proc = FakeProc()
        proc.on(["lsof", "-t"]) { _ in ProcResult(stdout: "", stderr: "", exitCode: 1) }
        let holders = await LockProbe.holders("/repo/.git/index.lock", proc: proc)
        #expect(holders == [])
    }

    @Test("holders() returns nil when the probe itself never completed — distinct from an empty set")
    func holdersNilWhenProbeNeverCompleted() async {
        // A probe that never ran is not proof nobody holds the lock. nil (not an empty set) is how
        // the caller (PropagationService, PR4) tells "unknown, treat as busy" apart from "ran, found
        // nothing" — collapsing them would let a crashed daemon call race a live lock holder.
        struct ThrowingProc: ProcRunning {
            struct Boom: Error {}
            func run(_ argv: [String], cwd: String?, env: [String: String], timeout: Duration?) async throws -> ProcResult {
                throw Boom()
            }
        }
        let holders = await LockProbe.holders("/repo/.git/index.lock", proc: ThrowingProc())
        #expect(holders == nil)
    }

    @Test("the Linux probe matches a /proc/<pid>/fd entry pointing at the lock")
    func linuxProbeMatchesFdTarget() {
        let lockPath = "/repo/.git/index.lock"
        let fdTargets: [(pid: Int32, target: String)] = [
            (pid: 111, target: lockPath),
            (pid: 222, target: "/repo/.git/some-other-file"),
        ]
        #expect(LockProbe.matchingHolders(fdTargets: fdTargets, lockPath: lockPath) == [111])
    }

    @Test("the Linux probe returns empty when no fd target matches the lock")
    func linuxProbeNoMatch() {
        let fdTargets: [(pid: Int32, target: String)] = [(pid: 111, target: "/repo/.git/unrelated")]
        #expect(LockProbe.matchingHolders(fdTargets: fdTargets, lockPath: "/repo/.git/index.lock").isEmpty)
    }
}
