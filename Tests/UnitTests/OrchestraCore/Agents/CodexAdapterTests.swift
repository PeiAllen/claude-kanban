import Foundation
import Testing
@testable import OrchestraCore

@Suite("CodexAdapter — argv, capabilities, registry")
struct CodexAdapterArgvTests {
    let adapter = CodexAdapter()

    // True iff `flag` is immediately followed by `value` in argv.
    private func adjacent(_ argv: [String], _ flag: String, _ value: String) -> Bool {
        guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return false }
        return argv[i + 1] == value
    }

    // The value immediately following `flag` in argv (e.g. the `-p` profile name), or nil.
    private func value(after flag: String, in argv: [String]) -> String? {
        guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
        return argv[i + 1]
    }

    /// Run the REAL launch prep into an isolated Codex home and return the profile file's TOML lines
    /// alongside the argv. This asserts on the SAME hooks/trust/instructions the branch used to inline
    /// via `-c`, now delivered through the file `prepareToLaunch` writes and `-p` selects — the
    /// indirection that keeps a ~16KB payload off tmux's ~16KB command line. `hookTrustBypass:` is forced
    /// so the helper never forks a real `codex --help` probe.
    private func profile(_ ctx: AdapterContext, resume: Bool = false) throws
        -> (name: String, lines: [String], argv: [String]) {
        let home = NSTemporaryDirectory() + "codexcfg-\(UUID().uuidString)"
        let a = CodexAdapter(codexHome: home, hookTrustBypass: false)
        try a.prepareToLaunch(ctx)
        let argv = resume ? try #require(a.resume(ctx)) : a.start(ctx)
        let name = try #require(value(after: "-p", in: argv))
        let body = try String(contentsOfFile: "\(home)/\(name).config.toml", encoding: .utf8)
        return (name, body.split(separator: "\n").map(String.init), argv)
    }

    @Test("registry resolves agentId=codex")
    func registryResolvesCodex() throws {
        let reg = AgentRegistry()
        #expect(try reg.get("codex").id == "codex")
        #expect(reg.list().contains { $0.id == "codex" })
        #expect(try reg.get("claude-code").id == "claude-code")   // both registered
    }

    @Test("capabilities are Codex's discovered/fileTail tuple")
    func capabilities() {
        let c = CodexAdapter().capabilities
        #expect(c == .codex)
        #expect(c.sessionId == .discovered)
        #expect(c.telemetry == .fileTail)
        #expect(c.contextUsage == .tokens)
        #expect(c.readOnlyEnforcement == .sandboxed)
        #expect(c.authMode == .subscription)
        #expect(c.terminalImagePaste == .controlV)
    }

    @Test("discovered agents do not mint a session id")
    func newSessionIdIsNil() {
        #expect(CodexAdapter().newSessionId() == nil)
    }

    @Test("rendered Codex hooks omit the retired Stop callback")
    func omitsStopHook() throws {
        let json = HooksRenderer.renderedCodexJSON(orchestraBin: "/usr/local/bin/orchestra", agentId: "codex")
        #expect(!json.contains("\"Stop\""))
        #expect(!json.contains("_report --event stop --agent codex"))
        #expect(!json.contains("__AGENT_ID__"))   // fully substituted
    }

    @Test("PermissionRequest bypasses metadata parsing and is state-silent")
    func permissionHookSignal() {
        let raw = RawTelemetry.hooksPush(kind: "permission", payload: .object([:]))
        #expect(adapter.parse(raw) == nil)
        #expect(adapter.agentSignals(
            from: raw,
            context: .init(sessionEpoch: 1, harnessSessionId: "thread")
        ).isEmpty)
    }

    @Test("SessionStart is lifecycle-only; app-server thread/started owns Codex identity")
    func parseSessionStartHook() {
        let payload: JSONValue = .object([
            "session_id": .string("hook-invocation-id"),
            "source": .string("startup"),
            "cwd": .string("/same/freeform/cwd"),
        ])
        #expect(adapter.parse(.hooksPush(kind: "session", payload: payload))
            == StatusReport(sessionSource: "startup"))
        #expect(adapter.parse(.hooksPush(kind: "session", payload: .object([:]))) == nil)

        let started: JSONValue = .object([
            "thread": .object([
                "id": .string("thread-1"),
                "sessionId": .string("thread-1"),
                "status": .object(["type": .string("idle")]),
            ]),
        ])
        #expect(adapter.parse(.rpcNotification(method: "thread/started", params: started))
            == StatusReport(sessionId: "thread-1"))
        #expect(adapter.parse(.rpcResponse(
            method: "thread/read",
            result: .object(["thread": started["thread"]!])
        )) == StatusReport(sessionId: "thread-1"))
    }

    @Test("fileTail turn-complete is ignored because app-server owns turn state")
    func fileTailTurnCompleteIgnored() {
        let line = #"{"type":"turn_complete","timestamp":"2026-07-04T10:00:00Z"}"#
        #expect(adapter.parse(.fileTail(line: line)) == nil)
    }

    @Test("rendered Codex hooks leave permission state to app-server")
    func rendersPermissionHook() throws {
        let json = HooksRenderer.renderedCodexJSON(orchestraBin: "/usr/local/bin/orchestra", agentId: "codex")
        #expect(!json.contains("\"PermissionRequest\""))
        #expect(!json.contains("_report --event permission --agent codex"))
        #expect(!json.contains("__AGENT_ID__"))   // fully substituted
    }

    @Test("models() is non-empty")
    func models() { #expect(!adapter.models().isEmpty) }

    @Test("start(ctx) for a default card: model, trailing prompt, and NO read-only clamp")
    func startArgv() {
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-6-astra",
                                 prompt: "Add OAuth login\nwith Google")
        let argv = adapter.start(ctx)
        #expect(argv.first == "codex")
        #expect(!argv.contains("read-only"))                   // default = Codex's own permissioning
        #expect(!argv.contains("never"))
        #expect(adjacent(argv, "-m", "gpt-6-astra"))
        #expect(argv.last == "Add OAuth login\nwith Google")   // launch positional prompt
    }

    @Test("Codex declares one short per-card Unix endpoint for its app-server observer")
    func observationEndpoint() {
        #expect(adapter.observationEndpoint(.init(cardId: UUID(), cardRef: "abc12345", sessionEpoch: 2,
                                                  runtimeStateDir: "/runtime")) ==
                .unixSocket(path: "/runtime/codex-abc12345.sock"))
    }

    @Test("an observation endpoint wraps the stock TUI around a launch-local app-server without inlining guidance")
    func appServerLaunch() throws {
        let testAdapter = CodexAdapter(binOverride: "codex", hookTrustBypass: false)
        let ctx = AdapterContext(
            cwd: "/wt/with spaces",
            model: "gpt-6-astra",
            prompt: "go",
            orchestraBin: "/abs/orchestra",
            access: .readOnly,
            trustCwd: false,
            orchestraMCPBin: "/abs/orchestra-mcp",
            observationEndpoint: .unixSocket(path: "/runtime/codex-card.sock")
        )
        let plan = try #require(CodexLaunchConfiguration.appServerLaunch(
            binary: "codex",
            context: ctx,
            agentId: "codex",
            clientArguments: CodexLaunchConfiguration.flags(cwd: ctx.cwd)
                + ["-s", "read-only", "-a", "never", "-m", "gpt-6-astra"],
            positional: ["go"]
        ))

        #expect(plan.socketPath == "/runtime/codex-card.sock")
        #expect(plan.serverArgv.starts(with: ["codex", "app-server", "--listen",
                                               "unix:///runtime/codex-card.sock"]))
        #expect(plan.serverArgv.contains { $0.contains("hooks.SessionStart=") })
        #expect(plan.serverArgv.contains { $0.contains("mcp_servers.orchestra.command=") &&
                                           $0.contains("/abs/orchestra-mcp") })
        #expect(plan.serverArgv.contains { $0.contains("mcp_servers.orchestra.disabled_tools=") &&
                                           $0.contains("exec") })
        #expect(!plan.serverArgv.contains { $0.contains(".trust_level=") })
        #expect(!plan.serverArgv.contains { $0.contains("developer_instructions") })
        #expect(adjacent(plan.clientArgv, "--remote", "unix:///runtime/codex-card.sock"))
        #expect(adjacent(plan.clientArgv, "-C", "/wt/with spaces"))
        #expect(plan.argv.first == "/bin/bash")
        #expect(plan.argv.joined(separator: " ").count < 4_000)
        #expect(testAdapter.start(ctx) == plan.argv)
    }

    @Test("start and resume select the same profile file without shadowing untrusted native project trust")
    func launchScopedConfigIsSharedByStartAndResume() throws {
        let cwd = "/wt/with \"quote\" and \\ slash"
        let ctx = AdapterContext(cwd: cwd, model: "gpt-6-astra", sessionId: "sess-9", prompt: "go",
                                 orchestraBin: "/abs/orchestra", trustCwd: false,
                                 orchestraMCPBin: "/abs/orchestra-mcp")
        let start = try profile(ctx)
        let resume = try profile(ctx, resume: true)

        // Both launches select the SAME per-cwd profile, and neither inlines the 16KB payload via `-c`.
        #expect(start.name == resume.name)
        #expect(start.lines == resume.lines)
        #expect(!start.argv.contains("-c"))
        #expect(!resume.argv.contains("-c"))

        let lines = start.lines
        #expect(!lines.contains { $0.contains(".trust_level") })
        #expect(lines.contains { $0.hasPrefix("hooks.SessionStart = ") && $0.contains("_report --event session --agent codex") })
        #expect(!lines.contains { $0.hasPrefix("hooks.PermissionRequest = ") })
        #expect(!lines.contains { $0.hasPrefix("hooks.Stop = ") })
        #expect(lines.contains("[mcp_servers.orchestra]"))
        #expect(lines.contains("command = \"/abs/orchestra-mcp\""))
        #expect(lines.contains("default_tools_approval_mode = \"approve\""))
        #expect(!lines.contains("disabled_tools = [\"exec\"]"))
        let instructions = try #require(lines.first { $0.hasPrefix("developer_instructions = ") })
        #expect(instructions.contains("Orchestra delegation"))
        #expect(instructions.contains("Working in a branch tree"))
    }

    @Test("read-only launch profile approves Orchestra MCP and disables exec")
    func readOnlyProfileDisablesExec() throws {
        let result = try profile(AdapterContext(cwd: "/wt/read-only", access: .readOnly,
                                                orchestraMCPBin: "/abs/orchestra-mcp"))

        #expect(result.lines.contains("[mcp_servers.orchestra]"))
        #expect(result.lines.contains("command = \"/abs/orchestra-mcp\""))
        #expect(result.lines.contains("default_tools_approval_mode = \"approve\""))
        #expect(result.lines.contains("disabled_tools = [\"exec\"]"))
    }

    @Test("trusted Codex launches explicitly set project trust in both configuration surfaces")
    func trustedContextSetsProjectTrust() throws {
        let trusted = try profile(AdapterContext(cwd: "/wt", trustCwd: true))
        #expect(trusted.lines.contains("projects.\"/wt\".trust_level = \"trusted\""))

        let context = AdapterContext(cwd: "/wt", trustCwd: true,
                                     observationEndpoint: .unixSocket(path: "/runtime/codex-card.sock"))
        let launch = try #require(CodexLaunchConfiguration.appServerLaunch(
            binary: "codex", context: context, agentId: "codex", clientArguments: [], positional: []))
        #expect(launch.serverArgv.contains("projects.\"/wt\".trust_level=\"trusted\""))
    }

    @Test("the launch selects a per-cwd `-p` profile, deterministic and free of the 16KB inline payload")
    func profileFlagIsDeterministicPerCwd() throws {
        let a = try profile(AdapterContext(cwd: "/wt/alpha"))
        let again = try profile(AdapterContext(cwd: "/wt/alpha"))
        let other = try profile(AdapterContext(cwd: "/wt/beta"))
        #expect(a.name == again.name)                 // deterministic per worktree
        #expect(a.name != other.name)                 // distinct worktrees → distinct profiles
        #expect(a.name.hasPrefix("orch-"))            // namespaced so it can't collide with a user profile
        #expect(adjacent(a.argv, "-p", a.name))       // argv actually selects it
        // The whole point: the argv stays tiny — the 16KB developer instructions live in the file, not here.
        #expect(a.argv.joined(separator: " ").count < 200)
    }

    @Test("TOML launch overrides escape strings and render nested hook values deterministically")
    func tomlOverrideEncoding() {
        #expect(TOMLOverride.string("quote \" slash \\ newline\n tab\t") ==
                "\"quote \\\" slash \\\\ newline\\n tab\\t\"")
        #expect(TOMLOverride.quotedKey("/wt/\"quoted\"") == "\"/wt/\\\"quoted\\\"\"")
        let hook: JSONValue = .object([
            "hooks": .array([
                .object([
                    "type": .string("command"),
                    "command": .string("/bin/orchestra _report --event session"),
                ]),
            ]),
        ])
        #expect(TOMLOverride.value(hook) ==
                "{hooks = [{command = \"/bin/orchestra _report --event session\", type = \"command\"}]}")
        #expect(TOMLOverride.value(.null) == nil)
    }

    @Test("start honors ctx.access: default launches unclamped, read-only applies the RO preset")
    func startAccessGated() {
        let rw = adapter.start(AdapterContext(cwd: "/wt", access: .readWrite))
        #expect(!rw.contains("read-only"))                     // default permissioning, no clamp
        #expect(!rw.contains("never"))
        let ro = adapter.start(AdapterContext(cwd: "/wt", access: .readOnly))
        #expect(adjacent(ro, "-s", "read-only"))               // read-only card → sandboxed RO preset
        #expect(adjacent(ro, "-a", "never"))
    }

    @Test("start with no prompt has no trailing positional")
    func startNoPrompt() {
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-6-astra", prompt: nil)
        let argv = adapter.start(ctx)
        #expect(argv.last == "gpt-6-astra")   // last token is the -m value, no prompt
    }

    @Test("resume(ctx) is `resume <id>`, model, NO prompt; default card is unclamped")
    func resumeArgv() throws {
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-6-astra", sessionId: "sess-9",
                                 prompt: "should be ignored")
        let argv = try #require(adapter.resume(ctx))
        #expect(adjacent(argv, "resume", "sess-9"))
        #expect(!argv.contains("read-only"))                   // default = Codex's own permissioning
        #expect(!argv.contains("never"))
        #expect(adjacent(argv, "-m", "gpt-6-astra"))
        #expect(!argv.contains("should be ignored"))
    }

    @Test("resume honors ctx.access: a read-only card resumes with the RO preset")
    func resumeReadOnly() throws {
        let ctx = AdapterContext(cwd: "/wt", sessionId: "sess-9", access: .readOnly)
        let argv = try #require(adapter.resume(ctx))
        #expect(adjacent(argv, "resume", "sess-9"))
        #expect(adjacent(argv, "-s", "read-only"))
        #expect(adjacent(argv, "-a", "never"))
    }

    @Test("resume returns nil without a session id")
    func resumeNilNoId() {
        #expect(adapter.resume(AdapterContext(cwd: "/wt", sessionId: nil)) == nil)
    }

    @Test("env leaves CODEX_HOME native while the injected home still resolves rollouts")
    func envLeavesCodexHomeNative() {
        let a = CodexAdapter(codexHome: "/tmp/ch")
        #expect(a.env.isEmpty)
        #expect(a.sessionsDir == "/tmp/ch/sessions")
    }

    // Defect 2 · hook trust. This customized Codex build trust-gates hooks behind a launch modal Orchestra
    // cannot answer. `--dangerously-bypass-hook-trust` enables the launch-scoped Orchestra hooks. It is the
    // only empirically verified
    // mechanism (the `-c bypass_hook_trust` override is inert; persisted trust is hash-keyed → a
    // config-seed is fragile). Build-gated so a stock codex-rs build (no gate, no flag) still launches;
    // `hookTrustBypass:` injects the probe result for hermetic tests.
    @Test("start/resume carry --dangerously-bypass-hook-trust when the build supports it")
    func hookTrustBypassPresentWhenSupported() throws {
        let a = CodexAdapter(binOverride: "codex", hookTrustBypass: true)
        let start = a.start(AdapterContext(cwd: "/wt", model: "gpt-6-astra", prompt: "go"))
        #expect(start.contains("--dangerously-bypass-hook-trust"))
        #expect(start.last == "go")                            // positional prompt still last
        let resume = try #require(a.resume(AdapterContext(cwd: "/wt", sessionId: "sess-9", seed: "drain")))
        #expect(resume.contains("--dangerously-bypass-hook-trust"))
        #expect(adjacent(resume, "resume", "sess-9"))          // flag must NOT split `resume <sid>`
        #expect(resume.last == "drain")                        // folded seed still last
    }

    @Test("start/resume OMIT the flag on a build that lacks it (graceful degradation)")
    func hookTrustBypassAbsentWhenUnsupported() throws {
        let a = CodexAdapter(binOverride: "codex", hookTrustBypass: false)
        #expect(!a.start(AdapterContext(cwd: "/wt", prompt: "go")).contains("--dangerously-bypass-hook-trust"))
        let resume = try #require(a.resume(AdapterContext(cwd: "/wt", sessionId: "sess-9")))
        #expect(!resume.contains("--dangerously-bypass-hook-trust"))
    }

    @Test("the hook-trust flag is Codex-local: Claude's argv never carries it")
    func claudeUnaffectedByHookTrust() {
        let claude = ClaudeCodeAdapter()
        #expect(!claude.start(AdapterContext(cwd: "/wt", prompt: "go")).contains("--dangerously-bypass-hook-trust"))
        let r = claude.resume(AdapterContext(cwd: "/wt", sessionId: "abc")) ?? []
        #expect(!r.contains("--dangerously-bypass-hook-trust"))
    }
}

// Directly exercises the hook-trust build-probe's caching + graceful-degradation logic (the highest-value,
// most-regression-prone part of Defect 2) against REAL tiny script "binaries" — the argv tests inject
// `hookTrustBypass:` and so never reach `probeBypassHookTrust`. Unique bin paths per test avoid the
// process-global cache colliding across tests.
@Suite("CodexAdapter — hook-trust build-probe caching + degradation")
struct CodexHookTrustProbeTests {
    private static let flag = "--dangerously-bypass-hook-trust"

    /// Write a unique executable script that ignores its args, prints `out`, and exits `code`.
    private func fakeBin(exit code: Int, prints out: String) throws -> String {
        let path = NSTemporaryDirectory() + "cxprobe-\(UUID().uuidString).sh"
        try "#!/bin/sh\nprintf '%s' '\(out)'\nexit \(code)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
    private func rewrite(_ path: String, exit code: Int, prints out: String) throws {
        try "#!/bin/sh\nprintf '%s' '\(out)'\nexit \(code)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    @Test("a --help that lists the flag (exit 0) → supported")
    func supportedWhenFlagPresent() throws {
        let bin = try fakeBin(exit: 0, prints: Self.flag)
        defer { try? FileManager.default.removeItem(atPath: bin) }
        #expect(CodexAdapter.probeBypassHookTrust(bin) == true)
    }

    @Test("a --help without the flag (exit 0) → unsupported, and the definitive result IS cached")
    func unsupportedExit0IsCached() throws {
        let bin = try fakeBin(exit: 0, prints: "no such flag here")
        defer { try? FileManager.default.removeItem(atPath: bin) }
        #expect(CodexAdapter.probeBypassHookTrust(bin) == false)
        // Rewrite the SAME path to now advertise the flag. A cached exit-0 `false` must NOT re-probe.
        try rewrite(bin, exit: 0, prints: Self.flag)
        #expect(CodexAdapter.probeBypassHookTrust(bin) == false)   // still false → the exit-0 result was cached
    }

    @Test("a non-zero --help (timeout/failure proxy) → unsupported, but NOT cached → retries")
    func nonzeroExitNotCached() throws {
        let bin = try fakeBin(exit: 1, prints: Self.flag)   // flag present but the probe FAILED (non-zero)
        defer { try? FileManager.default.removeItem(atPath: bin) }
        #expect(CodexAdapter.probeBypassHookTrust(bin) == false)   // degrade, do not cache
        // Rewrite to a clean exit 0. Because the failure wasn't cached, the retry now sees the flag.
        try rewrite(bin, exit: 0, prints: Self.flag)
        #expect(CodexAdapter.probeBypassHookTrust(bin) == true)    // retried → proves the failure wasn't cached
    }

    @Test("an absent binary → unsupported (never blocks launch)")
    func absentBinaryUnsupported() {
        #expect(CodexAdapter.probeBypassHookTrust("/no/such/codex-\(UUID().uuidString)") == false)
    }
}

@Suite("CodexAdapter — bound rollout metadata")
struct CodexAdapterDiscoveryTests {
    private func makeHome() -> (home: String, adapter: CodexAdapter) {
        let home = NSTemporaryDirectory() + "codexhome-\(UUID().uuidString)"
        return (home, CodexAdapter(codexHome: home))
    }
    private func writeRollout(_ home: String, sessionId: String) {
        let day = "2026/07/01"
        let dir = "\(home)/sessions/\(day)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/rollout-2026-07-01T10-00-00-\(sessionId).jsonl"
        let line = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(sessionId)\"}}\n"
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test("a bound app-server id selects its rollout metadata and resume target")
    func boundIdSelectsMetadata() throws {
        let (home, adapter) = makeHome()
        let sid = UUID().uuidString.lowercased()
        writeRollout(home, sessionId: sid)
        let info = try #require(adapter.sessionInfo(
            AdapterContext(cwd: "/wt"), current: sid, prior: ["old"]
        ))
        #expect(info.sessionId == sid)
        #expect(info.transcriptPath?.hasSuffix("-\(sid).jsonl") == true)
        #expect(info.resumeCmd?.contains(sid) == true)
        #expect(info.priorSessionIds == ["old"])
    }

    @Test("an unbound card never derives identity from rollout files")
    func unboundIsIdentitySilent() {
        let (home, adapter) = makeHome()
        writeRollout(home, sessionId: UUID().uuidString.lowercased())
        let info = adapter.sessionInfo(AdapterContext(cwd: "/wt"), current: nil, prior: [])
        #expect(info?.sessionId == nil)
        #expect(info?.transcriptPath == nil)
        #expect(info?.resumeCmd == nil)
    }
}

@Suite("CodexAdapter — spawn keeps native home + access-gated argv")
struct CodexSpawnWiringTests {
    @Test("spawn(agentId: codex, access: readOnly) passes no CODEX_HOME env and keeps the read-only preset")
    func spawnKeepsNativeHomeAndArgv() async throws {
        let base = NSTemporaryDirectory() + "codex-spawn-\(UUID().uuidString)"
        let work = base + "/work"
        let codexHome = base + "/codexhome"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)], sessionLaunchTimeout: 3600,
                            scratchRoot: PathResolver.canonical(base) + "/scratch",
                            runtimeStateDir: PathResolver.canonical(base) + "/state")
        let sessions = StubSessions()
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: codexHome)
        let svc = OrchestraService(config: config,
                                   store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [codex]),
                                   worktrees: TestEnv.registry(StubWorktrees(root: config.worktreesRoot), base: base, config: config),
                                   sessions: sessions,
                                   trust: TrustLedger(path: base + "/trust.json"),
                                   proc: TestEnv.defaultFakeProc(), gitRemotesProbe: { _ in [] })
        let t = try await TestEnv.spawnAwaited(svc, SpawnInput(id: UUID(), prompt: "look around", agentId: "codex",
                                               cwd: PathResolver.canonical(work), access: .readOnly))
        #expect(t.agentId == "codex")
        let name = sessions.sessionName(t.id)
        let argv = try #require(sessions.ensureArgv[name])
        #expect(argv.first == "/bin/bash")                         // tmux owns the app-server/TUI wrapper
        #expect(argv.contains("fake-codex"))                       // both server + stock TUI use the adapter binary
        #expect(argv.contains("read-only"))
        #expect(argv.contains("never"))
        // The service still stamps its own launch epoch, but Codex chooses its own native home.
        #expect(sessions.ensureEnv[name]?["ORCH_EPOCH"] != nil)
        #expect(sessions.ensureEnv[name]?["CODEX_HOME"] == nil)
    }
}

/// The model→agent ROUTING that makes Codex startable from the app's flat "Model" picker: the daemon
/// unions every enabled adapter's models into one list, and a spawn that names only a model resolves to
/// the adapter that owns it (no explicit agentId needed).
@Suite("Codex model routing — union list + model-only spawn")
struct CodexModelRoutingTests {

    @Test("adapter(forModel:) routes a model id to its owning adapter (catalog-driven)")
    func routesModelToOwningAdapter() {
        let reg = AgentRegistry()                                   // Claude + Codex, both enabled
        #expect(reg.adapter(forModel: "gpt-99-fictional") == nil)
        #expect(reg.adapter(forModel: "gpt-6-astra")?.id == "codex")
        let claudeModel = try! reg.get("claude-code").models().first!.id
        #expect(reg.adapter(forModel: claudeModel)?.id == "claude-code")
        #expect(reg.adapter(forModel: "no-such-model") == nil)     // unknown → nil (never fabricates)
    }

    @Test("models() unions every enabled adapter, default agent first")
    func modelsUnionAllAdapters() async {
        let env = TestEnv.make(registry: AgentRegistry())          // real Claude + Codex
        let ids = await env.svc.models().map(\.id)
        #expect(!ids.contains("gpt-5.4"))                       // demoted models stay out of the picker
        #expect(ids.contains("gpt-6-astra"))                    // Astra is surfaced by Codex
        #expect(ids.contains { $0.contains("claude") })            // Claude still there
        // Default agent (claude-code) lists first, so the picker's default entry stays a Claude model.
        #expect(AgentRegistry().adapter(forModel: ids.first!)?.id == "claude-code")
    }

    /// A registry with a side-effect-free default agent (a Stub keyed "claude-code", so the real
    /// ClaudeTrust write to ~/.claude.json never fires) alongside Codex with a fake bin and injected
    /// rollout metadata home under the scratch base. Distinct model catalogs (m1/m2 vs gpt-*) keep routing
    /// unambiguous.
    private func isolatedRegistry(_ base: String) -> AgentRegistry {
        let stub = StubAdapter(transcriptDir: base + "/tx", id: "claude-code", name: "Stub")
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: base + "/codexhome")
        return AgentRegistry(adapters: [stub, codex])
    }

    @Test("agents() lists every enabled adapter (id/name/icon + its models), default first")
    func agentsListsAdapters() async {
        let env = TestEnv.make(registry: AgentRegistry())          // real Claude + Codex
        let agents = await env.svc.agents()
        #expect(agents.map(\.id) == ["claude-code", "codex"])      // default agent first
        let codex = try! #require(agents.first { $0.id == "codex" })
        #expect(codex.name == "Codex")
        #expect(!codex.icon.isEmpty)
        #expect(codex.models.first?.id == "gpt-6-astra")        // Astra is the Codex default
    }

    @Test("spawn with a Codex model (no agentId) lands on the Codex adapter")
    func spawnCodexModelRoutesToCodex() async throws {
        let base = NSTemporaryDirectory() + "codex-route-\(UUID().uuidString)"
        let env = TestEnv.make(registry: isolatedRegistry(base))
        let repo = TestEnv.repo(env.base)
        // Model only — the way the app's flat picker sends it — no agentId.
        let t = try await TestEnv.spawnAwaited(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b", model: "gpt-6-astra"))
        #expect(t.agentId == "codex")                               // routed to Codex, not the default
        #expect(t.agentSessionId == nil)                            // Codex is .discovered → unseeded
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.first == "/bin/bash")                         // launched the app-server/TUI wrapper
        #expect(argv.contains("fake-codex"))                       // whose provider binary is Codex
        #expect(!argv.contains("read-only"))                        // default card = Codex's own permissioning
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("a model-less Codex spawn uses Astra as the adapter default")
    func modelLessCodexSpawnUsesAstraDefault() async throws {
        let base = NSTemporaryDirectory() + "codex-route-\(UUID().uuidString)"
        let env = TestEnv.make(registry: isolatedRegistry(base))
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAwaited(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b", agentId: "codex")
        )
        #expect(task.agentId == "codex")
        #expect(task.model.id == "gpt-6-astra")
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("a model-less Codex spawn ignores a retired configured default")
    func modelLessCodexSpawnIgnoresRetiredConfiguredDefault() async throws {
        let base = NSTemporaryDirectory() + "codex-route-\(UUID().uuidString)"
        let env = TestEnv.make(registry: isolatedRegistry(base), defaultModel: "gpt-99-fictional")
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAwaited(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b", agentId: "codex")
        )
        #expect(task.model.id == "gpt-6-astra")
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("a model-less Codex spawn ignores a foreign configured default")
    func modelLessCodexSpawnIgnoresForeignConfiguredDefault() async throws {
        let base = NSTemporaryDirectory() + "codex-route-\(UUID().uuidString)"
        let env = TestEnv.make(registry: isolatedRegistry(base), defaultModel: "m1")
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAwaited(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b", agentId: "codex")
        )
        #expect(task.model.id == "gpt-6-astra")
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("a model-less Codex spawn honors a valid configured default")
    func modelLessCodexSpawnHonorsValidConfiguredDefault() async throws {
        let base = NSTemporaryDirectory() + "codex-route-\(UUID().uuidString)"
        let env = TestEnv.make(registry: isolatedRegistry(base), defaultModel: "gpt-5.6-sol")
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAwaited(
            env.svc,
            SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b", agentId: "codex")
        )
        #expect(task.model.id == "gpt-5.6-sol")
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("spawn with no model still uses the default agent")
    func spawnNoModelUsesDefault() async throws {
        let base = NSTemporaryDirectory() + "codex-route-\(UUID().uuidString)"
        let env = TestEnv.make(registry: isolatedRegistry(base))
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        #expect(t.agentId == "claude-code")                        // default (config.defaultAgentId) preserved
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("explicit agentId wins over the model's owning adapter")
    func explicitAgentIdWins() async throws {
        let base = NSTemporaryDirectory() + "codex-route-\(UUID().uuidString)"
        let env = TestEnv.make(registry: isolatedRegistry(base))
        let repo = TestEnv.repo(env.base)
        // A Codex model BUT an explicit claude-code agentId — the explicit agent must win.
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, 
            SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b", model: "gpt-6-astra", agentId: "claude-code"))
        #expect(t.agentId == "claude-code")
        try? FileManager.default.removeItem(atPath: base)
    }
}

@Suite("CodexAdapter — launch-scoped guidance")
struct CodexGuidanceTests {
    @Test("trusted Codex launches persist native per-directory trust without disturbing existing configuration")
    func trustedLaunchPersistsNativeProjectTrust() throws {
        let home = NSTemporaryDirectory() + "codex-trust-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let path = home + "/config.toml"
        let existing = "model = \"gpt-5\"\n"
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        let cwd = "/wt/quoted \"path\" and \\ slash"
        let adapter = CodexAdapter(codexHome: home, hookTrustBypass: false)
        try adapter.prepareToLaunch(AdapterContext(cwd: cwd, trustCwd: true))
        try adapter.prepareToLaunch(AdapterContext(cwd: cwd, trustCwd: true))

        let config = try String(contentsOfFile: path, encoding: .utf8)
        #expect(config.hasPrefix(existing))
        #expect(config.components(separatedBy: "[projects.\"/wt/quoted \\\"path\\\" and \\\\ slash\"]").count == 2)
        #expect(config.contains("trust_level = \"trusted\""))
    }

    @Test("untrusted Codex launches leave native per-directory trust unchanged")
    func untrustedLaunchLeavesNativeProjectTrustUntouched() throws {
        let home = NSTemporaryDirectory() + "codex-trust-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let path = home + "/config.toml"
        let existing = "model = \"gpt-5\"\n[projects.\"/previously-trusted\"]\ntrust_level = \"trusted\"\n"
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(codexHome: home, hookTrustBypass: false)
        try adapter.prepareToLaunch(AdapterContext(cwd: "/wt/untrusted", trustCwd: false))

        #expect(try String(contentsOfFile: path, encoding: .utf8) == existing)
    }

    @Test("trusted Codex launches recognize an existing dotted native project trust entry")
    func trustedLaunchRecognizesExistingDottedNativeTrust() throws {
        let home = NSTemporaryDirectory() + "codex-trust-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let path = home + "/config.toml"
        let existing = "projects.\"/wt/already-trusted\".trust_level = \"trusted\"\n"
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(codexHome: home, hookTrustBypass: false)
        try adapter.prepareToLaunch(AdapterContext(cwd: "/wt/already-trusted", trustCwd: true))

        #expect(try String(contentsOfFile: path, encoding: .utf8) == existing)
    }

    @Test("guidance is carried by the launch profile file, not the command line")
    func guidanceIsLaunchScoped() throws {
        let home = NSTemporaryDirectory() + "codexcfg-\(UUID().uuidString)"
        let adapter = CodexAdapter(codexHome: home, hookTrustBypass: false)
        let ctx = AdapterContext(cwd: "/wt", orchestraBin: "/abs/orchestra",
                                 orchestraMCPBin: "/abs/orchestra-mcp")
        try adapter.prepareToLaunch(ctx)
        let toml = try String(contentsOfFile: CodexLaunchConfiguration.profilePath(cwd: "/wt", codexHome: home),
                              encoding: .utf8)
        #expect(toml.contains("developer_instructions = "))
        #expect(toml.contains("Orchestra delegation"))
        #expect(toml.contains("Working in a branch tree"))
        #expect(toml.contains("[mcp_servers.orchestra]"))
        #expect(toml.contains("command = \"/abs/orchestra-mcp\""))
        // The instructions never ride the argv (that is the bug this fixes).
        #expect(!adapter.start(ctx).contains("-c"))
    }

    @Test("global MCP installation is opt-in and disabling it removes the stale Codex entry")
    func globalMCPInstallIsOptInAndReconciles() throws {
        let home = NSTemporaryDirectory() + "codex-mcp-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let adapter = CodexAdapter(codexHome: home, hookTrustBypass: false, userHome: home)
        let path = home + "/config.toml"

        try adapter.prepareToLaunch(AdapterContext(cwd: "/wt", orchestraBin: "/abs/orchestra",
                                                   orchestraMCPBin: "/abs/orchestra-mcp"))
        #expect(!FileManager.default.fileExists(atPath: path))

        try adapter.prepareToLaunch(AdapterContext(cwd: "/wt", orchestraBin: "/abs/orchestra",
                                                   orchestraMCPBin: "/abs/orchestra-mcp",
                                                   autoInstallMCPGlobally: true))
        let config = try String(contentsOfFile: path, encoding: .utf8)
        #expect(config.contains("[mcp_servers.orchestra]"))
        #expect(config.contains("command = \"/abs/orchestra-mcp\""))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.local/bin/orchestra") == "/abs/orchestra")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.local/bin/orchestra-mcp") == "/abs/orchestra-mcp")
        #expect(try String(contentsOfFile: home + "/.zprofile", encoding: .utf8)
            .contains("Orchestra user-local command path"))

        try adapter.prepareToLaunch(AdapterContext(cwd: "/wt", orchestraBin: "/abs/orchestra",
                                                   orchestraMCPBin: "/abs/orchestra-mcp"))
        let removed = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!removed.contains("[mcp_servers.orchestra]"))
    }

    @Test("prepareToLaunch is load-bearing: no profile file → `-p` would resolve nothing")
    func profileFileIsActuallyWritten() throws {
        let home = NSTemporaryDirectory() + "codexcfg-\(UUID().uuidString)"
        let adapter = CodexAdapter(codexHome: home, hookTrustBypass: false)
        let ctx = AdapterContext(cwd: "/wt", orchestraBin: "/abs/orchestra")
        let path = CodexLaunchConfiguration.profilePath(cwd: "/wt", codexHome: home)
        #expect(!FileManager.default.fileExists(atPath: path))   // nothing until prep runs
        try adapter.prepareToLaunch(ctx)
        #expect(FileManager.default.fileExists(atPath: path))    // prep wrote the profile `-p` selects
    }
}
