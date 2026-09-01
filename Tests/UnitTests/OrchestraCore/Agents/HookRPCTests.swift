import Foundation
import Testing
@testable import OrchestraCore

@Suite("HookRPC endpoint fields")
struct HookRPCTests {
    @Test("provider message endpoints round-trip only through the ephemeral hook field")
    func claudeMessageEndpointRoundTrip() {
        let captured = AgentMessageEndpointReport(
            providerId: "claude-code",
            harnessSessionId: "session-1",
            endpoint: .claudeHookRPC(
                socketPath: "/tmp/claude-message.sock",
                token: "runtime-secret"
            )
        )

        let fields = HookRPC.hookFields(
            ref: "c", event: "statusline", report: nil, source: nil,
            epoch: 9, messageEndpoint: captured
        )
        #expect(HookRPC.messageEndpoint(fields[HookRPC.messageEndpointKey]) == captured)
    }
}
