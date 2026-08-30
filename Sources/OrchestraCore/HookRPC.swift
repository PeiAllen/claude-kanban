import Foundation

/// Hook-channel RPC wire helpers, shared by the `_report` edge (`ReportHelper`, which BUILDS the `hook`
/// params) and `ControlServer` (which DECODES them). Keeping the field construction here — not inline in
/// the `orchestra` executable target, which tests can't `@testable import` — makes the ReportHelper→RPC
/// wiring unit-testable, and gives the builder and the decoder one shared key vocabulary.
public enum HookRPC {
    /// The compact adapter-selected status payload consumed by the provider reducer. The edge projects
    /// only provider fields used for turn, activity, or human-need observations, so this does not turn the
    /// hook channel into a general raw-event mirror.
    public static let observationPayloadKey = "observationPayload"
    /// Optional, ephemeral provider-message endpoint. Its credential is manually encoded for this one
    /// local RPC and decoded into non-Codable runtime values; it must never be logged or persisted.
    public static let messageEndpointKey = "messageEndpoint"

    /// Decode the manually-shaped local hook field. Malformed/partial values fail closed to nil.
    public static func messageEndpoint(_ value: JSONValue?) -> AgentMessageEndpointReport? {
        guard let value,
              value["kind"]?.stringValue == "claudeHookRPC",
              let providerId = value["providerId"]?.stringValue, !providerId.isEmpty,
              let harnessSessionId = value["harnessSessionId"]?.stringValue, !harnessSessionId.isEmpty,
              let socketPath = value["socketPath"]?.stringValue, !socketPath.isEmpty,
              let token = value["token"]?.stringValue, !token.isEmpty
        else { return nil }
        return AgentMessageEndpointReport(
            providerId: providerId,
            harnessSessionId: harnessSessionId,
            endpoint: .claudeHookRPC(socketPath: socketPath, token: token)
        )
    }

    /// Build the `hook` RPC params the `_report` edge sends. Each optional field rides only when present.
    public static func hookFields(ref: String, event: String, report: JSONValue?, source: String?,
                                  epoch: Int?,
                                  observationPayload: JSONValue? = nil,
                                  messageEndpoint: AgentMessageEndpointReport? = nil) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["ref": .string(ref), "event": .string(event)]
        if let report { fields["report"] = report }
        if let source { fields["source"] = .string(source) }
        if let epoch { fields["epoch"] = .int(epoch) }
        if let observationPayload { fields[observationPayloadKey] = observationPayload }
        if let messageEndpoint {
            switch messageEndpoint.endpoint {
            case .claudeHookRPC(let socketPath, let token):
                fields[messageEndpointKey] = .object([
                    "kind": .string("claudeHookRPC"),
                    "providerId": .string(messageEndpoint.providerId),
                    "harnessSessionId": .string(messageEndpoint.harnessSessionId),
                    "socketPath": .string(socketPath),
                    "token": .string(token),
                ])
            case .codexAppServer:
                // Codex derives this launch-local socket from the runtime observation endpoint. It never
                // rides a hook payload, so its path cannot become an alternate hook-controlled endpoint.
                break
            }
        }
        return fields
    }
}
