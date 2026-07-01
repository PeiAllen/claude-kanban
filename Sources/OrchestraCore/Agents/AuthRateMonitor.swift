import Foundation

/// Advisory result of the authMode soft-warn: one adapter is running "too many" concurrent
/// subscription-auth cards. Carries the numbers so the surface (activity feed) can render a message.
/// This is **never** an error — q4 resolved to soft-warn only, with NO concurrency cap.
public struct AuthWarning: Sendable, Equatable {
    /// The adapter (subscription seat) the warning is about.
    public let agentId: String
    /// The adapter's display name, for the message.
    public let agentName: String
    /// Concurrent subscription-auth cards on this adapter (INCLUDING the card being brought up).
    public let count: Int
    /// The threshold `count` exceeded to trigger this warning.
    public let threshold: Int

    public init(agentId: String, agentName: String, count: Int, threshold: Int) {
        self.agentId = agentId; self.agentName = agentName; self.count = count; self.threshold = threshold
    }

    /// The human-readable advisory shown in the activity feed.
    public var message: String {
        "\(count) concurrent \(agentName) subscription agents running — heavy parallel fan-out on one "
        + "subscription seat can trip shared rate limits / anti-automation limits. "
        + "Consider API-key mode for large fan-outs (advisory only — not blocked)."
    }
}

/// Owns the **per-adapter rate state** for the authMode soft-warn (D12 / SSOT §9). It tallies active
/// subscription-auth cards grouped by `agentId` — each provider subscription is its own seat, so Claude
/// and Codex fan-outs are counted independently — and returns an `AuthWarning` when bringing up one more
/// card pushes that adapter's tally past `threshold`.
///
/// Pure and stateless: the "rate state" is DERIVED from the live card set (the SSOT), so it can't drift
/// and survives a daemon restart. It **never** caps — q4 resolved to warn-only; the caller always spawns.
public struct AuthRateMonitor: Sendable {
    /// Concurrent subscription cards (per adapter) that must be EXCEEDED to warn. `3` → the 4th+ warns.
    public static let defaultThreshold = 3

    public let threshold: Int
    public init(threshold: Int = AuthRateMonitor.defaultThreshold) { self.threshold = threshold }

    /// Whether an adapter is on subscription auth (only these count / can warn). Unknown ids → false.
    private func isSubscription(_ agentId: String, _ registry: AgentRegistry) -> Bool {
        (try? registry.get(agentId))?.capabilities.authMode == .subscription
    }

    /// Per-adapter count of active SUBSCRIPTION-auth cards. apiKey adapters (and unknown ids) are
    /// excluded entirely — they never appear in the tally.
    public func subscriptionTally(active: [Task], registry: AgentRegistry) -> [String: Int] {
        var tally: [String: Int] = [:]
        for t in active where isSubscription(t.agentId, registry) {
            tally[t.agentId, default: 0] += 1
        }
        return tally
    }

    /// The warn decision for `agentId`, given the current `active` card set (which MUST already include
    /// the card being brought up, so the tally reflects post-spawn concurrency). Returns nil for apiKey /
    /// unknown adapters, or when the tally does not exceed `threshold`. NEVER caps.
    public func warning(for agentId: String, active: [Task], registry: AgentRegistry) -> AuthWarning? {
        guard let adapter = try? registry.get(agentId),
              adapter.capabilities.authMode == .subscription else { return nil }
        let count = subscriptionTally(active: active, registry: registry)[agentId] ?? 0
        guard count > threshold else { return nil }
        return AuthWarning(agentId: agentId, agentName: adapter.name, count: count, threshold: threshold)
    }
}
