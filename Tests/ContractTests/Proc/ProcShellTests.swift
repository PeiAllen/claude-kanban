import Foundation
import Testing
@testable import OrchestraCore

/// `Proc.runShell` backs the passthrough statusLine: it runs the user's global statusLine command,
/// feeding it the event JSON on stdin and returning its output. Real statusLine scripts (e.g. ccusage
/// cost lookups) routinely take 2-4s; an over-tight timeout made passthrough always fall back to the
/// orchestra default, which is the regression these tests guard.
struct ProcShellTests {

    @Test("a command slower than 1s still returns its output (passthrough regression)")
    func slowCommandIsNotCutOffAtOneSecond() {
        let out = Proc.runShell("sleep 1.5; cat; printf READY",
                                stdin: Data("X".utf8), timeout: .seconds(5))
        #expect(out == "XREADY")
    }

    @Test("a genuinely hung command is bounded by the timeout and yields nil")
    func hungCommandTimesOut() {
        let out = Proc.runShell("sleep 5", stdin: Data(), timeout: .milliseconds(300))
        #expect(out == nil)
    }

    @Test("a non-zero exit yields nil so the caller can fall back")
    func nonZeroExitYieldsNil() {
        let out = Proc.runShell("exit 3", stdin: Data(), timeout: .seconds(2))
        #expect(out == nil)
    }
}
