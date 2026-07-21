import Foundation

/// Composes drained `InboxMessage`s into the bounded payload the Claude Stop hook injects, and builds
/// the `decision:block` stdout that forces continuation. Pure + synchronous so it is trivially testable
/// and callable from the `_report` hook process.
///
/// Payload channel: the design (§8) names this "`additionalContext` (10k)". The concrete Claude Stop-hook
/// continuation field is `reason` on a `{"decision":"block"}` output — on `block`, `reason` is fed to the
/// model to tell it how to proceed. We cap the payload at 10k characters either way.
public enum StopDrain {
    /// The `additionalContext`/`reason` payload bound the Claude Stop hook enforces.
    public static let maxPayloadChars = 10_000

    /// The **channel-neutral operator-relayed header** prepended to inbox messages on every delivery path,
    /// so the framing is identical whichever agent drains them: Claude via the Stop hook (`compose`, this
    /// file) and Codex via the resume seed (`HandoffSeed.compose`). It deliberately says nothing about how
    /// the messages arrive ("turn-end", "hook", "seed") and does not expose card-to-card provenance in the
    /// model-facing text.
    ///
    /// Why it exists: inbox messages reach the model on channels it may distrust — Claude receives the
    /// Stop-hook `reason` framed as "Stop hook feedback:", indistinguishable without context from an
    /// automated hook nagging it. In the busy-task conflict probe, user-relayed language was acted on far
    /// more reliably than queue, inbox, or agent-attribution language. An Orchestra `send` is operator
    /// authorized, so the delivery text frames it as the user's relayed follow-up while the durable source
    /// remains available to people in the inbox editors.
    public static func inboxHeader(_ count: Int) -> String {
        count == 1
            ? "Message from the user (relayed to you via Orchestra):"
            : "Messages from the user (relayed to you via Orchestra):"
    }

    /// The largest single message the inbox accepts (`send` rejects anything over this at enqueue time).
    /// It is the payload budget minus the room a lone-message delivery spends on the operator-relayed header +
    /// separator, so **any accepted message is always delivered whole** — the truncation fallback in `fit`
    /// is unreachable for `send`-queued messages and only ever guards non-`send` enqueues.
    public static var maxMessageChars: Int { maxPayloadChars - inboxHeader(1).count - 2 }

    /// Render the operator-relayed header followed by the messages (FIFO) as a **numbered** blank-line list.
    /// Numbering (`[2/3] …`) is added only for multi-message batches, so the agent treats a pile-up as
    /// distinct actionable items rather than one run-on blob — the documented mitigation for the
    /// "curse of instructions" compliance drop when several instructions share a turn. A lone message
    /// needs no index. Shared by both delivery paths (Stop-hook `fit`/`compose` and the Codex resume
    /// seed's `HandoffSeed.compose`) so the framing is byte-identical whichever agent drains.
    public static func renderMessages(_ messages: [InboxMessage]) -> String {
        let header = inboxHeader(messages.count)
        guard messages.count > 1 else { return header + "\n\n" + (messages.first?.text ?? "") }
        let n = messages.count
        let body = messages.enumerated()
            .map { "[\($0.offset + 1)/\(n)] \($0.element.text)" }
            .joined(separator: "\n\n")
        return header + "\n\n" + body
    }

    /// Fit as many **whole** messages (FIFO) as fit under `budget`, rendered via `renderMessages`. Returns
    /// the payload and how many messages it consumed, so the caller drains exactly that many and leaves the
    /// remainder queued for the next turn-end — no message is ever silently sliced mid-text. Always
    /// consumes ≥1: a lone first message larger than the whole budget is delivered truncated rather than
    /// stranded forever. `nil` when there is nothing to deliver.
    public static func fit(_ messages: [InboxMessage],
                           budget: Int = maxPayloadChars) -> (payload: String, consumed: Int)? {
        guard !messages.isEmpty else { return nil }
        var fitted: (payload: String, consumed: Int)?
        for k in 1...messages.count {
            let rendered = renderMessages(Array(messages.prefix(k)))
            if rendered.count <= budget { fitted = (rendered, k) } else { break }
        }
        if let fitted { return fitted }
        // Even the first message alone overflows the budget → deliver it truncated (consumed = 1).
        let header = inboxHeader(1) + "\n\n"
        let marker = "\n\n[…truncated]"
        let keep = max(0, budget - header.count - marker.count)
        return (header + String(messages[0].text.prefix(keep)) + marker, 1)
    }

    /// Single-payload compose: fit everything into one bounded payload (truncating a lone oversized
    /// message). Callers that can re-queue the remainder should prefer `fit` + a bounded drain; this
    /// is retained for one-shot callers and tests. `nil` if there is nothing to inject.
    public static func compose(_ messages: [InboxMessage]) -> String? { fit(messages)?.payload }

    /// The Stop-hook stdout that blocks the stop and hands `reason` to the model to continue.
    public static func blockJSON(reason: String) -> String {
        if let data = try? JSONValue.string(reason).rawData(),
           let escapedReason = String(data: data, encoding: .utf8) {
            return #"{"decision":"block","reason":\#(escapedReason)}"#
        }
        return #"{"decision":"block","reason":""}"#
    }
}
