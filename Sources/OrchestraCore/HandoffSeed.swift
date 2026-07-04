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
}
