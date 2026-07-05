import Foundation
import Combine
import OrchestraUI

/// Client-local snooze/dismiss state for the Needs You queue (design §6). Purely a phone-UI concern —
/// snoozing hides a card's attention row (and drops it from the tab badge) until the snooze lifts; it
/// never touches the daemon or the card's real state. Keyed by card id → the instant the snooze
/// expires (`.distantFuture` for an indefinite **Dismiss**). Owned by `OrchestraiOSApp` and shared with
/// the tab badge so both agree on what's suppressed.
@MainActor
final class NeedsYouSnooze: ObservableObject {
    @Published private var until: [UUID: Date] = [:]

    /// A short menu of snooze durations offered per row.
    static let options: [(label: String, interval: TimeInterval)] = [
        ("15 min", 15 * 60), ("1 hour", 60 * 60), ("Until tomorrow", 8 * 60 * 60),
    ]

    /// Read-only, non-mutating (safe to call from a view body): is this card currently suppressed?
    func isSnoozed(_ id: UUID, now: Date = Date()) -> Bool {
        guard let d = until[id] else { return false }
        return d > now
    }

    func snooze(_ id: UUID, for interval: TimeInterval, now: Date = Date()) {
        until[id] = now.addingTimeInterval(interval)
    }
    /// Indefinite dismiss — suppressed until the card leaves the queue and `reconcile` prunes it (or the
    /// user un-snoozes). Re-alerts naturally: once the card resolves, `reconcile` clears it, so a fresh
    /// attention state later is shown again.
    func dismiss(_ id: UUID) { until[id] = .distantFuture }
    func clear(_ id: UUID) { until[id] = nil }

    /// Drop snoozes for cards no longer in the queue, so a card that resolves and *later* re-alerts is
    /// not still suppressed by a stale snooze. Call when the attention set changes.
    func reconcile(activeIds: Set<UUID>) {
        let pruned = until.filter { activeIds.contains($0.key) }
        if pruned.count != until.count { until = pruned }
    }

    /// The visible subset of a queue with snoozed rows removed.
    func visible(_ items: [AttentionItem], now: Date = Date()) -> [AttentionItem] {
        items.filter { !isSnoozed($0.id, now: now) }
    }
}
