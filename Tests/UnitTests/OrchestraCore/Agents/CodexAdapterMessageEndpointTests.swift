import Foundation
import Testing
@testable import OrchestraCore

@Suite("CodexAdapter — native message endpoint")
struct CodexAdapterMessageEndpointTests {
    @Test("derives a thread-bound message endpoint from the prepared app-server socket")
    func derivesEndpoint() {
        let adapter = CodexAdapter()

        #expect(adapter.messageEndpoint(
            observationEndpoint: .unixSocket(path: "/runtime/codex-card.sock"),
            harnessSessionId: "thread-1"
        ) == .codexAppServer(socketPath: "/runtime/codex-card.sock", threadId: "thread-1"))
        #expect(adapter.messageEndpoint(
            observationEndpoint: .pushed,
            harnessSessionId: "thread-1"
        ) == nil)
        #expect(ClaudeCodeAdapter().messageEndpoint(
            observationEndpoint: .unixSocket(path: "/runtime/codex-card.sock"),
            harnessSessionId: "thread-1"
        ) == nil)
    }

    @Test("builds only complete Codex app-server sender endpoints")
    func senderFactory() {
        let adapter = CodexAdapter()

        #expect(adapter.makeMessageSender(for: .codexAppServer(
            socketPath: "/runtime/codex-card.sock",
            threadId: "thread-1"
        )) is CodexMessageSender)
        #expect(adapter.makeMessageSender(for: .codexAppServer(
            socketPath: "",
            threadId: "thread-1"
        )) == nil)
        #expect(adapter.makeMessageSender(for: .codexAppServer(
            socketPath: "/runtime/codex-card.sock",
            threadId: ""
        )) == nil)
        #expect(adapter.makeMessageSender(for: .claudeHookRPC(
            socketPath: "/runtime/claude.sock",
            token: "secret"
        )) == nil)
    }
}
