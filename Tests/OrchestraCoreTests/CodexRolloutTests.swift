import Foundation
import Testing
@testable import OrchestraCore

@Suite("Codex model table — vendored offline (E1 denominator for B2)")
struct CodexModelTableTests {
    let adapter = CodexAdapter()

    @Test("known Codex model resolves to its offline context window")
    func knownModelHasWindow() {
        let m = adapter.model(for: "gpt-5-codex")
        #expect(m.contextWindow == 272_000)
        #expect(m.displayName == "GPT-5 Codex")
    }

    @Test("unknown Codex model id falls back (no fabricated window)")
    func unknownFallsBack() {
        let m = adapter.model(for: "totally-made-up")
        #expect(m.id == "totally-made-up")
        #expect(m.contextWindow == nil)
    }

    @Test("table is loaded OFFLINE from the bundled local file (no network)")
    func offlineLocalResource() throws {
        let url = try #require(Bundle.module.url(forResource: "codex-models", withExtension: "json"))
        #expect(url.isFileURL)
        #expect(!ModelCatalog.load("codex-models").isEmpty)
    }

    @Test("every table entry carries a positive context window")
    func populated() {
        #expect(adapter.models().allSatisfy { ($0.contextWindow ?? 0) > 0 })
    }
}
