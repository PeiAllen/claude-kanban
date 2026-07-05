import Foundation
import OrchestraKit

// Pure, view-free logic for the Needs You attention queue (mobile design §6). Kept in OrchestraUI (not
// App-iOS) so `swift test` exercises the filtering / reason-derivation / sort without an iOS Simulator,
// and so the `send-keys` gate wrapper below can reach `BoardModel`'s module-internal `client`. The
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
        if t.status == .waiting, t.waitReason == .permission { return .permission }
        if t.status == .dead { return .died }
        if t.status == .waiting, t.waitReason == .humanTurn { return .humanTurn }
        if (t.status == .running || t.status == .waiting), t.ctxPct >= contextThreshold { return .contextFull }
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

    // MARK: - Permission gate key chords (the v1 send-keys mechanism)

    /// **Approve** a permission prompt: `Enter` accepts the prompt's default option. On a fresh,
    /// human-untouched Claude permission prompt that default is "Yes" (option 1 is pre-highlighted), so
    /// one keystroke approves. See the "Gates" discussion in the phone-agent-terminal-ux design.
    public static let approveChord: [KeyToken] = [.named(.enter)]

    /// **Deny** a permission prompt: `Esc` cancels it (Claude's option 3, "No, and tell Claude…").
    public static let denyChord: [KeyToken] = [.named(.esc)]
}

public extension BoardModel {
    /// The Needs You attention queue (design §6) computed off the live board — most-urgent-first.
    var needsYouItems: [AttentionItem] { NeedsYouQueue.build(from: tasks) }

    /// **Approve** a card's pending permission prompt — the concrete v1 gate mechanism (design §6 +
    /// phone-terminal-ux "Gates"): a captured-prompt key-send delivered to the card's live `agent` pane
    /// over the shipped `send-keys` RPC. Provider-neutral here; C1 refines Codex's structured
    /// `PermissionRequest` path onto the same `waitReason == .permission` surface.
    func approvePermission(_ id: UUID) async { await sendAgentKeys(id, NeedsYouQueue.approveChord) }

    /// **Deny** a card's pending permission prompt (the `send-keys` deny chord). See `approvePermission`.
    func denyPermission(_ id: UUID) async { await sendAgentKeys(id, NeedsYouQueue.denyChord) }

    /// Deliver a constrained key chord to a card's `agent` pane. Thin wrapper over the shipped
    /// `send-keys` RPC (reaching the module-internal `client`), exposed so the iOS Needs You queue can
    /// drive gates without a live terminal attach. Distinct from `send` (which queues to the inbox).
    func sendAgentKeys(_ id: UUID, _ chord: [KeyToken]) async {
        _ = try? await client.sendKeys(ref: id.uuidString, chord)
    }
}
