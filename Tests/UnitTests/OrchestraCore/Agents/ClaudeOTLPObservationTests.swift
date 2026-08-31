import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OrchestraCore
import TestSupport

@Suite("Claude OTLP turn completion", .serialized)
struct ClaudeOTLPObservationTests {
    @Test("Claude selects the shared trace receiver and exports only interaction spans as HTTP JSON")
    func endpointAndEnvironment() throws {
        let cardId = UUID()
        let setup = AgentObservationSetup(
            cardId: cardId,
            cardRef: "abc12345",
            sessionEpoch: 9,
            runtimeStateDir: "/runtime",
            traceHTTPBaseURL: "http://127.0.0.1:43181/secret"
        )
        let adapter = ClaudeCodeAdapter()
        let endpoint = try #require(adapter.observationEndpoint(setup))
        #expect(endpoint.otlpHTTPURL ==
                "http://127.0.0.1:43181/secret/v1/traces/\(cardId.uuidString.lowercased())/9")

        let env = adapter.launchEnvironment(AdapterContext(cwd: "/wt", observationEndpoint: endpoint))
        #expect(env["CLAUDE_CODE_ENABLE_TELEMETRY"] == "1")
        #expect(env["CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"] == "1")
        #expect(env["OTEL_TRACES_EXPORTER"] == "otlp")
        #expect(env["OTEL_EXPORTER_OTLP_TRACES_PROTOCOL"] == "http/json")
        #expect(env["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] == endpoint.otlpHTTPURL)
        #expect(env["OTEL_EXPORTER_OTLP_TRACES_COMPRESSION"] == "none")
        #expect(env["OTEL_METRICS_EXPORTER"] == "none")
        #expect(env["OTEL_LOGS_EXPORTER"] == "none")
        #expect(env["OTEL_TRACES_EXPORT_INTERVAL"] == "250")
    }

    @Test("OTLP JSON decoding emits only ended interaction roots and preserves session identity")
    func decoder() throws {
        let cardId = UUID()
        let observations = try OTLPTraceDecoder.decode(
            exportPayload(sessionId: "claude-session"),
            cardId: cardId,
            sessionEpoch: 7
        )
        #expect(observations.count == 1)
        let observation = try #require(observations.first)
        #expect(observation.cardId == cardId)
        #expect(observation.sessionEpoch == 7)
        guard case .traceSpanEnded(let name, let attributes) = observation.raw else {
            Issue.record("expected a completed trace span")
            return
        }
        #expect(name == "claude_code.interaction")
        #expect(attributes["session.id"] == .string("claude-session"))
        #expect(attributes["interaction.sequence"] == .int(3))
        #expect(attributes["service.name"] == .string("claude-code"))
    }

    @Test("the local receiver accepts a real OTLP request and keeps its endpoint stable across restart")
    func receiverRoundTripAndStableEndpoint() async throws {
        let root = NSTemporaryDirectory() + "orch-otlp-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recorder = OTLPObservationRecorder()
        let receiver = try OTLPHTTPTraceReceiver(runtimeStateDir: root)
        let firstBaseURL = receiver.baseURL
        receiver.start { recorder.append($0) }
        let cardId = UUID()
        let observationEndpoint = try #require(ClaudeCodeAdapter().observationEndpoint(.init(
            cardId: cardId,
            cardRef: "card",
            sessionEpoch: 11,
            runtimeStateDir: root,
            traceHTTPBaseURL: firstBaseURL
        )))
        let endpoint = try #require(observationEndpoint.otlpHTTPURL)

        var request = URLRequest(url: try #require(URL(string: endpoint)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = exportPayload(sessionId: "claude-session")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        try await pollUntil("OTLP request to reach the receiver") { recorder.values.count == 1 }
        #expect(recorder.values.first?.cardId == cardId)
        #expect(recorder.values.first?.sessionEpoch == 11)
        receiver.stop()

        for _ in 0..<5 {
            let restarted = try OTLPHTTPTraceReceiver(runtimeStateDir: root)
            #expect(restarted.baseURL == firstBaseURL)
            restarted.start { _ in }
            restarted.stop()
        }
    }

    private func exportPayload(sessionId: String) -> Data {
        Data(#"""
        {
          "resourceSpans": [{
            "resource": {"attributes": [
              {"key": "service.name", "value": {"stringValue": "claude-code"}},
              {"key": "session.id", "value": {"stringValue": "\#(sessionId)"}}
            ]},
            "scopeSpans": [{"spans": [
              {
                "name": "claude_code.interaction",
                "attributes": [
                  {"key": "interaction.sequence", "value": {"intValue": "3"}}
                ]
              },
              {"name": "claude_code.tool", "attributes": []}
            ]}]
          }]
        }
        """#.utf8)
    }
}

private final class OTLPObservationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [OTLPTraceObservation] = []

    var values: [OTLPTraceObservation] { lock.withLock { stored } }
    func append(_ observation: OTLPTraceObservation) {
        lock.withLock { stored.append(observation) }
    }
}
