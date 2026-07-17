import Foundation

/// Folds an authored handoff/fork seed **plus** a card's pending inbox into ONE bounded string that is
/// delivered as the resumed session's opening turn (F1). The inbox "folds into the seed" (design §8 F1):
/// on a resume — a handoff/fork, or an idle-wake relaunch (`.relaunch`) — the pending inbox rides the
/// opening turn instead of a live drain (that's the Stop hook, on a turn already running). Handoff context
/// comes first, then the inbox in FIFO order. Pure + synchronous → trivially testable, callable from
/// `resumeInCard`.
public enum HandoffSeed {
    /// Handoff text (trimmed; dropped if empty) followed by the pending `inbox` under the shared
    /// `StopDrain.inboxHeader` provenance line (so a Codex card draining via the seed gets the *same*
    /// framing a Claude card gets via the Stop hook — agent-agnostic), in FIFO order, joined by blank
    /// lines. The header rides only the inbox portion, so a pure handoff/fork seed is unchanged. `nil`
    /// when there is nothing to deliver. Bounded to `StopDrain.maxPayloadChars` (the same 10k
    /// live-delivery channel bound) with a `[…truncated]` prefix when it overflows.
    public static func fold(handoff: String?, inbox: [InboxMessage]) -> String? {
        var parts: [String] = []
        if let h = handoff?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty { parts.append(h) }
        if !inbox.isEmpty { parts.append(StopDrain.renderMessages(inbox)) }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: "\n\n")
        guard joined.count > StopDrain.maxPayloadChars else { return joined }
        let marker = "[…truncated]\n"
        let keep = StopDrain.maxPayloadChars - marker.count
        return marker + String(joined.prefix(max(0, keep)))
    }

    /// The FINAL argv seed for a `relaunchSeed` claim: the handoff part, then the pending inbox under
    /// `StopDrain.inboxHeader`, whole-message FIFO fit under ONE budget — and the count of messages the
    /// payload actually consumed.
    ///
    /// This is `Inbox.claim`'s render for the cold route, which is the point: the claim's
    /// consumed-prefix guarantee must cover the *final* argv bytes. Folding messages in AFTER the claim
    /// (the shape `fold` serves) could re-truncate and leave leased-but-unrendered messages to be
    /// confirmed — silent loss. `batch.payload` is therefore the argv seed verbatim, never re-folded.
    ///
    /// `consumed == 0` with a non-empty payload is the handoff-only case: a handoff's context is never
    /// silently dropped by an empty inbox. `nil` means genuinely nothing to seed.
    public static func compose(handoff: String?, messages: [InboxMessage],
                               budget: Int = StopDrain.maxPayloadChars) -> (payload: String, consumed: Int)? {
        let head = handoff?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !head.isEmpty else {
            // No handoff → the seed is exactly the message render (or nothing).
            return StopDrain.fit(messages, budget: budget)
        }
        let sep = "\n\n"
        let remaining = budget - head.count - sep.count
        // `StopDrain.fit` ALWAYS consumes ≥1, truncating a lone oversized message rather than stranding
        // it forever. That is safe at the full 10k budget (`maxMessageChars` guarantees any send-queued
        // message fits whole, so the fallback is unreachable), but here the handoff has already eaten the
        // budget — so the fallback IS reachable, and it would report `consumed: 1` for a message it only
        // rendered a PREFIX of. The claim would lease it and a later confirm would delete the full
        // original: silent partial loss, exactly what this design exists to prevent. It can also return a
        // body longer than `remaining` (header + marker alone can exceed it), blowing the argv budget.
        //
        // So only delegate to `fit` once a WHOLE first message provably fits; otherwise seed the handoff
        // alone with zero consumed. The messages stay pending and deliver on the next claim, which has the
        // full budget (a relaunch clears `pendingSeed`), so nothing is stranded.
        if remaining > 0, let first = messages.first,
           StopDrain.renderMessages([first]).count <= remaining,
           let (body, consumed) = StopDrain.fit(messages, budget: remaining) {
            return (head + sep + body, consumed)
        }
        // Handoff-only. Mirror `fold`'s truncation marker so a cut seed is self-evident downstream.
        // Cap the WHOLE thing at budget (marker included) — at a sub-marker budget the marker itself is
        // truncated rather than overrunning; `payload.count <= budget` must hold at every budget, not just
        // the realistic 10k route. `String.prefix` on a non-positive count is a safe empty string.
        guard head.count > budget else { return (head, 0) }
        let marker = "[…truncated]\n"
        return (String((marker + head).prefix(budget)), 0)
    }
}
