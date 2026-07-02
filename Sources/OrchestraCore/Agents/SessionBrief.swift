import Foundation

/// Composes the short, agent-agnostic orientation an agent reads at **SessionStart**: which board
/// column it's in, whether it's read-only, and its own card id (so it can `move` itself as the work
/// changes phase). Injected as the Claude SessionStart hook's `additionalContext` — the open-time
/// counterpart to [[StopDrain]] (which injects the inbox at turn-end). Pure + synchronous so it's
/// trivially testable and callable from the `_report` hook process.
///
/// The point is that an agent shouldn't need to be *told* "you're planning" / "you're implementing" /
/// "you're read-only" — the board already knows, so we hand it that context the moment it starts. The
/// column is read **live** (not the launch-time `startIn`), so a reopened or dragged card gets its
/// current lane. This is a suggestion, not a leash: the sentence nudges, it doesn't constrain.
public enum SessionBrief {
    /// One orientation sentence for a card. Always non-empty (every card has a column + id).
    public static func sentence(column: Column, access: CardAccess, shortId: String) -> String {
        let lane: String
        switch column {
        case .plan:   lane = "the **Plan** column — scope and plan the work before building"
        case .impl:   lane = "the **Implementation** column — build the work"
        case .review: lane = "the **Review** column — review/verify the work, not start fresh implementation"
        }
        let mode = access == .readOnly
            ? " You are **read-only**: read, search, and run read-only git freely, but make no edits, "
              + "writes, or commits — report findings instead."
            : ""
        return "Orchestra orientation: you are card `\(shortId)` in \(lane).\(mode) "
            + "Begin on that footing without waiting to be told. As your work changes phase, keep your "
            + "column honest by moving yourself with the `move` tool (`move \(shortId) --col plan|impl|review`) "
            + "— e.g. plan→impl once you start building, impl→review once it's ready to look at."
    }

    /// Wrap a brief in the Claude SessionStart hook's stdout envelope. Claude reads
    /// `hookSpecificOutput.additionalContext` on a SessionStart hook and folds it into the session's
    /// context. Returns `""` on the (unreachable) encode failure so the hook prints nothing.
    public static func claudeSessionStartJSON(_ context: String) -> String {
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
