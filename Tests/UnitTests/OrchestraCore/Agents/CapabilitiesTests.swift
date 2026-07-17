import Foundation
import Testing
@testable import OrchestraCore

@Suite("AgentCapabilities — frozen contract")
struct CapabilitiesTests {

    // The COMPLETE variant spelling, locked against SSOT §4 + 02-contract classDiagram.
    // If any spelling drifts (add/rename/remove a case), this fails — that is the point. `sendKeys` /
    // `sessionSeed` were retired when Codex moved to resume-seed wake + the Stop-hook drain (see
    // docs/04-cards-worktrees-sessions.md § "Agent adapters" — the capability descriptor / wake
    // transport); capabilities are computed from the adapter, never persisted.
    @Test("every enum variant spelling is frozen exactly")
    func variantSpellingsFrozen() {
        #expect(AgentCapabilities.SessionId.allCases.map(\.rawValue) == ["seeded", "discovered"])
        #expect(AgentCapabilities.Telemetry.allCases.map(\.rawValue) == ["hooksPush", "fileTail", "ptyScrape"])
        #expect(AgentCapabilities.ContextUsage.allCases.map(\.rawValue) == ["percent", "tokens", "none"])
        #expect(AgentCapabilities.WakeTransport.allCases.map(\.rawValue)
                == ["nativeReinvoke", "relaunch", "controlChannel"])
        #expect(AgentCapabilities.InboxDrain.allCases.map(\.rawValue) == ["stopHook", "none"])
        #expect(AgentCapabilities.ReadOnlyEnforcement.allCases.map(\.rawValue)
                == ["sandboxed", "toolGatedOnly", "orchestraSandboxed"])
        #expect(AgentCapabilities.AuthMode.allCases.map(\.rawValue) == ["subscription", "apiKey"])
        #expect(AgentCapabilities.TerminalImagePaste.allCases.map(\.rawValue) == ["direct", "controlV"])
        #expect(AgentCapabilities.TerminalPointerInput.allCases.map(\.rawValue)
                == ["applicationMouseReporting", "nativeSelection"])
        #expect(AgentCapabilities.ReadinessConfirmation.allCases.map(\.rawValue)
                == ["sessionStartHook", "rolloutMeta", "relaunchLiveness"])
    }

    @Test("Claude advertises its frozen shipped tuple")
    func claudeTupleFrozen() {
        let c = AgentCapabilities.claudeCode
        #expect(c.sessionId == .seeded)
        #expect(c.telemetry == .hooksPush)
        #expect(c.contextUsage == .percent)
        #expect(c.wakeTransport == .nativeReinvoke)
        #expect(c.inboxDrain == .stopHook)
        #expect(c.readOnlyEnforcement == .sandboxed)
        #expect(c.authMode == .subscription)
        #expect(c.terminalImagePaste == .controlV)
        #expect(c.terminalPointerInput == .applicationMouseReporting)
        #expect(c.readinessConfirmation == .sessionStartHook)   // Claude confirms via its SessionStart hook
    }

    @Test("ClaudeCodeAdapter conforms and advertises the Claude tuple")
    func claudeAdapterAdvertises() {
        #expect(ClaudeCodeAdapter().capabilities == .claudeCode)
    }

    // Codex is `.discovered` + `fileTail`: a fresh launch writes a rollout whose first line is a
    // `session_meta` record, so the daemon's rollout tail confirms a LAUNCH via `.rolloutMeta`. A
    // `codex resume` writes no rollout, so a relaunch has no marker and rides the universal N=3 fallback —
    // still on the readiness gate, never an immediate ensure-is-confirmation.
    @Test("Codex advertises rolloutMeta readiness confirmation (fileTail agent, session_meta launch marker)")
    func codexReadinessConfirmation() {
        #expect(AgentCapabilities.codex.readinessConfirmation == .rolloutMeta)
        #expect(AgentCapabilities.codex.telemetry == .fileTail)
        #expect(AgentCapabilities.codex.terminalPointerInput == .nativeSelection)
        #expect(CodexAdapter().capabilities == .codex)
    }

    @Test("StubAdapter is capability-parameterized and returns what it was given")
    func stubAdvertisesTuple() {
        let custom = AgentCapabilities(
            sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
            wakeTransport: .relaunch, inboxDrain: .stopHook,
            readOnlyEnforcement: .toolGatedOnly, authMode: .apiKey)
        #expect(custom.terminalImagePaste == .direct)
        #expect(custom.terminalImagePaste.canPasteImages)
        #expect(custom.terminalPointerInput == .applicationMouseReporting)
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

    @Test("pointer input preserves mouse-reporting unless an adapter explicitly opts into native selection")
    func terminalPointerInputSemantics() {
        #expect(AgentCapabilities.TerminalPointerInput.applicationMouseReporting
                    .allowsApplicationMouseReporting)
        #expect(!AgentCapabilities.TerminalPointerInput.nativeSelection
                    .allowsApplicationMouseReporting)
    }

    @Test("an older capability payload defaults pointer input to application mouse reporting")
    func legacyCapabilitiesDefaultPointerInput() throws {
        let encoded = try OrchestraJSON.wire.encode(AgentCapabilities.claudeCode)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "terminalPointerInput")

        let legacyPayload = try JSONSerialization.data(withJSONObject: object)
        let decoded = try OrchestraJSON.decoder.decode(AgentCapabilities.self, from: legacyPayload)

        #expect(decoded.terminalPointerInput == .applicationMouseReporting)
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
        wakeTransport: .relaunch, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .subscription,
        readinessConfirmation: .relaunchLiveness)
}
