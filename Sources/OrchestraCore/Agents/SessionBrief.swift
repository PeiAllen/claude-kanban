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
    /// One orientation sentence for a card. Always non-empty (every card has an id).
    ///
    /// The framing hinges on **`origin`**, which is the SAME predicate the daemon `move` guard uses
    /// (`origin == .worktree`): only a worktree card lives on the Plan → Implementation → Review board and
    /// can `move` itself between lanes. A freeform (`.borrowed`) or scratch (`.scratch`) card still carries
    /// a `column` value, but the board ignores it (it files those into the freeform dock by origin), and
    /// the daemon *rejects* their `move`s — so handing them the column/self-move text would provoke doomed
    /// self-moves. Keying orientation off `origin` here keeps it from drifting away from the move guard.
    public static func sentence(column: Column, access: CardAccess, shortId: String, origin: CardOrigin) -> String {
        // Access is orthogonal to origin: a read-only freeform investigation card is common.
        let mode = access == .readOnly
            ? " You are **read-only**: read, search, and run read-only git freely, but make no edits, "
              + "writes, or commits — report findings instead."
            : ""

        guard origin == .worktree else {
            // Freeform/scratch: no lifecycle column, nothing to `move` between. Noun mirrors the SharedUI
            // origin chip ("Scratch" for `.scratch`, "Freeform" for `.borrowed`).
            let noun = origin == .scratch ? "Scratch" : "Freeform"
            // A `.borrowed` card runs inside an existing project repo, so a fix it finds belongs on a
            // tracked branch, not on `main` or a hand-rolled branch: delegate it to a worktree card. A
            // `.scratch` card is a throwaway dir, not a project — no such guidance.
            let delegation = origin == .borrowed
                ? " If you find issues worth fixing in the project you're running in, don't fix them on "
                  + "`main` and don't hand-roll your own branch — `spawn` a plan/implementation card (a "
                  + "worktree card cuts its own branch) to do the work on a tracked branch."
                : ""
            // Naming nudge, worded for THIS branch: a branchless card is named after its read-only target
            // or its directory, so it must not be told it "starts named after its branch".
            return "Orchestra orientation: you are card `\(shortId)`, a standalone **\(noun)** card — it "
                + "runs on its own, not on the Plan → Implementation → Review board, so there's no column "
                + "to move between.\(mode) Begin on that footing without waiting to be told.\(delegation)"
                + " Your card is named after what it runs on, so give it a name of its own once the work "
                + "takes shape — `set-title \(shortId) <title>` — and update it as the work changes."
        }

        let lane: String
        switch column {
        case .plan:   lane = "the **Plan** column — scope and plan the work before building"
        case .impl:   lane = "the **Implementation** column — build the work"
        case .review: lane = "the **Review** column — review/verify the work, not start fresh implementation"
        }
        return "Orchestra orientation: you are card `\(shortId)` in \(lane).\(mode) "
            + "Begin on that footing without waiting to be told. As your work changes phase, keep your "
            + "column honest by moving yourself with the `move` tool (`move \(shortId) --col plan|impl|review`) "
            + "— e.g. plan→impl once you start building, impl→review once it's ready to look at. "
            + "Your card starts named after its branch, so name it for the work once that takes shape — "
            + "`set-title \(shortId) <title>` — and update it as the work changes."
    }
}
