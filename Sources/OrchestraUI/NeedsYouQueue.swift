import Foundation
import OrchestraKit

// Pure, view-free logic for the Needs You attention queue (mobile design §6), re-homed (BT slice 5) onto
// the 3b attention fold — the ONE definition of "needs you" shared with the L1/L4 card chips, peek rows,
// the drill banner, and the eye tint. Kept in OrchestraUI (not App-iOS) so `swift test` exercises the
// membership + sort without an iOS Simulator, and so the `send-keys` gate wrapper below can reach
// `BoardStore`'s module-internal `client`. The SwiftUI view (`App-iOS/Views/NeedsYouTab.swift`) only
// renders these decisions.
//
// The OLD hand-rolled `NeedsYouQueue.reason` (permission/died/deliveryStuck/mergeStalled/humanTurn/
// context) is RETIRED: membership is now `ownAttention` verbatim, so a card appears IFF a human action is
// required. Consequences of the single contract: a bare idle `humanTurn` no longer qualifies unless it
// stalls past T, and the old 📪 delivery-stuck immediacy is gone (a stuck card surfaces only if it
// independently stalls, never while still `.running`).

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

    /// **Approve** a card's pending permission prompt — the concrete v1 gate mechanism (design §6 +
    /// phone-terminal-ux "Gates"): a captured-prompt key-send delivered to the card's live `agent` pane
    /// over the shipped `send-keys` RPC. The chord is the card's *agent capability* (not a neutral-layer
    /// constant), so Codex's structured approval overrides Claude's keystrokes per-adapter.
    ///
    /// **State-guarded**: only fires while the card still has a provider permission need. Without the guard, a
    /// prompt the human just answered (from another surface, or a race) means the approve `Enter` lands in
    /// the now-live REPL and submits whatever sits in the composer. A just-answered Card makes this a safe
    /// no-op because the provider permission need has disappeared.
    func approvePermission(_ id: UUID) async {
        guard let chord = permissionGateChord(id, \.approveChord) else { return }
        await sendKeysToAgent(id, chord)
    }

    /// **Deny** a card's pending permission prompt (the agent's deny chord). Same state guard as
    /// `approvePermission` — never sends into a Card whose provider permission need has cleared.
    func denyPermission(_ id: UUID) async {
        guard let chord = permissionGateChord(id, \.denyChord) else { return }
        await sendKeysToAgent(id, chord)
    }

    /// The approve/deny chord for a card that is STILL blocked on a permission prompt, or `nil` if the
    /// card is unknown, no longer has a provider permission need, or its agent has no send-keys gate (empty chord
    /// → structured-approval agent). Centralizes the state guard + per-capability chord lookup for both
    /// gate verbs. Internal (not private) so the guard + per-adapter routing is unit-testable.
    func permissionGateChord(_ id: UUID,
                             _ key: KeyPath<AgentCapabilities, [KeyToken]>) -> [KeyToken]? {
        guard let t = tasks.first(where: { $0.id == id }),
              t.agentState?.humanNeed == .permission,
              let capabilities = capabilities(for: t.agentId) else { return nil }
        let chord = capabilities[keyPath: key]
        return chord.isEmpty ? nil : chord
    }
}
