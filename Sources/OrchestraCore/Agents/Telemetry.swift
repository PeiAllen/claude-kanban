import Foundation

/// The raw, un-parsed unit of telemetry an Orchestra **transport** hands to `Adapter.parse`. Each case
/// is one transport shape, keyed by `AgentCapabilities.Telemetry`:
///   - `hooksPush`  — an agent-pushed hook event (`orchestra _report`): the event `kind` + its JSON
///                    `payload`. The transport is the ephemeral push process; parse is the adapter's.
///   - `fileTail`   — one line the daemon tailed from a rollout/transcript file (Codex, next PR B2).
///   - `rpcNotification` / `rpcResponse` — one decoded provider RPC message. The response case carries
///                    only the JSON-RPC `result`, paired with the originating request method.
///   - `traceSpanEnded` — one completed provider trace span after the receiver has decoded its attributes.
/// The **transport** owns only obtaining these bytes (push endpoint / tailer); the **adapter** owns the
/// agent-dependent conversion to either the legacy `StatusReport` or the replacement `AgentSignal`.
/// `ptyScrape` has no v1 consumer and is intentionally omitted until a scrape adapter needs it.
public enum RawTelemetry: Equatable, Sendable {
    case hooksPush(kind: String, payload: JSONValue)
    case fileTail(line: String)
    case rpcNotification(method: String, params: JSONValue)
    case rpcResponse(method: String, result: JSONValue)
    case traceSpanEnded(name: String, attributes: JSONValue)
}
