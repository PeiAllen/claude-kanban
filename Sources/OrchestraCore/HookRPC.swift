import Foundation

/// Hook-channel RPC wire helpers, shared by the `_report` edge (`ReportHelper`, which BUILDS the `hook`
/// params) and `ControlServer` (which DECODES them). Keeping the field construction here — not inline in
/// the `orchestra` executable target, which tests can't `@testable import` — makes the ReportHelper→RPC
/// wiring unit-testable, and gives the builder and the decoder ONE key string so a typo can't silently
/// break every real continuation's stop-drain confirm.
public enum HookRPC {
    /// The sibling field carrying the Stop hook's `stop_hook_active` loop-guard flag. Camel-case on the
    /// wire like `epoch`/`ref`/`event`; referenced by BOTH `hookFields` and the `ControlServer` decode.
    public static let stopHookActiveKey = "stopHookActive"
    /// The raw payload for the two turn-boundary hooks consumed by the replacement adapter reducer.
    /// Tool/input payloads stay at the edge until their independent activity/request reconciliation is
    /// implemented, so this field does not turn the hook channel into a general raw-event mirror.
    public static let observationPayloadKey = "observationPayload"
    /// Optional, ephemeral provider-message endpoint. Its credential is manually encoded for this one
    /// local RPC and decoded into non-Codable runtime values; it must never be logged or persisted.
    public static let messageEndpointKey = "messageEndpoint"

    private static let claudeMessagingSocketKey = "CLAUDE_CODE_MESSAGING_SOCKET"
    private static let claudeMessagingTokenKey = "CLAUDE_CODE_MESSAGING_TOKEN"

    /// Extract the Stop hook's `stop_hook_active` flag from the RAW agent stdin JSON, at the edge — never
    /// via `Adapter.parse` (structurally impossible for Codex's report-less Stop; dropped by Claude's
    /// background-work hold). Agent-agnostic: both agents set this top-level boolean on a `decision:block`
    /// continuation Stop (L1 loop guard). Absent / non-bool → nil (a plain Stop, or a non-Stop event).
    public static func stopHookActive(_ payload: JSONValue) -> Bool? {
        payload["stop_hook_active"]?.boolValue
    }

    /// Capture Claude's session-local hook RPC endpoint only when all identity and credential pieces are
    /// present. The returned value is runtime-only; the environment dictionary is never retained.
    public static func claudeMessageEndpoint(
        providerId: String,
        harnessSessionId: String?,
        environment: [String: String]
    ) -> AgentMessageEndpointReport? {
        guard !providerId.isEmpty,
              let harnessSessionId, !harnessSessionId.isEmpty,
              let socketPath = environment[claudeMessagingSocketKey], !socketPath.isEmpty,
              let token = environment[claudeMessagingTokenKey], !token.isEmpty
        else { return nil }
        return AgentMessageEndpointReport(
            providerId: providerId,
            harnessSessionId: harnessSessionId,
            endpoint: .claudeHookRPC(socketPath: socketPath, token: token)
        )
    }

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

    /// Build the `hook` RPC params the `_report` edge sends. Each optional field rides ONLY when present
    /// (like `epoch`), so absent ones fall back to the daemon defaults. Unconditional by construction:
    /// `stopHookActive` is read from the raw payload and rides even when `report` is nil (Codex's
    /// report-less Stop, Claude's bg-hold), so a continuation that yields to background work still confirms.
    public static func hookFields(ref: String, event: String, report: JSONValue?, source: String?,
                                  epoch: Int?, stopHookActive: Bool?,
                                  observationPayload: JSONValue? = nil,
                                  messageEndpoint: AgentMessageEndpointReport? = nil) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["ref": .string(ref), "event": .string(event)]
        if let report { fields["report"] = report }
        if let source { fields["source"] = .string(source) }
        if let epoch { fields["epoch"] = .int(epoch) }
        if let stopHookActive { fields[stopHookActiveKey] = .bool(stopHookActive) }
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
            }
        }
        return fields
    }
}
