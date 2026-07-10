import Foundation

/// The bounded exponential backoff shared by both terminal hosts (iOS `IOSTerminalView`, mac
/// `AgentTerminalView`): attempt `n` (1-based) waits `min(8, 2^(n-1))` seconds, up to `maxReconnects`
/// attempts, then gives up. Pure — the host owns the timer, the pending-dedup flag, and the live gate.
public struct TerminalReconnectPolicy: Sendable, Equatable {
    public let maxReconnects: Int
    public init(maxReconnects: Int = 5) { self.maxReconnects = maxReconnects }

    /// Seconds to wait before attempt `n` (1-based), or `nil` to give up (budget spent / invalid attempt).
    public func delay(forAttempt n: Int) -> Int? {
        guard n >= 1, n <= maxReconnects else { return nil }
        return min(8, 1 << (n - 1))
    }
}
