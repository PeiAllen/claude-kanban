import Foundation

/// Pure gating for the desktop half of F1: non-blocking spawn (PR4b) returns a `.creatingWorktree` card
/// BEFORE any tmux `agent` window exists, so `AgentTerminalView`'s immediate attach dies (session absent).
/// `Coordinator.processTerminated` only reschedules a reconnect if the live gate held at the instant the
/// pane died — false during `.creatingWorktree`/`.launching` — and `updateNSView` re-attaches only on a
/// TARGET change, so a card that reaches `.live` after its birth-time attach died shows a blank pane.
///
/// The fix drives a (re)attach on the `→ live` gate edge. This decision is the pure core so it can be
/// table-tested apart from the SwiftUI/SwiftTerm hosting. Agent-agnostic: it is phase-driven (Claude +
/// Codex alike) — nothing here inspects which agent runs in the pane.
public enum TerminalReattachDecision {
    /// Should a dead pane re-attach because the card just reached a renderable-live state?
    /// - Parameters:
    ///   - paneAlive: is the attached terminal process currently alive? (A live pane never re-attaches —
    ///     that keeps the reattach idempotent, so a normal `updateNSView` on a healthy pane is a no-op.)
    ///   - wasLive: did the live gate return true on the PREVIOUS update? (Guards against re-firing every
    ///     update once already live — we act only on the false→true edge.)
    ///   - isLive: does the live gate return true now?
    public static func shouldReattachOnLiveEdge(paneAlive: Bool, wasLive: Bool, isLive: Bool) -> Bool {
        !paneAlive && isLive && !wasLive
    }
}

/// Pure gating for the iOS half of F1 (phone auto-takeover). Phone-spawn requests a takeover the instant
/// `spawn` returns, but the card is still `.creatingWorktree` with no `agent` window, so the daemon rejects
/// the lease (`no agent window`) and `BoardStore` maps it to `nil`. `TakeoverController` used to treat that
/// `nil` as a PERMANENT failure ("Could not take over") and never retried — so a normal phone-spawn-into-
/// agent reliably failed.
///
/// The fix RETRIES while the card is being born, and — because the fixed backoff budget (~15–23s) can be
/// shorter than a long checkout — RE-ARMS that budget on the card's `→ live` edge (when the window finally
/// exists). Agent-agnostic: phase-driven, provider-blind.
public enum TakeoverRetryDecision {
    /// After a failed acquire, keep retrying? Only while the card is still being born and within budget.
    /// (A live/dead card that still fails to grant is a genuine failure, not a being-born transient.)
    public static func shouldRetry(beingBorn: Bool, attemptsSoFar: Int, maxAttempts: Int) -> Bool {
        beingBorn && attemptsSoFar < maxAttempts
    }

    /// A failure that won't retry: surface it as PERMANENT only when the card is NOT being born (it's
    /// live/dead and the grant still failed → a real problem). A being-born budget-exhaustion instead
    /// pauses in `.acquiring` until the `→ live` edge re-arms, so the user keeps seeing "Taking over…".
    public static func isPermanentFailure(beingBorn: Bool) -> Bool { !beingBorn }

    /// On the card's false→true `→ live` edge, re-arm the acquire budget and restart a paused/failed loop:
    /// the `agent` window now exists, so a takeover that gave up while the card was being born can succeed.
    public static func shouldRearmOnLive(wasLive: Bool, isLive: Bool) -> Bool { isLive && !wasLive }
}
