import Foundation
import Testing
@testable import OrchestraCore

@Suite("Claude hook observation", .serialized)
struct ClaudeHookObservationTests {
    @Test("Claude uses pushed hooks without enabling process telemetry")
    func hookOnlyEndpointAndEnvironment() throws {
        let cardId = UUID()
        let setup = AgentObservationSetup(
            cardId: cardId,
            cardRef: "abc12345",
            sessionEpoch: 9,
            runtimeStateDir: "/runtime"
        )
        let adapter = ClaudeCodeAdapter()
        let endpoint = try #require(adapter.observationEndpoint(setup))
        #expect(endpoint == .pushed)

        let env = adapter.launchEnvironment(AdapterContext(cwd: "/wt", observationEndpoint: endpoint))
        #expect(env["CLAUDE_CODE_ENABLE_TELEMETRY"] == nil)
        #expect(env["CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"] == nil)
        #expect(env.keys.allSatisfy { !$0.hasPrefix("OTEL_") })
    }
}
