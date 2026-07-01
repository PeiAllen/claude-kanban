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

    /// Join drained messages (FIFO) into one bounded payload; `nil` if there is nothing to inject.
    public static func compose(_ messages: [InboxMessage]) -> String? {
        guard !messages.isEmpty else { return nil }
        let joined = messages.map(\.text).joined(separator: "\n\n")
        guard joined.count > maxPayloadChars else { return joined }
        let marker = "[…truncated]\n"
        let keep = maxPayloadChars - marker.count
        return marker + String(joined.prefix(max(0, keep)))
    }

    /// The Stop-hook stdout that blocks the stop and hands `reason` to the model to continue.
    public static func blockJSON(reason: String) -> String {
        let obj = JSONValue.object(["decision": .string("block"), "reason": .string(reason)])
        if let data = try? obj.rawData(), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return #"{"decision":"block","reason":""}"#
    }
}
