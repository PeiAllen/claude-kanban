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

    @Test("registry resolves agentId=codex")
    func registryResolvesCodex() throws {
        let reg = AgentRegistry()
        #expect(try reg.get("codex").id == "codex")
        #expect(reg.list().contains { $0.id == "codex" })
        #expect(try reg.get("claude-code").id == "claude-code")   // both registered
    }

    @Test("capabilities are Codex's discovered/fileTail/relaunch/stopHook tuple")
    func capabilities() {
        let c = CodexAdapter().capabilities
        #expect(c == .codex)
        #expect(c.sessionId == .discovered)
        #expect(c.telemetry == .fileTail)
        #expect(c.contextUsage == .tokens)
        #expect(c.wakeTransport == .relaunch)
        #expect(c.inboxDrain == .stopHook)
        #expect(c.readOnlyEnforcement == .sandboxed)
        #expect(c.authMode == .subscription)
        #expect(c.terminalImagePaste == .controlV)
    }

    @Test("discovered agents do not mint a session id")
    func newSessionIdIsNil() {
        #expect(CodexAdapter().newSessionId() == nil)
    }

    // F3 · live drain: Codex encodes a Stop-drain continuation into the SAME `decision:block` envelope as
    // Claude (byte-identical framing). This is what `handleHook(.stop)` → `drainForStop` rides.
    @Test("encode(.continuation, for: .stop) is the shared block continuation")
    func encodesStopContinuation() {
        let out = CodexAdapter().encode(HookResponse(continuation: "DRAIN-ME"), for: .stop)
        #expect(out == HookEnvelope.block("DRAIN-ME"))
        #expect(out == StopDrain.blockJSON(reason: "DRAIN-ME"))
    }

    // The rendered Codex hooks file must wire the Stop event, or the drain above never fires.
    @Test("rendered Codex hooks wire the Stop event to `_report --event stop --agent codex`")
    func rendersStopHook() throws {
        let dest = NSTemporaryDirectory() + "codex-hooks-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: dest) }
        _ = try HooksRenderer.renderCodex(orchestraBin: "/usr/local/bin/orchestra", agentId: "codex", to: dest)
        let json = try String(contentsOfFile: dest, encoding: .utf8)
        #expect(json.contains("\"Stop\""))
        #expect(json.contains("_report --event stop --agent codex"))
        #expect(!json.contains("__AGENT_ID__"))   // fully substituted
    }

    // C1 · Codex permission gate. Codex's `PermissionRequest` hook fires `_report --event permission`,
    // and THIS adapter classifies that hooksPush into the SAME `waitReason == .permission` Claude uses
    // (via its Notification/permission_prompt), so a blocked Codex card surfaces as a Needs-You 🔐 row.
    @Test("parse(permission hooksPush) → waiting/.permission (Codex PermissionRequest gate)")
    func parsePermissionHook() {
        let r = adapter.parse(.hooksPush(kind: "permission", payload: .object([:])))
        #expect(r == StatusReport(run: .waiting(.permission)))
    }

    // The OTHER Codex hooks (SessionStart/Stop) carry NO StatusReport — the daemon dispatches them
    // (orientation, inbox drain) via the typed HookEvent, and telemetry stays the rollout fileTail.
    // Only PermissionRequest produces a report from a hooksPush, so those must remain nil (no churn).
    @Test("parse(session/stop hooksPush) stays nil — only PermissionRequest reports from a push")
    func parseNonPermissionHooksNil() {
        #expect(adapter.parse(.hooksPush(kind: "session", payload: .object([:]))) == nil)
        #expect(adapter.parse(.hooksPush(kind: "stop", payload: .object([:]))) == nil)
    }

    // The permission push must not disturb the fileTail path: a completed turn is still humanTurn.
    @Test("fileTail turn-complete still classifies humanTurn (permission push is additive)")
    func fileTailUnaffected() {
        let line = #"{"type":"turn_complete","timestamp":"2026-07-04T10:00:00Z"}"#
        let r = adapter.parse(.fileTail(line: line))
        #expect(r?.snapshot?.run != nil)
        #expect(r?.snapshot?.run == .waiting(.humanTurn))
    }

    // The rendered Codex hooks file must wire the PermissionRequest event, or the gate never fires.
    @Test("rendered Codex hooks wire PermissionRequest → `_report --event permission --agent codex`")
    func rendersPermissionHook() throws {
        let dest = NSTemporaryDirectory() + "codex-hooks-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: dest) }
        _ = try HooksRenderer.renderCodex(orchestraBin: "/usr/local/bin/orchestra", agentId: "codex", to: dest)
        let json = try String(contentsOfFile: dest, encoding: .utf8)
        #expect(json.contains("\"PermissionRequest\""))
        #expect(json.contains("_report --event permission --agent codex"))
        #expect(!json.contains("__AGENT_ID__"))   // fully substituted
    }

    @Test("models() is non-empty (fallback when no vendored table)")
    func models() { #expect(!adapter.models().isEmpty) }

    @Test("start(ctx) for a default card: model, trailing prompt, and NO read-only clamp")
    func startArgv() {
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-5.3-codex",
                                 prompt: "Add OAuth login\nwith Google")
        let argv = adapter.start(ctx)
        #expect(argv.first == "codex")
        #expect(!argv.contains("read-only"))                   // default = Codex's own permissioning
        #expect(!argv.contains("never"))
        #expect(adjacent(argv, "-m", "gpt-5.3-codex"))
        #expect(argv.last == "Add OAuth login\nwith Google")   // launch positional prompt
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
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-5.3-codex", prompt: nil)
        let argv = adapter.start(ctx)
        #expect(argv.last == "gpt-5.3-codex")   // last token is the -m value, no prompt
    }

    @Test("resume(ctx) is `resume <id>`, model, NO prompt; default card is unclamped")
    func resumeArgv() throws {
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-5.5", sessionId: "sess-9",
                                 prompt: "should be ignored")
        let argv = try #require(adapter.resume(ctx))
        #expect(adjacent(argv, "resume", "sess-9"))
        #expect(!argv.contains("read-only"))                   // default = Codex's own permissioning
        #expect(!argv.contains("never"))
        #expect(adjacent(argv, "-m", "gpt-5.5"))
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

    @Test("env pins CODEX_HOME")
    func envPinsCodexHome() {
        let a = CodexAdapter(codexHome: "/tmp/ch")
        #expect(a.env["CODEX_HOME"] == "/tmp/ch")
    }
}

@Suite("CodexAdapter — rollout session-id discovery")
struct CodexAdapterDiscoveryTests {
    /// Make an isolated CODEX_HOME + adapter.
    private func makeHome() -> (home: String, adapter: CodexAdapter) {
        let home = NSTemporaryDirectory() + "codexhome-\(UUID().uuidString)"
        return (home, CodexAdapter(codexHome: home))
    }
    private func writeRollout(_ home: String, day: String, sessionId: String,
                              cwd: String = "/wt", mtime: Date? = nil) {
        let dir = "\(home)/sessions/\(day)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/rollout-2026-07-01T10-00-00-\(sessionId).jsonl"
        try? #"{"type":"session_meta","payload":{"id":"\#(sessionId)","cwd":"\#(cwd)"}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        if let m = mtime {
            try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: path)
        }
    }

    @Test("sessionInfo discovers the session id from the newest rollout file")
    func discoversFromRollout() throws {
        let (home, adapter) = makeHome()
        let sid = UUID().uuidString.lowercased()
        writeRollout(home, day: "2026/07/01", sessionId: sid)
        let info = try #require(adapter.sessionInfo(AdapterContext(cwd: "/wt"), current: nil, prior: []))
        #expect(info.sessionId == sid)
        #expect(info.transcriptPath?.hasSuffix("-\(sid).jsonl") == true)
        #expect(info.resumeCmd?.contains("resume") == true)
        #expect(info.resumeCmd?.contains(sid) == true)
    }

    @Test("discovery picks the NEWEST rollout by mtime")
    func discoversNewest() throws {
        let (home, adapter) = makeHome()
        let older = UUID().uuidString.lowercased()
        let newer = UUID().uuidString.lowercased()
        writeRollout(home, day: "2026/06/30", sessionId: older, mtime: Date(timeIntervalSince1970: 1000))
        writeRollout(home, day: "2026/07/01", sessionId: newer, mtime: Date(timeIntervalSince1970: 2000))
        #expect(adapter.discover() == newer)
    }

    @Test("sessionInfo discovers newest rollout for the card cwd, not global newest")
    func sessionInfoDiscoversByCwd() throws {
        let (home, adapter) = makeHome()
        let target = UUID().uuidString.lowercased()
        let other = UUID().uuidString.lowercased()
        writeRollout(home, day: "2026/07/01", sessionId: target,
                     cwd: "/work/target", mtime: Date(timeIntervalSince1970: 1000))
        writeRollout(home, day: "2026/07/01", sessionId: other,
                     cwd: "/work/other", mtime: Date(timeIntervalSince1970: 2000))

        let info = try #require(adapter.sessionInfo(AdapterContext(cwd: "/work/target"),
                                                    current: nil, prior: []))
        #expect(info.sessionId == target)
        #expect(info.transcriptPath?.hasSuffix("-\(target).jsonl") == true)
    }

    @Test("current id wins over discovery")
    func currentWins() throws {
        let (home, adapter) = makeHome()
        writeRollout(home, day: "2026/07/01", sessionId: UUID().uuidString.lowercased())
        let info = try #require(adapter.sessionInfo(AdapterContext(cwd: "/wt"), current: "explicit-id", prior: ["old"]))
        #expect(info.sessionId == "explicit-id")
        #expect(info.priorSessionIds == ["old"])
    }

    @Test("no rollouts → nil session id, nil resume")
    func noRollouts() {
        let (_, adapter) = makeHome()   // empty home
        let info = adapter.sessionInfo(AdapterContext(cwd: "/wt"), current: nil, prior: [])
        #expect(info?.sessionId == nil)
        #expect(info?.resumeCmd == nil)
    }

    @Test("a non-UUID rollout tail is rejected (never a fabricated id)")
    func rejectsNonUuidTail() {
        let (home, adapter) = makeHome()
        let dir = "\(home)/sessions/2026/07/01"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "{}".write(toFile: "\(dir)/rollout-2026-07-01T10-00-00-not-a-uuid.jsonl",
                        atomically: true, encoding: .utf8)
        #expect(adapter.discover() == nil)
    }
}

@Suite("CodexAdapter — spawn wires CODEX_HOME + access-gated argv")
struct CodexSpawnWiringTests {
    @Test("spawn(agentId: codex, access: readOnly) passes CODEX_HOME env + the read-only preset to the session")
    func spawnWiresHomeAndArgv() async throws {
        let base = NSTemporaryDirectory() + "codex-spawn-\(UUID().uuidString)"
        let work = base + "/work"
        let codexHome = base + "/codexhome"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)])
        let sessions = StubSessions()
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: codexHome)
        let svc = OrchestraService(config: config,
                                   store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [codex]),
                                   worktrees: TestEnv.registry(StubWorktrees(root: config.worktreesRoot), base: base, config: config),
                                   sessions: sessions,
                                   trust: TrustLedger(path: base + "/trust.json"))
        let t = try await TestEnv.spawnAwaited(svc, SpawnInput(prompt: "look around", agentId: "codex",
                                               cwd: PathResolver.canonical(work), access: .readOnly))
        #expect(t.agentId == "codex")
        let name = sessions.sessionName(t.id)
        let argv = try #require(sessions.ensureArgv[name])
        #expect(argv.first == "fake-codex")
        #expect(argv.contains("read-only"))
        #expect(argv.contains("never"))
        // env wiring: the pinned CODEX_HOME reaches the launch.
        #expect(sessions.ensureEnv[name]?["CODEX_HOME"] == codexHome)
    }
}

@Suite("CodexAdapter — trust mirror + isolation")
struct CodexAdapterTrustTests {
    private func makeHome() -> (home: String, adapter: CodexAdapter) {
        let home = NSTemporaryDirectory() + "codexhome-\(UUID().uuidString)"
        return (home, CodexAdapter(codexHome: home))
    }
    private func configText(_ home: String) -> String {
        (try? String(contentsOfFile: "\(home)/config.toml", encoding: .utf8)) ?? ""
    }

    @Test("test_adapter_applies_ctx_trust: trustCwd=true writes trust_level from ctx, into the isolated home")
    func appliesCtxTrust() throws {
        let (home, adapter) = makeHome()
        let ctx = AdapterContext(cwd: "/Users/x/wt/app/feat", trustCwd: true)
        try adapter.prepareToLaunch(ctx)
        // Isolation: the pinned CODEX_HOME was created (ordering: home exists before trust write).
        #expect(FileManager.default.fileExists(atPath: home))
        let toml = configText(home)
        #expect(toml.contains("[projects.\"/Users/x/wt/app/feat\"]"))
        #expect(toml.contains("trust_level = \"trusted\""))
    }

    @Test("trustCwd=false does NOT write trust (mirrors, never grants what core didn't)")
    func untrustedNoWrite() throws {
        let (home, adapter) = makeHome()
        try adapter.prepareToLaunch(AdapterContext(cwd: "/wt", trustCwd: false))
        #expect(!configText(home).contains("trust_level"))
    }

    @Test("mirror is idempotent + non-clobbering: existing config content survives")
    func idempotentNonClobbering() throws {
        let (home, adapter) = makeHome()
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try "model = \"gpt-5\"\n".write(toFile: "\(home)/config.toml", atomically: true, encoding: .utf8)
        let ctx = AdapterContext(cwd: "/wt", trustCwd: true)
        try adapter.prepareToLaunch(ctx)
        try adapter.prepareToLaunch(ctx)   // second apply must not duplicate the section
        let toml = configText(home)
        #expect(toml.contains("model = \"gpt-5\""))                  // user content preserved
        #expect(toml.components(separatedBy: "[projects.\"/wt\"]").count == 2)  // exactly one section
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
        #expect(reg.adapter(forModel: "gpt-5.3-codex")?.id == "codex")
        let claudeModel = try! reg.get("claude-code").models().first!.id
        #expect(reg.adapter(forModel: claudeModel)?.id == "claude-code")
        #expect(reg.adapter(forModel: "no-such-model") == nil)     // unknown → nil (never fabricates)
    }

    @Test("models() unions every enabled adapter, default agent first")
    func modelsUnionAllAdapters() async {
        let env = TestEnv.make(registry: AgentRegistry())          // real Claude + Codex
        let ids = await env.svc.models().map(\.id)
        #expect(ids.contains("gpt-5.3-codex"))                        // Codex now surfaced in the picker
        #expect(ids.contains { $0.contains("claude") })            // Claude still there
        // Default agent (claude-code) lists first, so the picker's default entry stays a Claude model.
        #expect(AgentRegistry().adapter(forModel: ids.first!)?.id == "claude-code")
    }

    /// A registry with a side-effect-free default agent (a Stub keyed "claude-code", so the real
    /// ClaudeTrust write to ~/.claude.json never fires) alongside an ISOLATED Codex (fake bin + a
    /// CODEX_HOME under the scratch base). Distinct model catalogs (m1/m2 vs gpt-*) so routing is
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
        #expect(codex.models.contains { $0.id == "gpt-5.3-codex" })  // carries its own catalog
    }

    @Test("spawn with a Codex model (no agentId) lands on the Codex adapter")
    func spawnCodexModelRoutesToCodex() async throws {
        let base = NSTemporaryDirectory() + "codex-route-\(UUID().uuidString)"
        let env = TestEnv.make(registry: isolatedRegistry(base))
        let repo = TestEnv.repo(env.base)
        // Model only — the way the app's flat picker sends it — no agentId.
        let t = try await TestEnv.spawnAwaited(env.svc, SpawnInput(prompt: "x", repo: repo, branch: "b", model: "gpt-5.3-codex"))
        #expect(t.agentId == "codex")                               // routed to Codex, not the default
        #expect(t.agentSessionId == nil)                            // Codex is .discovered → unseeded
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.first == "fake-codex")                         // launched the Codex adapter's argv
        #expect(!argv.contains("read-only"))                        // default card = Codex's own permissioning
        try? FileManager.default.removeItem(atPath: base)
    }

    @Test("spawn with no model still uses the default agent")
    func spawnNoModelUsesDefault() async throws {
        let base = NSTemporaryDirectory() + "codex-route-\(UUID().uuidString)"
        let env = TestEnv.make(registry: isolatedRegistry(base))
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "x", repo: repo, branch: "b"))
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
            SpawnInput(prompt: "x", repo: repo, branch: "b", model: "gpt-5.3-codex", agentId: "claude-code"))
        #expect(t.agentId == "claude-code")
        try? FileManager.default.removeItem(atPath: base)
    }
}

@Suite("CodexAdapter — delegation AGENTS.md materialization")
struct CodexDelegationTests {
    private func makeHome() -> (home: String, adapter: CodexAdapter) {
        let home = NSTemporaryDirectory() + "codexhome-deleg-\(UUID().uuidString)"
        return (home, CodexAdapter(codexHome: home))
    }

    @Test("prepareToLaunch composes the delegation + tree sections into the isolated CODEX_HOME AGENTS.md")
    func materializesAgents() throws {
        let (home, adapter) = makeHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        try adapter.prepareToLaunch(AdapterContext(cwd: "/wt", trustCwd: false))
        let text = try String(contentsOfFile: "\(home)/AGENTS.md", encoding: .utf8)
        #expect(text.contains(try #require(DelegationDocs.forAgent("codex"))))   // delegation section body
        #expect(text.contains(try #require(TreeDocs.forAgent("codex"))))         // tree section body
        #expect(text.contains(AgentsFileComposer.startMarker("delegation")))
        #expect(text.contains(AgentsFileComposer.startMarker("tree")))
        #expect(!text.hasPrefix("---\n"))                        // plain AGENTS.md, no frontmatter
    }

    @Test("materialization does not touch the worktree cwd (no leakage / no clobber)")
    func noWorktreeWrite() throws {
        let (home, adapter) = makeHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let cwd = NSTemporaryDirectory() + "cwd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        try adapter.prepareToLaunch(AdapterContext(cwd: cwd, trustCwd: false))
        #expect(!FileManager.default.fileExists(atPath: "\(cwd)/AGENTS.md"))   // never in the worktree
    }

    @Test("idempotent + coexists with the trust config write")
    func idempotentWithTrust() throws {
        let (home, adapter) = makeHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let ctx = AdapterContext(cwd: "/wt", trustCwd: true)
        try adapter.prepareToLaunch(ctx)
        try adapter.prepareToLaunch(ctx)   // second apply must not duplicate either section
        let text = try String(contentsOfFile: "\(home)/AGENTS.md", encoding: .utf8)
        #expect(text.contains(try #require(DelegationDocs.forAgent("codex"))))
        #expect(text.contains(try #require(TreeDocs.forAgent("codex"))))
        #expect(text.components(separatedBy: AgentsFileComposer.startMarker("delegation")).count == 2)
        #expect(text.components(separatedBy: AgentsFileComposer.startMarker("tree")).count == 2)
        // the trust write (config.toml) is unaffected by the AGENTS.md materialization
        #expect((try? String(contentsOfFile: "\(home)/config.toml", encoding: .utf8))?.contains("trust_level = \"trusted\"") == true)
    }

    @Test("start argv + env are unchanged by the added materialization")
    func argvEnvUnchanged() throws {
        let (home, adapter) = makeHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-5.3-codex", prompt: "go")
        let before = adapter.start(ctx)
        try adapter.prepareToLaunch(ctx)
        #expect(adapter.start(ctx) == before)                    // byte-identical argv
        #expect(adapter.env["CODEX_HOME"] == home)               // env unchanged (still just CODEX_HOME)
    }
}
