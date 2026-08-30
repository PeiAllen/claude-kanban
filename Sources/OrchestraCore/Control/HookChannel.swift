import Foundation

/// The core-owned hook vocabulary. rawValue == the `--event` string baked into the rendered hook file
/// (and the key the daemon dispatches on). No agent identity anywhere — a new agent maps its hooks onto
/// this shared set, and genuinely-new semantics grow it additively.
public enum HookEvent: String, Sendable, Codable, CaseIterable {
    case statusLine   = "statusline"
    case sessionStart = "session"      // Claude "session" + Codex "orient" collapse here
    case userPrompt   = "prompt"
    case preToolUse   = "pretool"
    case postToolUse  = "posttool"
    case postToolUseFailure = "posttoolfailure"
    case notification = "notification"
    case permission   = "permission"
    case taskCompleted = "taskcompleted"
    case stop         = "stop"
    case sessionEnd   = "sessionend"
}

/// How a `sessionStart` fired — gates orientation (skip on `.compact` so we don't re-announce mid-turn).
/// Normalized by the adapter at the edge (`Adapter.sessionSource`) so core never reads raw payload fields.
public enum SessionSource: String, Sendable, Codable {
    case startup, resume, clear, compact, other
}

/// The agent-neutral receive payload core computes and the adapter encodes to its stdout. Exactly one
/// field is set per event.
public struct HookResponse: Sendable, Codable, Equatable {
    public var additionalContext: String?   // sessionStart → orientation
    public init(additionalContext: String? = nil) {
        self.additionalContext = additionalContext
    }
}

/// The stdout envelopes Claude & Codex share today. A shared HELPER adapters CALL from `encode` — never
/// an implicit default, so a divergent future agent can't silently inherit this shape (A1 philosophy:
/// no adapter inherits another's format for free).
public enum HookEnvelope {
    /// Claude/Codex SessionStart hooks read `hookSpecificOutput.additionalContext` from stdout and fold
    /// it into the session's context. Returns `""` on the (unreachable) encode failure so nothing prints.
    public static func additionalContext(_ context: String) -> String {
        let obj = JSONValue.object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("SessionStart"),
                "additionalContext": .string(context),
            ])
        ])
        if let data = try? obj.rawData(), let s = String(data: data, encoding: .utf8) { return s }
        return ""
    }

}
