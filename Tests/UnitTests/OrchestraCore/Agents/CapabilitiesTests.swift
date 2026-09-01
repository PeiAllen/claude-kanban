import Foundation
import Testing
@testable import OrchestraCore

@Suite("AgentCapabilities — frozen contract")
struct CapabilitiesTests {

    // The COMPLETE variant spelling, locked against SSOT §4 + 02-contract classDiagram.
    // If any spelling drifts (add/rename/remove a case), this fails — that is the point. `sendKeys` /
    // Capabilities are computed from the adapter, never persisted.
    @Test("every enum variant spelling is frozen exactly")
    func variantSpellingsFrozen() {
        #expect(AgentCapabilities.SessionId.allCases.map(\.rawValue) == ["seeded", "discovered"])
        #expect(AgentCapabilities.Telemetry.allCases.map(\.rawValue) == ["hooksPush", "fileTail", "ptyScrape"])
        #expect(AgentCapabilities.ContextUsage.allCases.map(\.rawValue) == ["percent", "tokens", "none"])
        #expect(AgentCapabilities.ReadOnlyEnforcement.allCases.map(\.rawValue)
                == ["sandboxed", "toolGatedOnly", "orchestraSandboxed"])
        #expect(AgentCapabilities.AuthMode.allCases.map(\.rawValue) == ["subscription", "apiKey"])
        #expect(AgentCapabilities.TerminalImagePaste.allCases.map(\.rawValue) == ["direct", "controlV"])
        #expect(AgentCapabilities.ReadinessConfirmation.allCases.map(\.rawValue)
                == ["sessionStartHook", "relaunchLiveness"])
    }

    @Test("Claude advertises its frozen shipped tuple")
    func claudeTupleFrozen() {
        let c = AgentCapabilities.claudeCode
        #expect(c.sessionId == .seeded)
        #expect(c.telemetry == .hooksPush)
        #expect(c.contextUsage == .percent)
        #expect(c.readOnlyEnforcement == .sandboxed)
        #expect(c.authMode == .subscription)
        #expect(c.terminalImagePaste == .controlV)
        #expect(c.readinessConfirmation == .sessionStartHook)   // Claude confirms via its SessionStart hook
    }

    @Test("ClaudeCodeAdapter conforms and advertises the Claude tuple")
    func claudeAdapterAdvertises() {
        #expect(ClaudeCodeAdapter().capabilities == .claudeCode)
    }

    @Test("Codex uses SessionStart for readiness while app-server owns its discovered thread id")
    func codexReadinessConfirmation() {
        #expect(AgentCapabilities.codex.readinessConfirmation == .sessionStartHook)
        #expect(AgentCapabilities.codex.sessionId == .discovered)
        #expect(AgentCapabilities.codex.telemetry == .fileTail)
        #expect(CodexAdapter().capabilities == .codex)
    }

    @Test("StubAdapter is capability-parameterized and returns what it was given")
    func stubAdvertisesTuple() {
        let custom = AgentCapabilities(
            sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
            readOnlyEnforcement: .toolGatedOnly, authMode: .apiKey)
        #expect(custom.terminalImagePaste == .direct)
        #expect(custom.terminalImagePaste.canPasteImages)
        let stub = StubAdapter(transcriptDir: NSTemporaryDirectory(), capabilities: custom)
        #expect(stub.capabilities == custom)
        // Default is Claude-shaped EXCEPT `.relaunchLiveness` readiness, so setup spawns/resumes land
        // immediately under 2.6's capability-gated launch readiness (see `AgentCapabilities.stub`).
        #expect(StubAdapter(transcriptDir: NSTemporaryDirectory()).capabilities == .stub)
    }

    @Test("terminal image paste direct means the normal paste path handles images")
    func terminalImagePasteSemantics() {
        #expect(AgentCapabilities.TerminalImagePaste.direct.canPasteImages)
        #expect(AgentCapabilities.TerminalImagePaste.controlV.canPasteImages)
    }

    // A daemon still on the retired `terminalPointerInput` key must not break a newer client: the
    // decoder ignores a field it no longer declares rather than throwing.
    @Test("a capability payload carrying the retired pointer-input key still decodes")
    func retiredPointerInputKeyIgnored() throws {
        let encoded = try OrchestraJSON.wire.encode(AgentCapabilities.claudeCode)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["terminalPointerInput"] = "nativeSelection"

        let legacyPayload = try JSONSerialization.data(withJSONObject: object)
        let decoded = try OrchestraJSON.decoder.decode(AgentCapabilities.self, from: legacyPayload)

        #expect(decoded == .claudeCode)
    }

    @Test("retired direct permission-gate keys are ignored")
    func retiredPermissionGateKeysIgnored() throws {
        let encoded = try OrchestraJSON.wire.encode(AgentCapabilities.claudeCode)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["approveChord"] = []
        object["denyChord"] = []

        let legacyPayload = try JSONSerialization.data(withJSONObject: object)
        let decoded = try OrchestraJSON.decoder.decode(AgentCapabilities.self, from: legacyPayload)

        #expect(decoded == .claudeCode)
    }

    @Test("AdapterContext.seed defaults to nil and round-trips when set")
    func seedField() {
        #expect(AdapterContext(cwd: "/wt").seed == nil)
        #expect(AdapterContext(cwd: "/wt", seed: "handoff summary").seed == "handoff summary")
    }

    @Test("AdapterContext carries the MCP executable and global-install setting")
    func mcpLaunchFields() {
        let context = AdapterContext(cwd: "/wt", orchestraMCPBin: "/bin/orchestra-mcp",
                                      autoInstallMCPGlobally: true)
        #expect(context.orchestraMCPBin == "/bin/orchestra-mcp")
        #expect(context.autoInstallMCPGlobally)
        #expect(AdapterContext(cwd: "/wt").autoInstallMCPGlobally == false)
    }

    @Test("spawn seeds a session id for a .seeded adapter (Claude behavior preserved)")
    func spawnSeedsWhenSeeded() async throws {
        let env = TestEnv.make()   // default .claudeCode → .seeded
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        #expect(t.agentSessionId != nil)
        // Seeded id is passed to launch as --session-id.
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--session-id"))
    }

    @Test("spawn does NOT seed a session id for a .discovered adapter (core gates on caps, not identity)")
    func spawnDiscoveredDoesNotSeed() async throws {
        let env = TestEnv.make(capabilities: Self.discoveredTuple)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        #expect(t.agentSessionId == nil)   // discovered → read back post-launch, not seeded
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(!argv.contains("--session-id"))
    }

    @Test("isResumable: seeded adapter with a stored id + state on disk is resumable; absent → not")
    func isResumableGatedByCaps() async throws {
        let env = TestEnv.make()   // .seeded
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        // No transcript yet → not resumable.
        #expect(await env.svc.isResumable(t) == false)
        // Adapter's state (transcript) now on disk → resumable.
        env.adapter.writeTranscript(for: t.agentSessionId!)
        #expect(await env.svc.isResumable(t) == true)
        // Remove it → not resumable again (core consults the adapter's sessionInfo path, not ~/.claude).
        env.adapter.deleteTranscript(for: t.agentSessionId!)
        #expect(await env.svc.isResumable(t) == false)
    }

    @Test("isResumable: a discovered adapter with no stored id is not resumable")
    func isResumableDiscoveredNoId() async throws {
        let env = TestEnv.make(capabilities: Self.discoveredTuple)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        #expect(t.agentSessionId == nil)               // discovered → unseeded
        #expect(await env.svc.isResumable(t) == false) // no id ⇒ nothing to resume
    }

    /// A representative non-Claude tuple used to prove core gates on the descriptor, not identity.
    /// `.relaunchLiveness` readiness so the setup spawns here land immediately (these tests assert session-id
    /// seeding, not the awaited launch-readiness path).
    static let discoveredTuple = AgentCapabilities(
        sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
        readOnlyEnforcement: .sandboxed, authMode: .subscription,
        readinessConfirmation: .relaunchLiveness)
}
