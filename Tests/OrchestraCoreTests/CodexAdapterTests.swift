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

    @Test("capabilities are Codex's discovered/fileTail/sendKeys tuple")
    func capabilities() {
        let c = CodexAdapter().capabilities
        #expect(c == .codex)
        #expect(c.sessionId == .discovered)
        #expect(c.telemetry == .fileTail)
        #expect(c.contextUsage == .tokens)
        #expect(c.wakeTransport == .sendKeys)
        #expect(c.inboxDrain == .sessionSeed)
        #expect(c.readOnlyEnforcement == .sandboxed)
        #expect(c.authMode == .subscription)
    }

    @Test("discovered agents do not mint a session id")
    func newSessionIdIsNil() {
        #expect(CodexAdapter().newSessionId() == nil)
    }

    @Test("models() is non-empty (fallback when no vendored table)")
    func models() { #expect(!adapter.models().isEmpty) }

    @Test("start(ctx) is read-only-first with adjacent flags, model, and trailing prompt")
    func startArgv() {
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-5-codex",
                                 prompt: "Add OAuth login\nwith Google")
        let argv = adapter.start(ctx)
        #expect(argv.first == "codex")
        #expect(adjacent(argv, "-s", "read-only"))
        #expect(adjacent(argv, "-a", "never"))
        #expect(adjacent(argv, "-m", "gpt-5-codex"))
        #expect(argv.last == "Add OAuth login\nwith Google")   // launch positional prompt
    }

    @Test("start clamps to read-only even when ctx.access is readWrite (read-only-first)")
    func startReadOnlyFirst() {
        let ctx = AdapterContext(cwd: "/wt", access: .readWrite)
        let argv = adapter.start(ctx)
        #expect(adjacent(argv, "-s", "read-only"))
        #expect(adjacent(argv, "-a", "never"))
    }

    @Test("start with no prompt has no trailing positional")
    func startNoPrompt() {
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-5-codex", prompt: nil)
        let argv = adapter.start(ctx)
        #expect(argv.last == "gpt-5-codex")   // last token is the -m value, no prompt
    }

    @Test("resume(ctx) is `resume <id>` read-only-first, NO prompt")
    func resumeArgv() throws {
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-5", sessionId: "sess-9",
                                 prompt: "should be ignored")
        let argv = try #require(adapter.resume(ctx))
        #expect(adjacent(argv, "resume", "sess-9"))
        #expect(adjacent(argv, "-s", "read-only"))
        #expect(adjacent(argv, "-a", "never"))
        #expect(adjacent(argv, "-m", "gpt-5"))
        #expect(!argv.contains("should be ignored"))
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
    private func writeRollout(_ home: String, day: String, sessionId: String, mtime: Date? = nil) {
        let dir = "\(home)/sessions/\(day)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/rollout-2026-07-01T10-00-00-\(sessionId).jsonl"
        try? "{}".write(toFile: path, atomically: true, encoding: .utf8)
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
