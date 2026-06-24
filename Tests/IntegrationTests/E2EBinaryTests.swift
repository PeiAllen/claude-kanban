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
                            allowlist: [PathResolver.canonical(base)])
        let sessions = SessionManager(socket: tmuxSock, confPath: SessionManager.bundledConf, sockEnvPath: ctlSock)
        let adapter = ClaudeCodeAdapter(binOverride: IntegrationSupport.fakeAgentPath)
        service = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [adapter]),
                                   worktrees: WorktreeManager(config: config), sessions: sessions)
        server = ControlServer(service: service, socketPath: ctlSock)
        try server.start()
    }

    deinit {
        server?.stop()
        _ = try? Proc.run(["tmux", "-L", tmuxSock, "kill-server"])
    }

    // Locate a built executable next to this package's .build/debug.
    private func binary(_ name: String) -> String {
        let pkgRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        return "\(pkgRoot)/.build/debug/\(name)"
    }

    private func cli(_ args: [String]) throws -> ProcResult {
        try Proc.run([binary("orchestra")] + args, env: ["ORCHESTRA_SOCK": ctlSock])
    }

    @Test("CLI: spawn → list → exec → sessions drive real daemon state")
    func cliSmoke() throws {
        try #expect(Bool(FileManager.default.fileExists(atPath: binary("orchestra"))))

        // spawn (title seeded from the prompt, no title/desc flags)
        let spawn = try cli(["spawn", "--prompt", "Add the feature", "--repo", repo, "--branch", "feat"])
        #expect(spawn.exitCode == 0)
        #expect(spawn.stdout.contains("orchestra://task/"))

        // list shows it
        let list = try cli(["list"])
        #expect(list.stdout.contains("Add the feature"))

        // grab the shortId from list
        let shortId = String(list.stdout.split(whereSeparator: \.isWhitespace).first ?? "")
        #expect(!shortId.isEmpty)

        // exec runs in the worktree and prints the branch
        let exec = try cli(["exec", shortId, "git rev-parse --abbrev-ref HEAD"])
        #expect(exec.stdout.contains("feat"))
        #expect(exec.exitCode == 0)

        // sessions --json returns a CardSessions with the agent window
        let sessions = try cli(["sessions", shortId, "--json"])
        #expect(sessions.stdout.contains("\"session\""))
        #expect(sessions.stdout.contains(":agent"))
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

        // tools/list (id 2) should equal the registry's command set
        let toolsResp = lines.first { $0["id"]?.intValue == 2 }
        let tools = toolsResp?["result"]?["tools"]?.arrayValue ?? []
        let names = Set(tools.compactMap { $0["name"]?.stringValue })
        #expect(names == Set(CommandRegistry().names))

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
