import Foundation
import Testing
@testable import OrchestraCore

@Suite("AuthRateMonitor — per-adapter subscription rate state (soft-warn, no cap)")
struct AuthRateMonitorTests {

    // Two adapters: a subscription one ("claude-code") and an apiKey one ("keyed"), distinct ids so the
    // registry can hold both and the monitor tallies each seat independently.
    static let subAdapter = StubAdapter(transcriptDir: NSTemporaryDirectory(),
                                        capabilities: .claudeCode, id: "claude-code", name: "Claude")
    static let apiKeyCaps = AgentCapabilities(
        sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
        wakeTransport: .relaunch, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .apiKey)
    static let keyAdapter = StubAdapter(transcriptDir: NSTemporaryDirectory(),
                                        capabilities: apiKeyCaps, id: "keyed", name: "Keyed")
    static let registry = AgentRegistry(adapters: [subAdapter, keyAdapter])

    /// A minimal active card on an adapter. Only `agentId` + `status`/`archived` matter to the monitor.
    static func card(_ agentId: String, status: AgentStatus = .running, archived: Bool = false) -> Task {
        var t = Task(title: "c", repo: "/r", branch: "b", cwd: "/c", agentId: agentId,
                     model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0,
                     status: status, initialPrompt: "p")
        t.archived = archived
        return t
    }

    @Test("subscriptionTally counts subscription cards per adapter; excludes apiKey adapters")
    func tallyPerAdapter() {
        let mon = AuthRateMonitor()
        let active = [Self.card("claude-code"), Self.card("claude-code"), Self.card("keyed"), Self.card("keyed"), Self.card("keyed")]
        let tally = mon.subscriptionTally(active: active, registry: Self.registry)
        #expect(tally["claude-code"] == 2)   // subscription seat counted
        #expect(tally["keyed"] == nil)        // apiKey adapter excluded entirely
    }

    @Test("no warning at or below threshold")
    func silentUnderThreshold() {
        let mon = AuthRateMonitor(threshold: 3)
        let active = [Self.card("claude-code"), Self.card("claude-code"), Self.card("claude-code")]  // exactly 3
        #expect(mon.warning(for: "claude-code", active: active, registry: Self.registry) == nil)
    }

    @Test("warning fires when the subscription tally exceeds threshold")
    func warnsPastThreshold() throws {
        let mon = AuthRateMonitor(threshold: 3)
        let active = (0..<4).map { _ in Self.card("claude-code") }  // 4 > 3
        let warn = try #require(mon.warning(for: "claude-code", active: active, registry: Self.registry))
        #expect(warn.agentId == "claude-code")
        #expect(warn.agentName == "Claude")
        #expect(warn.count == 4)
        #expect(warn.threshold == 3)
        #expect(warn.message.contains("Claude"))
    }

    @Test("apiKey adapter never warns, however many are running")
    func apiKeyNeverWarns() {
        let mon = AuthRateMonitor(threshold: 1)
        let active = (0..<10).map { _ in Self.card("keyed") }
        #expect(mon.warning(for: "keyed", active: active, registry: Self.registry) == nil)
    }

    @Test("rate state is per-adapter: another seat's cards don't push this adapter over")
    func perAdapterIsolation() {
        let mon = AuthRateMonitor(threshold: 3)
        // 10 apiKey cards + only 2 subscription cards → subscription adapter is under its own threshold.
        let active = (0..<10).map { _ in Self.card("keyed") } + [Self.card("claude-code"), Self.card("claude-code")]
        #expect(mon.warning(for: "claude-code", active: active, registry: Self.registry) == nil)
    }

    @Test("unknown agentId (not in registry) yields no warning and no tally entry")
    func unknownAgentSafe() {
        let mon = AuthRateMonitor(threshold: 0)
        let active = [Self.card("ghost"), Self.card("ghost")]
        #expect(mon.subscriptionTally(active: active, registry: Self.registry)["ghost"] == nil)
        #expect(mon.warning(for: "ghost", active: active, registry: Self.registry) == nil)
    }
}
