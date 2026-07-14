import Foundation
import Testing
@testable import OrchestraCore

/// End-to-end: the real `orchestra` CLI and `orchestra-mcp` binaries drive an in-process daemon
/// (real git + real tmux + the fake-agent adapter) over a temp socket. Proves the full stack and
/// CLI/MCP parity with the CommandRegistry.
@Suite("E2E — CLI + MCP binaries against an in-process daemon",
       .enabled(if: IntegrationSupport.gitAvailable && IntegrationSupport.tmuxAvailable), .serialized)
final class E2EBinaryTests {

    let base: String
    let tmuxSock: String
    let ctlSock: String
    let repo: String
    var server: ControlServer!
    var service: OrchestraService!
    var pollLoop: _Concurrency.Task<Void, Never>!

    init() throws {
        base = IntegrationSupport.tempDir("e2e")
        tmuxSock = "orch-e2e-\(UUID().uuidString.prefix(8))"
        ctlSock = "/tmp/orch-e2e-\(UUID().uuidString.prefix(8)).sock"
        repo = base + "/repos/app"

        // Real git repo
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try Proc.checked(["git", "-C", repo, "init", "-q", "-b", "main"])
        try Proc.checked(["git", "-C", repo, "config", "user.email", "t@t.t"])
        try Proc.checked(["git", "-C", repo, "config", "user.name", "T"])
        try "x".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        try Proc.checked(["git", "-C", repo, "add", "."])
        try Proc.checked(["git", "-C", repo, "commit", "-q", "-m", "init"])

        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)], sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let sessions = SessionManager(socket: tmuxSock, confPath: SessionManager.bundledConf, sockEnvPath: ctlSock)
        let adapter = ClaudeCodeAdapter(binOverride: IntegrationSupport.fakeAgentPath)
        service = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [adapter]),
                                   worktrees: WorktreeRegistry(config: config, borrowsPath: base + "/borrows.json",
                                                               markersDir: base + "/worktree-markers"),
                                   sessions: sessions)
        server = ControlServer(service: service, socketPath: ctlSock)
        try server.start()

        // The real daemon's 2s background poll (orchestrad/main.swift) — mirrored here (faster) so a
        // capability-gated blank spawn reaches `.live` via the N=3 liveness fallback (the fake agent fires
        // no SessionStart(startup) hook), exactly as production would drive it. Without this loop the
        // spawn would await its launch-ready signal until the grace and fail.
        let svc = service!
        pollLoop = _Concurrency.Task {
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .milliseconds(200))
                await svc.reconcile()          // Task 3: the stepping reconciler drives non-blocking spawn → live
                await svc.pollTelemetry()
            }
        }
    }

    deinit {
        pollLoop?.cancel()
        server?.stop()
        _ = try? Proc.run(["tmux", "-L", tmuxSock, "kill-server"])
    }

    // Locate a built executable next to this package's .build/debug.
    private func binary(_ name: String) -> String {
        return "\(PackageRoot.find())/.build/debug/\(name)"
    }

    /// The daemon under test is IN-PROCESS with the whole `--parallel` suite, so its RPC replies are
    /// scheduled on a machine oversubscribed by ~900 concurrent tests and thousands of git/tmux forks.
    /// Measured delays there reach 15-20s, which exceeds the CLI's default 15s RPC deadline — so `spawn`
    /// exited 1 with "daemon not reachable … did not answer version probe", a scheduling artifact that
    /// looked like a broken daemon. The deadline is client policy (see `CLIRunner.rpcTimeout`); raise it so
    /// this test asserts what the daemon DOES, not how fast the host happened to schedule it.
    private func cli(_ args: [String]) throws -> ProcResult {
        try Proc.run([binary("orchestra")] + args,
                     env: ["ORCHESTRA_SOCK": ctlSock, "ORCHESTRA_RPC_TIMEOUT_MS": "120000"])
    }

    @Test("CLI: spawn → list → exec → sessions drive real daemon state")
    func cliSmoke() throws {
        try #expect(Bool(FileManager.default.fileExists(atPath: binary("orchestra"))))

        // spawn (title seeded from the prompt, no title/desc flags)
        let spawn = try cli(["spawn", "--prompt", "Add the feature", "--repo", repo, "--branch", "feat"])
        // The CLI reports every failure as `orchestra: <msg>` on STDERR and exits 1. Asserting only on the
        // exit code threw that message away and left "spawn exits 1" unexplainable; surface it.
        #expect(spawn.exitCode == 0, "spawn failed (rc=\(spawn.exitCode)) stderr=\(spawn.stderr) stdout=\(spawn.stdout)")
        #expect(spawn.stdout.contains("orchestra://task/"))

        // list shows it
        let list = try cli(["list"])
        #expect(list.stdout.contains("Add the feature"))

        // grab the shortId from list
        let shortId = String(list.stdout.split(whereSeparator: \.isWhitespace).first ?? "")
        #expect(!shortId.isEmpty)

        // Non-blocking spawn (PR4b Task 3): the card is `.creatingWorktree`/`.launching` until the daemon's
        // reconcile loop cuts the worktree + brings the session up + confirms readiness (via the N=3
        // fallback — the fake agent fires no SessionStart hook). `exec` is gated until the card is `.live`,
        // so poll the board (~15s cap) until the card leaves `launching`/`creating`.
        for _ in 0..<75 {
            let listed = try cli(["list"])
            if listed.stdout.contains(shortId), listed.stdout.contains("running") { break }   // reached .live(.running)
            usleep(200_000)
        }
        let sessions = try cli(["sessions", shortId, "--json"])

        // exec runs in the worktree and prints the branch
        let exec = try cli(["exec", shortId, "git rev-parse --abbrev-ref HEAD"])
        #expect(exec.stdout.contains("feat"))
        #expect(exec.exitCode == 0)

        // sessions --json returns a CardSessions with the agent window
        #expect(sessions.stdout.contains("\"session\""))
        #expect(sessions.stdout.contains(":agent"))
    }

    @Test("CLI: handoff is a routed verb (not an unknown command)")
    func cliHandoffRouted() throws {
        // No ref/context → the handoff case runs and dies on the missing ref; it must NOT reach the
        // `default:` unknown-command branch. Proves the CLI switch surfaces the new verb.
        let r = try cli(["handoff"])
        #expect(r.exitCode != 0)
        #expect(!r.stdout.contains("unknown command"))
        #expect(!r.stderr.contains("unknown command"))
    }

    @Test("CLI: trust is a routed verb (not an unknown command)")
    func cliTrustRouted() throws {
        // No path → the trust case runs and dies on the missing path; it must NOT reach the
        // `default:` unknown-command branch. Proves the CLI switch surfaces the new verb.
        let r = try cli(["trust"])
        #expect(r.exitCode != 0)
        #expect(!r.stdout.contains("unknown command"))
        #expect(!r.stderr.contains("unknown command"))
    }

    @Test("CLI: `orchestra trust <path>` with a non-tty stdin fails closed with actionable text")
    func cliTrustNonInteractiveFails() throws {
        // Run the binary directly with an explicit non-tty stdin (/dev/null) so isatty is
        // deterministically false — the verb must refuse BEFORE any daemon call (so no daemon is even
        // needed here). Exit non-zero, message names the path and never a `--trust` flag.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [binary("orchestra"), "trust", "/tmp/some-untrusted-dir"]
        p.environment = ProcessInfo.processInfo.environment.merging(["ORCHESTRA_SOCK": ctlSock]) { _, b in b }
        p.standardInput = FileHandle.nullDevice          // non-tty → isatty == 0
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        p.waitUntilExit()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus != 0)
        #expect(errText.contains("some-untrusted-dir"))
        #expect(errText.contains("interactive terminal"))
        #expect(!errText.contains("--trust"))
    }

    @Test("MCP: initialize + tools/list parity with the registry; tools/call spawn creates a card")
    func mcpSmoke() throws {
        let mcp = binary("orchestra-mcp")
        try #expect(Bool(FileManager.default.fileExists(atPath: mcp)))

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"spawn","arguments":{"prompt":"From MCP","repo":"\#(repo)","branch":"mcpbranch"}}}"#,
        ].joined(separator: "\n") + "\n"

        let out = try runMCP(mcp, stdin: requests)
        let lines = out.split(whereSeparator: \.isNewline).compactMap { try? JSONValue.parse(Data($0.utf8)) }

        // tools/list (id 2) should equal the MCP-exposed command set — the `.appOnly` primitives
        // (send-keys, capture, inspect) are withheld from agents, so it is the registry set minus those.
        let toolsResp = lines.first { $0["id"]?.intValue == 2 }
        let tools = toolsResp?["result"]?["tools"]?.arrayValue ?? []
        let names = Set(tools.compactMap { $0["name"]?.stringValue })
        #expect(names == Set(CommandCatalog.mcpExposed.map(\.name)))
        #expect(!names.contains("send-keys") && !names.contains("capture") && !names.contains("inspect"))

        // tools/call spawn (id 3) returns content; the card now exists in the daemon
        let callResp = lines.first { $0["id"]?.intValue == 3 }
        #expect(callResp?["result"]?["content"] != nil)
        let list = try cli(["list"])
        #expect(list.stdout.contains("From MCP"))
    }

    /// Run the MCP binary, feed stdin, and collect stdout. The SDK server handles requests in async
    /// child tasks and exits on stdin EOF, so we keep stdin OPEN (like a real client), drain stdout for
    /// a short window, then terminate.
    private func runMCP(_ bin: String, stdin: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [bin]
        var env = ProcessInfo.processInfo.environment
        env["ORCHESTRA_SOCK"] = ctlSock
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipe()

        let acc = ByteAccumulator()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { acc.append(d) }
        }
        try p.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))   // keep stdin open
        Thread.sleep(forTimeInterval: 1.5)                    // let the server respond
        outPipe.fileHandleForReading.readabilityHandler = nil
        try? inPipe.fileHandleForWriting.close()
        p.terminate()
        return String(decoding: acc.data, as: UTF8.self)
    }
}

final class ByteAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = Data()
    func append(_ d: Data) { lock.lock(); buf.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buf }
}
