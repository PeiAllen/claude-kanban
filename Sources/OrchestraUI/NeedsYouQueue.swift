import Foundation
import OrchestraKit

// Pure, view-free logic for the Needs You attention queue (mobile design §6), re-homed (BT slice 5) onto
// the 3b attention fold — the ONE definition of "needs you" shared with the L1/L4 card chips, peek rows,
// the drill banner, and the eye tint. Kept in OrchestraUI (not App-iOS) so `swift test` exercises the
// membership + sort without an iOS Simulator. The SwiftUI view
// (`App-iOS/Views/NeedsYouTab.swift`) only renders these decisions.
//
// The old hand-rolled `NeedsYouQueue.reason` (permission/died/mergeStalled/humanTurn/
// context) is RETIRED: membership is now `ownAttention` verbatim, so a card appears IFF a human action is
// required. A bare idle `humanTurn` no longer qualifies unless it stalls past T.

/// One row of the Needs You queue: a card that needs the human, plus EVERY own-attention reason it holds
/// (most-urgent first — `ownAttention`'s order). The top signal drives the row's urgency, section, and
/// primary action; the rest render as extra labels.
public struct NeedsYouRow: Identifiable, Sendable, Equatable {
    public let task: Task
    /// Non-empty, most-urgent first (top = lowest `reason.rawValue`).
    public let signals: [AttentionSignal]
    public var id: UUID { task.id }
    public init(task: Task, signals: [AttentionSignal]) { self.task = task; self.signals = signals }

    /// The top (most hard-blocked) reason — drives the section bucket and the primary action.
    public var topReason: Attention.Reason { signals.first?.reason ?? .stalled }
}

public extension BoardStore {
    /// The Needs You attention queue computed off the live board — most-urgent-first. Every non-archived
    /// card whose `ownAttention` is non-empty, sorted by top reason priority, then longest-waiting (oldest
    /// `updatedAt`) within a reason. `now` is the render clock (injected in tests) — the stall row is
    /// time-derived, so a card can enter/leave the queue as the clock ticks with no daemon traffic.
    func needsYouRows(now: Date) -> [NeedsYouRow] {
        tasks.compactMap { t -> NeedsYouRow? in
            guard !t.archived else { return nil }
            let signals = ownAttention(of: t, now: now)
            guard !signals.isEmpty else { return nil }
            return NeedsYouRow(task: t, signals: signals)
        }
        .sorted {
            $0.topReason.rawValue != $1.topReason.rawValue
                ? $0.topReason.rawValue < $1.topReason.rawValue
                : $0.task.updatedAt < $1.task.updatedAt
        }
    }

}
