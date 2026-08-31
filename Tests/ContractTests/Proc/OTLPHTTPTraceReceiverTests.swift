import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OrchestraCore

@Suite("OTLP HTTP trace receiver — process contract", .serialized)
struct OTLPHTTPTraceReceiverTests {
    @Test("the listener is not inherited by child processes and its endpoint survives restart")
    func listenerIsCloseOnExecAndEndpointIsStable() async throws {
        let root = NSTemporaryDirectory() + "orch-otlp-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let receiver = try OTLPHTTPTraceReceiver(runtimeStateDir: root)
        let firstBaseURL = receiver.baseURL
        receiver.start { _ in }

        let endpoint = firstBaseURL + "/v1/traces/\(UUID().uuidString.lowercased())/11"
        var request = URLRequest(url: try #require(URL(string: endpoint)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"resourceSpans":[]}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        // A long-lived child deterministically pins every descriptor lacking FD_CLOEXEC. Without the
        // listener fence, stop closes only the parent's copy and the persisted port cannot be rebound.
        let inheritor = Process()
        inheritor.executableURL = URL(fileURLWithPath: "/bin/sleep")
        inheritor.arguments = ["5"]
        try inheritor.run()
        defer {
            if inheritor.isRunning { inheritor.terminate() }
            inheritor.waitUntilExit()
        }

        receiver.stop()
        let restarted = try OTLPHTTPTraceReceiver(runtimeStateDir: root)
        #expect(restarted.baseURL == firstBaseURL)
        restarted.start { _ in }
        restarted.stop()
    }
}
