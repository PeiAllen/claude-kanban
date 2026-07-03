import Foundation
import Testing
@testable import OrchestraCore

/// Records launchctl invocations instead of touching the real user agent.
final class LaunchdMock: Launchctl, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    func run(_ args: [String]) throws -> ProcResult {
        lock.withLock { calls.append(args) }
        return ProcResult(stdout: "", stderr: "", exitCode: 0)
    }
}

@Suite("DaemonLifecycle — install/load/uninstall logic (mocked launchctl)")
struct DaemonLifecycleTests {

    private func tempPaths() -> (plist: String, sock: String) {
        let base = NSTemporaryDirectory() + "orch-ld-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return (base + "/com.orchestra.daemon.plist", "/tmp/orch-\(UUID().uuidString.prefix(8)).sock")
    }

    @Test("install writes a rendered plist and bootstraps + enables")
    func install() throws {
        let mock = LaunchdMock()
        let (plist, sock) = tempPaths()
        let life = DaemonLifecycle(launchctl: mock, plistPath: plist, socketPath: sock)
        try life.install(orchestradBin: "/usr/local/bin/orchestrad", logPath: NSTemporaryDirectory() + "orchestrad.log")

        let written = try String(contentsOfFile: plist, encoding: .utf8)
        #expect(written.contains("/usr/local/bin/orchestrad"))
        #expect(written.contains("com.orchestra.daemon"))
        #expect(written.contains("RunAtLoad"))
        #expect(mock.calls.contains { $0.first == "bootstrap" })
        #expect(mock.calls.contains { $0.first == "enable" })
    }

    @Test("isRunning is false with no daemon on the socket")
    func notRunning() {
        let mock = LaunchdMock()
        let (plist, sock) = tempPaths()
        let life = DaemonLifecycle(launchctl: mock, plistPath: plist, socketPath: sock)
        #expect(!life.isRunning())
    }

    @Test("ensureRunning installs when not running")
    func ensureInstalls() throws {
        let mock = LaunchdMock()
        let (plist, sock) = tempPaths()
        let life = DaemonLifecycle(launchctl: mock, plistPath: plist, socketPath: sock)
        try life.ensureRunning(orchestradBin: "/bin/orchestrad")
        #expect(FileManager.default.fileExists(atPath: plist))
        #expect(mock.calls.contains { $0.first == "bootstrap" })
    }

    @Test("uninstall boots out and removes the plist")
    func uninstall() throws {
        let mock = LaunchdMock()
        let (plist, sock) = tempPaths()
        let life = DaemonLifecycle(launchctl: mock, plistPath: plist, socketPath: sock)
        try life.install(orchestradBin: "/bin/orchestrad")
        life.uninstall()
        #expect(!FileManager.default.fileExists(atPath: plist))
        #expect(mock.calls.contains { $0.first == "bootout" })
    }

    @Test("HooksRenderer substitutes the orchestra binary path")
    func hooksRender() throws {
        let dest = NSTemporaryDirectory() + "orch-hooks-\(UUID().uuidString).json"
        try HooksRenderer.render(orchestraBin: "/opt/orchestra", agentId: "claude-code", to: dest)
        let s = try String(contentsOfFile: dest, encoding: .utf8)
        #expect(s.contains("/opt/orchestra _report --event statusline --agent claude-code"))
        #expect(!s.contains("__ORCHESTRA_BIN__"))
        #expect(!s.contains("__AGENT_ID__"))
        // the event vocabulary is split (distinct notification/stop, pretool/posttool)
        #expect(s.contains("--event stop --agent claude-code"))
        #expect(s.contains("--event notification --agent claude-code"))
        #expect(s.contains("--event pretool --agent claude-code"))
        #expect(s.contains("--event posttool --agent claude-code"))
        // valid JSON
        #expect(throws: Never.self) { _ = try JSONValue.parse(Data(s.utf8)) }
    }
}
