import Foundation
import Testing

/// Regression: the hidden `orchestra _report` helper (statusLine + hooks) writes its output to a
/// stdout pipe that Claude captures. A self-close (`archive`) kills the agent's tmux session — and
/// that pipe — the instant the helper runs. `FileHandle.write` RAISES an uncatchable ObjC
/// `NSFileHandleOperationException` on the resulting EPIPE (Swift `try?` can't catch it →
/// `terminate()` → SIGABRT → the "orchestra quit unexpectedly" popup); a raw `write(2)` without
/// SIGPIPE-ignore would instead die with signal 13. The helper is contractually best-effort and must
/// survive BOTH modes. This spawns the real binary against a dead stdout pipe and asserts a clean
/// exit 0. Without the fix the child dies by signal (SIGABRT/SIGPIPE) and this fails.
@Suite("ReportHelper — never crashes on a broken stdout pipe (self-close)", .serialized)
struct ReportHelperPipeTests {

    private func binary(_ name: String) -> String {
        return "\(PackageRoot.find())/.build/debug/\(name)"
    }

    @Test("`_report --event statusline` writing to a closed stdout pipe exits 0, never crashes")
    func statuslineBrokenPipeDoesNotCrash() throws {
        let bin = binary("orchestra")
        try #require(FileManager.default.fileExists(atPath: bin))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["_report", "--event", "statusline"]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        try p.run()
        // The reader is gone: close every read end so the helper's stdout write hits EPIPE. The
        // helper blocks on reading stdin first, so it can't write until after the EOF below — by
        // which point there is no reader left.
        try? outPipe.fileHandleForReading.close()
        inPipe.fileHandleForWriting.write(
            Data(#"{"model":{"display_name":"x"},"context_window":{"used_percentage":42}}"#.utf8))
        try? inPipe.fileHandleForWriting.close()
        p.waitUntilExit()

        // Before the fix: terminationReason == .uncaughtSignal (SIGABRT=6 or SIGPIPE=13).
        #expect(p.terminationReason == .exit)
        #expect(p.terminationStatus == 0)
    }
}
