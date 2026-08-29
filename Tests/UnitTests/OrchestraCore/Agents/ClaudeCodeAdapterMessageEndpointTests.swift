import Foundation
import Testing
@testable import OrchestraCore

@Suite("ClaudeCodeAdapter — hook message endpoint")
struct ClaudeCodeAdapterMessageEndpointTests {
    private let environment = [
        "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/claude-message.sock",
        "CLAUDE_CODE_MESSAGING_TOKEN": "runtime-secret",
    ]
    private let payload: JSONValue = .object(["session_id": .string("session-1")])

    @Test("Claude extracts a complete native endpoint from SessionStart and status-line hooks")
    func extractsSupportedHookEndpoints() {
        let adapter = ClaudeCodeAdapter()

        for event in [HookEvent.sessionStart, .statusLine] {
            #expect(adapter.hookMessageEndpoint(
                event: event,
                payload: payload,
                environment: environment
            ) == AgentMessageEndpointReport(
                providerId: adapter.id,
                harnessSessionId: "session-1",
                endpoint: .claudeHookRPC(
                    socketPath: "/tmp/claude-message.sock",
                    token: "runtime-secret"
                )
            ))
        }
    }

    @Test("Claude rejects unsupported hooks and incomplete native endpoint values")
    func rejectsUnsupportedOrIncompleteEndpoints() {
        let adapter = ClaudeCodeAdapter()

        #expect(adapter.hookMessageEndpoint(
            event: .stop,
            payload: payload,
            environment: environment
        ) == nil)
        #expect(adapter.hookMessageEndpoint(
            event: .sessionStart,
            payload: payload,
            environment: ["CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/only-socket"]
        ) == nil)
        #expect(adapter.hookMessageEndpoint(
            event: .statusLine,
            payload: .object([:]),
            environment: environment
        ) == nil)
    }

    @Test("other adapters do not interpret Claude messaging environment")
    func otherAdaptersIgnoreClaudeEnvironment() {
        #expect(CodexAdapter().hookMessageEndpoint(
            event: .sessionStart,
            payload: payload,
            environment: environment
        ) == nil)
    }
}
