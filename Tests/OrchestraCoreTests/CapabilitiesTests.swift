import Foundation
import Testing
@testable import OrchestraCore

@Suite("AgentCapabilities — frozen contract")
struct CapabilitiesTests {

    // The COMPLETE variant spelling, locked against SSOT §4 + 02-contract classDiagram.
    // If any spelling drifts (add/rename/remove a case), this fails — that is the point.
    @Test("every enum variant spelling is frozen exactly")
    func variantSpellingsFrozen() {
        #expect(AgentCapabilities.SessionId.allCases.map(\.rawValue) == ["seeded", "discovered"])
        #expect(AgentCapabilities.Telemetry.allCases.map(\.rawValue) == ["hooksPush", "fileTail", "ptyScrape"])
        #expect(AgentCapabilities.ContextUsage.allCases.map(\.rawValue) == ["percent", "tokens", "none"])
        #expect(AgentCapabilities.WakeTransport.allCases.map(\.rawValue)
                == ["nativeReinvoke", "controlChannel", "sendKeys", "relaunch"])
        #expect(AgentCapabilities.InboxDrain.allCases.map(\.rawValue) == ["stopHook", "sessionSeed", "none"])
        #expect(AgentCapabilities.ReadOnlyEnforcement.allCases.map(\.rawValue)
                == ["sandboxed", "toolGatedOnly", "orchestraSandboxed"])
        #expect(AgentCapabilities.AuthMode.allCases.map(\.rawValue) == ["subscription", "apiKey"])
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
    }

    @Test("ClaudeCodeAdapter conforms and advertises the Claude tuple")
    func claudeAdapterAdvertises() {
        #expect(ClaudeCodeAdapter().capabilities == .claudeCode)
    }

    @Test("StubAdapter is capability-parameterized and returns what it was given")
    func stubAdvertisesTuple() {
        let custom = AgentCapabilities(
            sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
            wakeTransport: .sendKeys, inboxDrain: .stopHook,
            readOnlyEnforcement: .toolGatedOnly, authMode: .apiKey)
        let stub = StubAdapter(transcriptDir: NSTemporaryDirectory(), capabilities: custom)
        #expect(stub.capabilities == custom)
        // Default stays Claude-shaped so existing suites are unaffected.
        #expect(StubAdapter(transcriptDir: NSTemporaryDirectory()).capabilities == .claudeCode)
    }

    @Test("AdapterContext.seed defaults to nil and round-trips when set")
    func seedField() {
        #expect(AdapterContext(cwd: "/wt").seed == nil)
        #expect(AdapterContext(cwd: "/wt", seed: "handoff summary").seed == "handoff summary")
    }

    @Test("spawn seeds a session id for a .seeded adapter (Claude behavior preserved)")
    func spawnSeedsWhenSeeded() async throws {
        let env = TestEnv.make()   // default .claudeCode → .seeded
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        #expect(t.agentSessionId != nil)
        // Seeded id is passed to launch as --session-id.
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--session-id"))
    }

    @Test("spawn does NOT seed a session id for a .discovered adapter (core gates on caps, not identity)")
    func spawnDiscoveredDoesNotSeed() async throws {
        let env = TestEnv.make(capabilities: Self.discoveredTuple)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        #expect(t.agentSessionId == nil)   // discovered → read back post-launch, not seeded
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(!argv.contains("--session-id"))
    }

    @Test("isResumable: seeded adapter with a stored id + state on disk is resumable; absent → not")
    func isResumableGatedByCaps() async throws {
        let env = TestEnv.make()   // .seeded
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
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
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        #expect(t.agentSessionId == nil)               // discovered → unseeded
        #expect(await env.svc.isResumable(t) == false) // no id ⇒ nothing to resume
    }

    /// A representative non-Claude tuple used to prove core gates on the descriptor, not identity.
    static let discoveredTuple = AgentCapabilities(
        sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
        wakeTransport: .sendKeys, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .subscription)
}
