import Foundation
import OrchestraKit

// Pure, view-free logic for the Needs You attention queue (mobile design §6). Kept in OrchestraUI (not
// App-iOS) so `swift test` exercises the filtering / reason-derivation / sort without an iOS Simulator,
// and so the `send-keys` gate wrapper below can reach `BoardStore`'s module-internal `client`. The
// SwiftUI view (`App-iOS/Views/NeedsYouTab.swift`) only renders these decisions.

/// Why a card is in the Needs You queue. Each case maps to a *real* daemon signal — there is no
/// fabricated "blocked/error" bucket (design §6). The declaration order **is** the urgency order
/// (`rawValue` ascending = most-urgent-first): unblock actively-halted work (permission) first, then
/// recover dead cards, then reply to genuinely-done ones, then the soft context nudge last.
public enum AttentionReason: Int, CaseIterable, Sendable, Equatable, Hashable {
    case permission   // status == .waiting && waitReason == .permission — blocked on tool approval
    case died         // status == .dead — needs recovery
    case humanTurn    // status == .waiting && waitReason == .humanTurn — genuinely done, waiting on you
    case contextFull  // derived from ctxPct — near-full; may still be running

    /// The reason chip glyph (design §6: 🔐 / 💀 / 🙋 / ◔).
    public var emoji: String {
        switch self {
        case .permission:  return "🔐"
        case .died:        return "💀"
        case .humanTurn:   return "🙋"
        case .contextFull: return "◔"
        }
    }

    /// The reason chip label.
    public var label: String {
        switch self {
        case .permission:  return "Permission"
        case .died:        return "Died"
        case .humanTurn:   return "Needs you"
        case .contextFull: return "Context full"
        }
    }
}

/// One row of the Needs You queue: a card that needs the human, plus the single reason it surfaced for.
public struct AttentionItem: Identifiable, Sendable, Equatable {
    public let task: Task
    public let reason: AttentionReason
    public var id: UUID { task.id }
    public init(task: Task, reason: AttentionReason) { self.task = task; self.reason = reason }
}

/// The Needs You queue's pure model: which cards need the human, why, and in what order (design §6).
public enum NeedsYouQueue {
    /// `ctxPct` at/above which a card is flagged **◔ Context near-full**. 85 gives the human runway to
    /// act (wrap up / spawn a fresh card) before the 90%+ red zone where the model starts
    /// compacting/degrading — and keeps the queue quiet below it.
    public static let contextNearFullThreshold: Double = 85

    /// The single reason a card surfaces for, or `nil` if it needs nothing right now. Precedence
    /// (matches `AttentionReason`'s order): permission > died > humanTurn > context.
    ///
    /// **Background-waits are excluded by construction:** a card that yielded its turn to a background
    /// task (`run_in_background` shell, subagent, `/loop`/cron wake) stays `.running` with *no* wait —
    /// the adapters return no waiting report for it (see `ClaudeCodeAdapter` `stop` / `CodexAdapter`) —
    /// so it matches none of these and never appears. Context-full is gated to live (running/waiting)
    /// cards so a `.done` card is never dragged back in by a stale high `ctxPct`.
    public static func reason(for t: Task,
                              contextThreshold: Double = contextNearFullThreshold) -> AttentionReason? {
        if t.waitReason == .permission { return .permission }
        if t.phase.kind == .dead { return .died }
        if t.waitReason == .humanTurn { return .humanTurn }
        if case .live = t.phase, t.ctxPct >= contextThreshold { return .contextFull }
        return nil
    }

    /// Build the attention queue off the live board: every non-archived card that needs the human,
    /// **most-urgent-first** — sorted by reason priority, then longest-waiting (oldest `updatedAt`)
    /// within a reason.
    public static func build(from tasks: [Task],
                             contextThreshold: Double = contextNearFullThreshold) -> [AttentionItem] {
        tasks.compactMap { t -> AttentionItem? in
            guard !t.archived, let r = reason(for: t, contextThreshold: contextThreshold) else { return nil }
            return AttentionItem(task: t, reason: r)
        }
        .sorted {
            $0.reason.rawValue != $1.reason.rawValue
                ? $0.reason.rawValue < $1.reason.rawValue
                : $0.task.updatedAt < $1.task.updatedAt
        }
    }
}

public extension BoardStore {
    /// The Needs You attention queue (design §6) computed off the live board — most-urgent-first.
    var needsYouItems: [AttentionItem] { NeedsYouQueue.build(from: tasks) }

    /// **Approve** a card's pending permission prompt — the concrete v1 gate mechanism (design §6 +
    /// phone-terminal-ux "Gates"): a captured-prompt key-send delivered to the card's live `agent` pane
    /// over the shipped `send-keys` RPC. The chord is the card's *agent capability* (not a neutral-layer
    /// constant), so Codex's structured approval overrides Claude's keystrokes per-adapter.
    ///
    /// **State-guarded**: only fires while the card is still `.waiting/.permission`. Without the guard, a
    /// prompt the human just answered (from another surface, or a race) means the approve `Enter` lands in
    /// the now-live REPL and submits whatever sits in the composer. A just-answered card no longer waiting
    /// makes this a safe no-op.
    func approvePermission(_ id: UUID) async {
        guard let chord = permissionGateChord(id, \.approveChord) else { return }
        await sendKeysToAgent(id, chord)
    }

    /// **Deny** a card's pending permission prompt (the agent's deny chord). Same state guard as
    /// `approvePermission` — never sends into a card that has left `.waiting/.permission`.
    func denyPermission(_ id: UUID) async {
        guard let chord = permissionGateChord(id, \.denyChord) else { return }
        await sendKeysToAgent(id, chord)
    }

    /// The approve/deny chord for a card that is STILL blocked on a permission prompt, or `nil` if the
    /// card is unknown, no longer `.waiting/.permission`, or its agent has no send-keys gate (empty chord
    /// → structured-approval agent). Centralizes the state guard + per-capability chord lookup for both
    /// gate verbs. Internal (not private) so the guard + per-adapter routing is unit-testable.
    func permissionGateChord(_ id: UUID,
                             _ key: KeyPath<AgentCapabilities, [KeyToken]>) -> [KeyToken]? {
        guard let t = tasks.first(where: { $0.id == id }),
              t.waitReason == .permission,
              let capabilities = capabilities(for: t.agentId) else { return nil }
        let chord = capabilities[keyPath: key]
        return chord.isEmpty ? nil : chord
    }

}
