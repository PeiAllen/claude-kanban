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

    /// Extract the Stop hook's `stop_hook_active` flag from the RAW agent stdin JSON, at the edge — never
    /// via `Adapter.parse` (structurally impossible for Codex's report-less Stop; dropped by Claude's
    /// background-work hold). Agent-agnostic: both agents set this top-level boolean on a `decision:block`
    /// continuation Stop (L1 loop guard). Absent / non-bool → nil (a plain Stop, or a non-Stop event).
    public static func stopHookActive(_ payload: JSONValue) -> Bool? {
        payload["stop_hook_active"]?.boolValue
    }

    /// Build the `hook` RPC params the `_report` edge sends. Each optional field rides ONLY when present
    /// (like `epoch`), so absent ones fall back to the daemon defaults. Unconditional by construction:
    /// `stopHookActive` is read from the raw payload and rides even when `report` is nil (Codex's
    /// report-less Stop, Claude's bg-hold), so a continuation that yields to background work still confirms.
    public static func hookFields(ref: String, event: String, report: JSONValue?, source: String?,
                                  epoch: Int?, stopHookActive: Bool?) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["ref": .string(ref), "event": .string(event)]
        if let report { fields["report"] = report }
        if let source { fields["source"] = .string(source) }
        if let epoch { fields["epoch"] = .int(epoch) }
        if let stopHookActive { fields[stopHookActiveKey] = .bool(stopHookActive) }
        return fields
    }
}
