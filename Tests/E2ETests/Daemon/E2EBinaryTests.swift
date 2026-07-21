import Foundation
import Testing
import TestSupport
@testable import OrchestraCore
import OrchestraKit

/// One repo + one in-process daemon (real git + real tmux + the fake-agent adapter) over a temp socket,
/// built ONCE for the whole suite and shared by every test. Setup used to run in `init()` — i.e. per
/// test instance, five times — re-doing the git repo, the `ControlServer`, the tmux server and the poll
/// loop for each case. The daemon is an accumulating board; the tests spawn distinct branches/cards and
/// only assert on their own, so one shared daemon is sufficient and cuts the setup to a single pass. The
/// fixture is torn down once at process exit (server stop + tmux kill-server).
struct E2EDaemon: Sendable {
    let base: String
    let tmuxSock: String
    let ctlSock: String
    let repo: String
    let server: ControlServer
    let service: OrchestraService
    let pollLoop: _Concurrency.Task<Void, Never>
}

/// Suite-scoped async-lazy fixture: the first `get()` builds the daemon; every later call awaits the
/// same one. An actor serializes the "build once" check so two concurrent first-callers can't both build.
actor E2EFixture {
    static let shared = E2EFixture()
    private var built: E2EDaemon?

    func get() async throws -> E2EDaemon {
        if let built { return built }
        let d = try Self.build()
        built = d
        return d
    }

    private static func build() throws -> E2EDaemon {
        let base = IntegrationSupport.tempDir("e2e")
        let tmuxSock = "orch-e2e-\(UUID().uuidString.prefix(8))"
        let ctlSock = "/tmp/orch-e2e-\(UUID().uuidString.prefix(8)).sock"
        let repo = base + "/repos/app"

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
        let service = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                       registry: AgentRegistry(adapters: [adapter]),
                                       worktrees: WorktreeRegistry(config: config, borrowsPath: base + "/borrows.json",
                                                                   markersDir: base + "/worktree-markers"),
                                       sessions: sessions,
                               proc: RealProc(), gitRemotesProbe: OrchestraService.defaultGitRemotesProbe)
        let server = ControlServer(service: service, socketPath: ctlSock)
        try server.start()

        // The real daemon's 2s background poll (orchestrad/main.swift) — mirrored here (faster) so a
        // capability-gated blank spawn reaches `.live` via the N=3 liveness fallback (the fake agent fires
        // no SessionStart(startup) hook), exactly as production would drive it. Without this loop the
        // spawn would await its launch-ready signal until the grace and fail. (This 200ms is a faithful
        // mirror of the daemon poll, NOT an arbitrary settle — it stays a real sleep.)
        let svc = service
        let pollLoop = _Concurrency.Task {
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .milliseconds(200))
                await svc.reconcile()          // Task 3: the stepping reconciler drives non-blocking spawn → live
                await svc.pollTelemetry()
            }
        }

        // Tear the shared fixture down once, after the last test (no suite teardown in swift-testing).
        registerProcessExitCleanup {
            pollLoop.cancel()
            server.stop()
            _ = try? Proc.run(["tmux", "-L", tmuxSock, "kill-server"])
        }

        return E2EDaemon(base: base, tmuxSock: tmuxSock, ctlSock: ctlSock, repo: repo,
                         server: server, service: service, pollLoop: pollLoop)
    }
}

@Suite("E2E — CLI + MCP binaries against an in-process daemon",
       .enabled(if: IntegrationSupport.gitAvailable && IntegrationSupport.tmuxAvailable), .serialized)
struct E2EBinaryTests {

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
    private func cli(_ args: [String], ctlSock: String,
                     environment: [String: String] = [:]) throws -> ProcResult {
        // The test process itself may run inside an Orchestra card. An empty value models no usable relay
        // context while preventing that ambient card id from leaking into tests that are meant to be Human.
        var env = ["ORCHESTRA_SOCK": ctlSock, "ORCHESTRA_RPC_TIMEOUT_MS": "120000",
                   "ORCHESTRA_TASK_ID": ""]
        env.merge(environment, uniquingKeysWith: { _, incoming in incoming })
        return try Proc.run([binary("orchestra")] + args, env: env)
    }

    @Test("CLI: spawn → list → exec → sessions drive real daemon state")
    func cliSmoke() async throws {
        let fx = try await E2EFixture.shared.get()
        try #expect(Bool(FileManager.default.fileExists(atPath: binary("orchestra"))))

        // spawn (title seeded from the prompt, no title/desc flags)
        let spawn = try cli(["spawn", "--prompt", "Add the feature", "--repo", fx.repo, "--branch", "feat"], ctlSock: fx.ctlSock)
        // The CLI reports every failure as `orchestra: <msg>` on STDERR and exits 1. Asserting only on the
        // exit code threw that message away and left "spawn exits 1" unexplainable; surface it.
        #expect(spawn.exitCode == 0, "spawn failed (rc=\(spawn.exitCode)) stderr=\(spawn.stderr) stdout=\(spawn.stdout)")
        #expect(spawn.stdout.contains("orchestra://task/"))

        // list shows it
        let list = try cli(["list"], ctlSock: fx.ctlSock)
        #expect(list.stdout.contains("Add the feature"))

        // grab the shortId from the spawned card's row (the row that carries the title we just set)
        let shortId = String(list.stdout.split(whereSeparator: \.isNewline)
            .first { $0.contains("Add the feature") }?
            .split(whereSeparator: \.isWhitespace).first ?? "")
        #expect(!shortId.isEmpty)

        // Non-blocking spawn (PR4b Task 3): the card is `.creatingWorktree`/`.launching` until the daemon's
        // reconcile loop cuts the worktree + brings the session up + confirms readiness (via the N=3
        // fallback — the fake agent fires no SessionStart hook). `exec` is gated until the card is `.live`,
        // so poll the OBSERVABLE board state until the card reads `running` (was a 75×200ms usleep loop).
        try await pollUntil("card \(shortId) reaches .live(.running)", timeout: .seconds(60)) {
            let listed = try? cli(["list"], ctlSock: fx.ctlSock)
            let out = listed?.stdout ?? ""
            return out.contains(shortId) && out.lowercased().contains("running")   // list renders the phase title-cased ("Running")
        }
        let sessions = try cli(["sessions", shortId, "--json"], ctlSock: fx.ctlSock)

        // exec runs in the worktree and prints the branch
        let exec = try cli(["exec", shortId, "git rev-parse --abbrev-ref HEAD"], ctlSock: fx.ctlSock)
        #expect(exec.stdout.contains("feat"))
        #expect(exec.exitCode == 0)

        // sessions --json returns a CardSessions with the agent window
        #expect(sessions.stdout.contains("\"session\""))
        #expect(sessions.stdout.contains(":agent"))
    }

    @Test("CLI: handoff is a routed verb (not an unknown command)")
    func cliHandoffRouted() async throws {
        let fx = try await E2EFixture.shared.get()
        // No ref/context → the handoff case runs and dies on the missing ref; it must NOT reach the
        // `default:` unknown-command branch. Proves the CLI switch surfaces the new verb.
        let r = try cli(["handoff"], ctlSock: fx.ctlSock)
        #expect(r.exitCode != 0)
        #expect(!r.stdout.contains("unknown command"))
        #expect(!r.stderr.contains("unknown command"))
    }

    @Test("CLI: trust is a routed verb (not an unknown command)")
    func cliTrustRouted() async throws {
        let fx = try await E2EFixture.shared.get()
        // No path → the trust case runs and dies on the missing path; it must NOT reach the
        // `default:` unknown-command branch. Proves the CLI switch surfaces the new verb.
        let r = try cli(["trust"], ctlSock: fx.ctlSock)
        #expect(r.exitCode != 0)
        #expect(!r.stdout.contains("unknown command"))
        #expect(!r.stderr.contains("unknown command"))
    }

    @Test("CLI: `orchestra trust <path>` with a non-tty stdin fails closed with actionable text")
    func cliTrustNonInteractiveFails() async throws {
        let fx = try await E2EFixture.shared.get()
        // Run the binary directly with an explicit non-tty stdin (/dev/null) so isatty is
        // deterministically false — the verb must refuse BEFORE any daemon call (so no daemon is even
        // needed here). Exit non-zero, message names the path and never a `--trust` flag.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [binary("orchestra"), "trust", "/tmp/some-untrusted-dir"]
        p.environment = ProcessInfo.processInfo.environment.merging(["ORCHESTRA_SOCK": fx.ctlSock]) { _, b in b }
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

    @Test("CLI and MCP send persist source only from their bridge card context")
    func sendSourceAttribution() async throws {
        let fx = try await E2EFixture.shared.get()
        let suffix = UUID().uuidString.lowercased()
        let sender = try await fx.service.spawn(SpawnInput(
            id: UUID(), prompt: "binary sender", repo: fx.repo, branch: "binary-sender-\(suffix)"))
        let recipient = try await fx.service.spawn(SpawnInput(
            id: UUID(), prompt: "binary recipient", repo: fx.repo, branch: "binary-recipient-\(suffix)"))
        let spoofedSender = try await fx.service.spawn(SpawnInput(
            id: UUID(), prompt: "spoofed sender", repo: fx.repo, branch: "binary-spoofed-\(suffix)"))

        let humanCLI = try cli(["send", recipient.shortId, "human CLI"], ctlSock: fx.ctlSock)
        #expect(humanCLI.exitCode == 0,
                "human CLI send failed (rc=\(humanCLI.exitCode)) stderr=\(humanCLI.stderr)")

        let cardCLI = try cli(["send", recipient.shortId, "card CLI"], ctlSock: fx.ctlSock,
                               environment: ["ORCHESTRA_TASK_ID": sender.id.uuidString])
        #expect(cardCLI.exitCode == 0,
                "card CLI send failed (rc=\(cardCLI.exitCode)) stderr=\(cardCLI.stderr)")

        let noContextMCP = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send","arguments":{"ref":"\#(recipient.shortId)","message":"human MCP","senderCard":"\#(sender.id.uuidString)"}}}"#,
        ].joined(separator: "\n") + "\n"
        _ = try await runMCP(binary("orchestra-mcp"), stdin: noContextMCP, ctlSock: fx.ctlSock)

        let cardContextMCP = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send","arguments":{"ref":"\#(recipient.shortId)","message":"card MCP","senderCard":"\#(spoofedSender.id.uuidString)"}}}"#,
        ].joined(separator: "\n") + "\n"
        _ = try await runMCP(binary("orchestra-mcp"), stdin: cardContextMCP, ctlSock: fx.ctlSock,
                              environment: ["ORCHESTRA_TASK_ID": sender.id.uuidString])

        let messages = try await fx.service.inboxPeek(recipient.id)
        #expect(messages.map(\.text) == ["human CLI", "card CLI", "human MCP", "card MCP"])
        #expect(messages[0].source == .human)
        #expect(messages[1].source == .card(id: sender.id, title: sender.title))
        #expect(messages[2].source == .human)
        #expect(messages[3].source == .card(id: sender.id, title: sender.title))
    }

    @Test("MCP: initialize + tools/list parity with the registry; tools/call spawn creates a card")
    func mcpSmoke() async throws {
        let fx = try await E2EFixture.shared.get()
        let mcp = binary("orchestra-mcp")
        try #expect(Bool(FileManager.default.fileExists(atPath: mcp)))

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"spawn","arguments":{"prompt":"From MCP","repo":"\#(fx.repo)","branch":"mcpbranch"}}}"#,
        ].joined(separator: "\n") + "\n"

        let out = try await runMCP(mcp, stdin: requests, ctlSock: fx.ctlSock)
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
        let list = try cli(["list"], ctlSock: fx.ctlSock)
        #expect(list.stdout.contains("From MCP"))
    }

    @Test("MCP: publish-image renders the shared transcript marker, not raw JSON")
    func mcpPublishImageReturnsTranscriptMarker() async throws {
        let fx = try await E2EFixture.shared.get()
        let mcp = binary("orchestra-mcp")
        try #expect(Bool(FileManager.default.fileExists(atPath: mcp)))

        let imagePath = fx.base + "/mcp-image.png"
        let minimalPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try minimalPNG.write(to: URL(fileURLWithPath: imagePath))

        let branch = "mcp-image-\(UUID().uuidString.lowercased())"
        let spawn = try cli(["spawn", "--prompt", "MCP image marker", "--repo", fx.repo,
                             "--branch", branch], ctlSock: fx.ctlSock)
        #expect(spawn.exitCode == 0,
                "spawn failed (rc=\(spawn.exitCode)) stderr=\(spawn.stderr) stdout=\(spawn.stdout)")
        let ref = spawn.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(ref.hasPrefix("orchestra://task/"))

        try await pollUntil("MCP image card \(ref) reaches .live", timeout: .seconds(60)) {
            guard let card = try? await fx.service.resolveRef(ref) else { return false }
            return card.phase.kind == .live
        }

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"publish-image","arguments":{"ref":"\#(ref)","path":"\#(imagePath)","caption":"diagram"}}}"#,
        ].joined(separator: "\n") + "\n"

        let out = try await runMCP(mcp, stdin: requests, ctlSock: fx.ctlSock)
        let lines = out.split(whereSeparator: \.isNewline)
            .compactMap { try? JSONValue.parse(Data($0.utf8)) }
        let callResp = lines.first { $0["id"]?.intValue == 3 }
        let marker = callResp?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        #expect(marker != nil)

        let markerURL = marker?.split(separator: " ").last.map(String.init)
        let referenceID = markerURL.flatMap(TranscriptImageLink.referenceID(from:))
        #expect(referenceID != nil)
        if let marker, let referenceID {
            let card = try await fx.service.resolveRef(ref)
            let payload = try await fx.service.transcriptImage(card.id, referenceID: referenceID)
            #expect(payload.reference.id == referenceID)
            #expect(payload.reference.caption == "diagram")
            #expect(marker == TranscriptImageMarker.render(referenceID: referenceID, caption: "diagram"))
        }
    }

    /// Run the MCP binary, feed stdin, and collect stdout. The SDK server handles requests in async
    /// child tasks and exits on stdin EOF, so we keep stdin OPEN (like a real client), poll stdout until
    /// the last request's response (id 3) has arrived (was a fixed 1.5s Thread.sleep), then terminate.
    private func runMCP(_ bin: String, stdin: String, ctlSock: String,
                        environment: [String: String] = [:]) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [bin]
        var env = ProcessInfo.processInfo.environment
        env["ORCHESTRA_SOCK"] = ctlSock
        // Keep an enclosing card's context out of a bridge test unless the test explicitly injects one.
        env["ORCHESTRA_TASK_ID"] = ""
        env.merge(environment, uniquingKeysWith: { _, incoming in incoming })
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
        // Poll the OBSERVABLE condition instead of a fixed settle. The SDK server answers each request in
        // an async CHILD TASK, so responses can arrive out of order — id:3 (spawn) can land before id:2
        // (tools/list). Both are the responses this test asserts on, so wait until BOTH are present (was a
        // fixed 1.5s Thread.sleep, which risked cutting off a still-in-flight response under load).
        try? await pollUntil("MCP id:2 + id:3 responses", timeout: .seconds(30)) {
            let text = String(decoding: acc.data, as: UTF8.self)
            let lines = text.split(whereSeparator: \.isNewline).compactMap { try? JSONValue.parse(Data($0.utf8)) }
            let ids = Set(lines.compactMap { $0["id"]?.intValue })
            return ids.isSuperset(of: [2, 3])
        }
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
