import Foundation
import Darwin
import Testing
import TestSupport
@testable import OrchestraCore

@Suite("Codex app-server launcher", .enabled(if: IntegrationSupport.hasTool("python3")), .serialized)
struct CodexAppServerLauncherTests {
    @Test("a successor waits for predecessor cleanup before reusing its socket")
    func successorWaitsForPredecessorCleanup() async throws {
        // AF_UNIX socket pathnames are short on macOS. IntegrationSupport.tempDir includes a
        // long UUID-bearing prefix, so keep this private fixture directory deliberately short.
        let root = "/tmp/orch-codex-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let socket = "\(root)/codex.sock"
        let oldLog = "\(root)/old.log"
        let oldReady = "\(root)/old-ready"
        let oldEntered = "\(root)/old-entered"
        let oldTerm = "\(root)/old-term"
        let oldDone = "\(root)/old-done"
        let oldStop = "\(root)/old-stop-unused"
        let newLog = "\(root)/new.log"
        let newReady = "\(root)/new-ready"
        let newEntered = "\(root)/new-entered"
        let newTerm = "\(root)/new-term"
        let newDone = "\(root)/new-done"
        let newStop = "\(root)/new-stop"

        let old = try launch(
            socket: socket,
            log: oldLog,
            serverReady: oldReady,
            serverTerm: oldTerm,
            serverDone: oldDone,
            shutdownDelay: "2",
            clientEntered: oldEntered,
            clientStop: oldStop,
            clientMode: "exit"
        )
        var successor: RunningLauncher?

        defer {
            old.stop()
            touch(newStop)
            successor?.stop()
        }

        try await pollUntil("predecessor client entered", timeout: .seconds(8)) {
            FileManager.default.fileExists(atPath: oldEntered)
        }
        try await pollUntil("predecessor cleanup started", timeout: .seconds(8)) {
            FileManager.default.fileExists(atPath: oldTerm)
        }

        successor = try launch(
            socket: socket,
            log: newLog,
            serverReady: newReady,
            serverTerm: newTerm,
            serverDone: newDone,
            shutdownDelay: "0",
            clientEntered: newEntered,
            clientStop: newStop,
            clientMode: "hold"
        )

        try await pollUntil("successor server became ready", timeout: .seconds(8)) {
            FileManager.default.fileExists(atPath: newReady)
        }

        #expect(!old.process.isRunning)
        #expect(old.waitForExit(), "predecessor exit notification did not arrive")
        #expect(FileManager.default.fileExists(atPath: socket))
    }

    private func launch(
        socket: String,
        log: String,
        serverReady: String,
        serverTerm: String,
        serverDone: String,
        shutdownDelay: String,
        clientEntered: String,
        clientStop: String,
        clientMode: String
    ) throws -> RunningLauncher {
        let server = try #require(fixture("codex-launcher-server", extension: "py"))
        let client = try #require(fixture("codex-launcher-client", extension: "py"))
        let launcher = try #require(launcherPath())

        let serverArgv = [
            "/usr/bin/env", "python3", server, socket, serverReady, serverTerm, serverDone, shutdownDelay,
        ]
        let clientArgv = [
            "/usr/bin/env", "python3", client, serverReady, clientEntered, clientStop, clientMode,
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launcher, socket, log, "\(serverArgv.count)"] + serverArgv + clientArgv
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        return try RunningLauncher(process: process)
    }

    private struct RunningLauncher {
        let process: Process
        let exited: DispatchGroup

        init(process: Process) throws {
            self.process = process
            let exited = DispatchGroup()
            self.exited = exited
            exited.enter()
            process.terminationHandler = { _ in exited.leave() }
            try process.run()
        }

        func waitForExit() -> Bool {
            exited.wait(timeout: .now() + .seconds(8)) == .success
        }

        func stop() {
            if process.isRunning { process.terminate() }
            // The full concurrent suite exposed waitUntilExit() stuck in Foundation after the
            // launcher and its children had exited. Observe the handler with a bounded wait,
            // as Proc does, so failed cleanup reports an issue instead of hanging the suite.
            guard !waitForExit() else { return }
            Issue.record("launcher cleanup did not finish within eight seconds")
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            #expect(exited.wait(timeout: .now() + .seconds(2)) == .success,
                    "launcher exit notification did not arrive after forced cleanup")
        }
    }

    private func launcherPath() -> String? {
        let context = AdapterContext(
            cwd: "/tmp/codex-launcher-test",
            observationEndpoint: .unixSocket(path: "/tmp/codex-launcher-test.sock")
        )
        return CodexLaunchConfiguration.appServerLaunch(
            binary: "codex",
            context: context,
            agentId: "codex",
            clientArguments: [],
            positional: []
        )?.argv.dropFirst().first
    }

    private func fixture(_ name: String, extension: String) -> String? {
        Bundle.module.path(forResource: "Fixtures/\(name)", ofType: `extension`)
            ?? Bundle.module.path(forResource: name, ofType: `extension`)
    }

    private func touch(_ path: String) {
        FileManager.default.createFile(atPath: path, contents: Data())
    }
}
