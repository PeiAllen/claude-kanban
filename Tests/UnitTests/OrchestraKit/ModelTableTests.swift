import Foundation
import Testing
@testable import OrchestraCore

@Suite("Model table — AgentModel context window + ctxPct")
struct ModelTableAgentModelTests {

    @Test("full init carries contextWindow + flags")
    func fullInit() {
        let m = AgentModel(id: "x", displayName: "X", family: "claude",
                           contextWindow: 200_000,
                           flags: ModelFlags(toolCall: true, reasoning: true, vision: false))
        #expect(m.contextWindow == 200_000)
        #expect(m.flags?.toolCall == true)
        #expect(m.flags?.vision == false)
    }

    @Test("heuristic init leaves contextWindow nil (unknown-model fallback)")
    func heuristicInitHasNoWindow() {
        let m = AgentModel(id: "some-unknown-model")
        #expect(m.contextWindow == nil)
        #expect(m.flags == nil)
    }

    @Test("ctxPct divides usedTokens by contextWindow, clamped 0...100")
    func ctxPctMath() {
        let m = AgentModel(id: "x", displayName: "X", family: "claude", contextWindow: 200_000)
        #expect(m.ctxPct(usedTokens: 50_000) == 25.0)
        #expect(m.ctxPct(usedTokens: 0) == 0.0)
        #expect(m.ctxPct(usedTokens: 999_999_999) == 100.0)   // clamped
    }

    @Test("ctxPct is nil when contextWindow unknown (don't divide by a guess)")
    func ctxPctUnknownWindow() {
        #expect(AgentModel(id: "unknown").ctxPct(usedTokens: 1000) == nil)
        #expect(AgentModel(id: "z", displayName: "Z", family: "other", contextWindow: 0)
                    .ctxPct(usedTokens: 1000) == nil)
    }

    @Test("object model decodes with optional fields absent")
    func objectModelDecode() throws {
        let obj = try OrchestraJSON.decoder.decode(
            AgentModel.self, from: Data("{\"id\":\"m\",\"displayName\":\"M\",\"family\":\"claude\"}".utf8))
        #expect(obj.id == "m")
        #expect(obj.contextWindow == nil)
        #expect(obj.launchId == nil)
    }

    @Test("launchId decodes when present, and defaults to nil (no card migration needed)")
    func launchIdDecode() throws {
        let withLaunchId = try OrchestraJSON.decoder.decode(AgentModel.self, from: Data(
            "{\"id\":\"claude-opus-5\",\"displayName\":\"Opus 5\",\"family\":\"claude\",\"launchId\":\"claude-opus-5[1m]\"}"
                .utf8))
        #expect(withLaunchId.id == "claude-opus-5")          // storage id stays plain
        #expect(withLaunchId.launchId == "claude-opus-5[1m]")
    }
}

@Suite("Model table — vendored offline catalog")
struct ModelCatalogTests {
    let adapter = ClaudeCodeAdapter()

    @Test("known model resolves its display name; carries no context window (dead data — Claude reports its own)")
    func knownModelHasNoWindow() {
        let m = adapter.model(for: "claude-opus-5")
        #expect(m.displayName == "Opus 5")
        #expect(m.contextWindow == nil)   // Claude's own statusline percentage is the only consumer of usage
    }

    @Test("opus carries a 1M launchId; its storage id stays plain (data, not a blanket rule)")
    func opusHasLaunchIdOtherModelsDoNot() {
        let opus = adapter.model(for: "claude-opus-5")
        #expect(opus.id == "claude-opus-5")            // storage/picker/routing id: unchanged
        #expect(opus.launchId == "claude-opus-5[1m]")   // only the launch argv reads this

        // fable-5-1 is natively 1M (no suffix); sonnet-5 and haiku-4-5 carry no 1M tier here.
        for id in ["claude-fable-5-1", "claude-sonnet-5", "claude-haiku-4-5"] {
            #expect(adapter.model(for: id).launchId == nil)
        }
    }

    @Test("unknown model id falls back (heuristic, no window)")
    func unknownModelFallsBack() {
        let m = adapter.model(for: "totally-made-up-model")
        #expect(m.id == "totally-made-up-model")
        #expect(m.contextWindow == nil)   // fallback: gauge hidden, never a fabricated denominator
    }

    @Test("models() is non-empty and every entry carries capability flags")
    func tableIsPopulated() {
        let models = adapter.models()
        #expect(!models.isEmpty)
        #expect(models.allSatisfy { $0.flags != nil })
    }

    @Test("table is loaded OFFLINE from a bundled local file (no network fetch)")
    func offlineLocalResource() throws {
        let url = try #require(Bundle.module.url(forResource: "claude-code-models", withExtension: "json"))
        #expect(url.isFileURL)                       // local vendored file, not a remote endpoint
        #expect(FileManager.default.fileExists(atPath: url.path))
        // And ModelCatalog reads exactly that file with no network.
        #expect(!ModelCatalog.load("claude-code-models").isEmpty)
    }

    @Test("test_ctxpct_from_model_table: tokens ÷ table contextWindow = ctxPct in the StatusReport")
    func ctxPctFromModelTable() throws {
        // The token-reporting (Codex-shaped) denominator path E1 provides for B2. Claude's own rows
        // carry no contextWindow (dead data removed), so this exercises the mechanism directly with a
        // synthetic table entry rather than through ClaudeCodeAdapter's catalog.
        let model = AgentModel(id: "x", displayName: "X", family: "claude", contextWindow: 200_000)
        let usedTokens = 40_000
        let pct = try #require(model.ctxPct(usedTokens: usedTokens))
        #expect(pct == 20.0)                                     // 40_000 / 200_000 * 100
        // …lands as the StatusReport.snapshot.ctxPct a tail adapter would emit:
        let report = StatusReport(ctxPct: pct, modelId: model.id)
        #expect(report.snapshot?.ctxPct == 20.0)
    }
}
