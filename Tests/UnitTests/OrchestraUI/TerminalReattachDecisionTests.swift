import Testing
@testable import OrchestraKit

/// The pure `→ live` edge gating shared by the desktop `AgentTerminalView` and the iOS
/// `TakeoverController` (F1): non-blocking spawn (PR4b) returns a `.creatingWorktree` card before any
/// tmux `agent` window exists, so a terminal that attaches immediately dies (session absent). Both
/// surfaces must (re)attach when the card later reaches `.live`. This tests the extracted decision only —
/// the SwiftUI/SwiftTerm hosting is verified on a built app.
@Suite struct TerminalReattachDecisionTests {

    // Desktop: reattach EXACTLY on the dead-pane × false→true live edge, and never otherwise.
    @Test func test_reattachOnLiveEdge() {
        // dead pane, card just became live (false→true edge) → reattach the blank pane
        #expect(TerminalReattachDecision.shouldReattachOnLiveEdge(paneAlive: false, wasLive: false, isLive: true))
        // live pane → never reattach (idempotent: don't double-attach a healthy pane)
        #expect(!TerminalReattachDecision.shouldReattachOnLiveEdge(paneAlive: true, wasLive: false, isLive: true))
        // already-live gate (no edge) → don't re-fire on every subsequent update
        #expect(!TerminalReattachDecision.shouldReattachOnLiveEdge(paneAlive: false, wasLive: true, isLive: true))
        // card not (yet) live → nothing to attach to
        #expect(!TerminalReattachDecision.shouldReattachOnLiveEdge(paneAlive: false, wasLive: false, isLive: false))
    }

    // iOS: a takeover that fails while the card is being born RETRIES within budget; a live/dead card
    // that still fails does NOT retry (that path is a genuine failure).
    @Test func test_takeoverRetry_whileBeingBornWithinBudget() {
        let max = 5
        #expect(TakeoverRetryDecision.shouldRetry(beingBorn: true, attemptsSoFar: 1, maxAttempts: max))
        #expect(TakeoverRetryDecision.shouldRetry(beingBorn: true, attemptsSoFar: 4, maxAttempts: max))
        #expect(!TakeoverRetryDecision.shouldRetry(beingBorn: true, attemptsSoFar: 5, maxAttempts: max))  // budget spent
        #expect(!TakeoverRetryDecision.shouldRetry(beingBorn: false, attemptsSoFar: 1, maxAttempts: max)) // live/dead → don't retry
    }

    // A failure that won't retry is only PERMANENT (surface the error) when the card is not being born.
    @Test func test_takeoverPermanentFailure_onlyWhenNotBeingBorn() {
        #expect(TakeoverRetryDecision.isPermanentFailure(beingBorn: false))  // live/dead + grant failed → real error
        #expect(!TakeoverRetryDecision.isPermanentFailure(beingBorn: true))  // being born → pause, wait for →live
    }

    // Re-arm the acquire budget only on the card's false→true `→ live` edge (the window now exists).
    @Test func test_takeoverRearm_onLiveEdge() {
        #expect(TakeoverRetryDecision.shouldRearmOnLive(wasLive: false, isLive: true))   // edge → re-arm
        #expect(!TakeoverRetryDecision.shouldRearmOnLive(wasLive: true, isLive: true))   // already live → no re-arm
        #expect(!TakeoverRetryDecision.shouldRearmOnLive(wasLive: false, isLive: false)) // never became live
    }
}
