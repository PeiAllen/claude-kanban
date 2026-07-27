import SwiftUI
import OrchestraKit
import OrchestraUI

/// iOS **attached-agents** affordance — an inline accordion inside the target card (mirrors the desktop
/// inline redesign). A read-only sub-card (reviewer / fork inspector / browse-only borrow) is embedded
/// behind its target (`IOSBoardModel.isEmbedded`) and reached ONLY here: the target's `👁 N`/chevron
/// toggle expands the attached agents as rows *inside the card's frame* (`model.expandedRows(for:)`), and
/// tapping a row opens that card's detail. Desktop reveals on selection; iOS is tap-driven because
/// selecting a card pushes a full-screen detail (`IOSBoardModel.showsInlineRows`).

/// The `👁 N` count + liveness indicator, gaining a chevron so it doubles as the iOS **expand toggle**
/// (desktop's badge is glance-only because selection reveals; iOS has no on-board selection, so this is
/// the reveal trigger). `👁 N` tinted by roll-up liveness (green all-running / amber needs-attention).
/// Self-hides unless this card is a target. Rendered ABOVE the card's move-gesture overlay so its tap
/// wins (the overlay shadows nested taps) — idb-verified.
struct AttachedExpandToggle: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    let task: Task

    var body: some View {
        if let liveness = model.attachedLiveness(of: task) {
            let count = model.attachedAgents(of: task).count
            let expanded = model.isAttachedExpanded(task)
            let tint = theme.eyeTint(liveness)
            Button { model.toggleAttachedExpanded(task) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "eye").font(.system(size: 10, weight: .medium))
                    Text("\(count)").font(.system(.caption2, design: .monospaced).weight(.semibold))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Capsule().fill(theme.chip))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(count == 1 ? "1 attached agent" : "\(count) attached agents")
            .accessibilityHint(expanded ? "Collapse" : "Expand")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
        }
    }
}

/// The expanded accordion body: the target's attached agents (`model.expandedRows(for:)`) as compact rows,
/// styled to read as the BOTTOM of the target card — a squared-top / rounded-bottom fill matching the card,
/// drawn directly under it with no gap (one continuous frame, not a separate tile). Rendered as a sibling
/// BELOW the gestured header (never under the move-gesture overlay), so its row `Button`s receive taps.
struct AttachedAgentsRows: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    let target: Task

    private static let shape = UnevenRoundedRectangle(
        topLeadingRadius: 0, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 0,
        style: .continuous)

    var body: some View {
        let rows = model.expandedRows(for: target)
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, agent in
                if idx > 0 { Rectangle().fill(theme.hair).frame(height: 0.5).padding(.leading, 14) }
                AttachedAgentRow(agent: agent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.shape.fill(theme.card))
        .overlay(Self.shape.strokeBorder(theme.cardBorder, lineWidth: 1))
    }
}

/// The visual for one attached-agent row (status dot · shortId · title · ›), highlighted when it is the
/// current selection. Shared by the board row (a `Button` that selects) and the detail-header row (a
/// `NavigationLink` that pushes) so the two can't drift.
struct AttachedAgentRowLabel: View {
    @Environment(\.theme) private var theme: Theme
    let agent: Task
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(theme.statusColor(agent.phaseDisplay).dot).frame(width: 6, height: 6)
            Text(agent.shortId)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.text3)
            Text(agent.title)
                .font(.subheadline)
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(isSelected ? theme.accent.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
    }
}

/// The BOARD row: a `Button` that selects the agent. On the board that's correct — the Board tab's
/// `navigationDestination(item: selectedCardBinding)` observes `selectedId` and pushes the agent's detail
/// (nil→B, the proven `parentChip` path). NOTE: this selection path is Board-tab-specific — the
/// card-DETAIL list uses a `NavigationLink` instead (see `CardDetailHeader`), because that detail can be
/// presented from the Needs You tab too, whose stack does NOT observe `selectedId`.
struct AttachedAgentRow: View {
    @EnvironmentObject private var model: BoardModel
    let agent: Task

    var body: some View {
        Button { model.selectedId = agent.id } label: {
            AttachedAgentRowLabel(agent: agent, isSelected: model.selectedId == agent.id)
        }
        .buttonStyle(.plain)
    }
}

/// A **non-interactive** `👁 N` count + liveness indicator for the card-detail header (parity with the
/// desktop inspector's demoted badge). Self-hides unless the card is a target.
struct AttachedCountIndicator: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    let task: Task

    var body: some View {
        if let liveness = model.attachedLiveness(of: task) {
            let count = model.attachedAgents(of: task).count
            let tint = theme.eyeTint(liveness)
            HStack(spacing: 3) {
                Image(systemName: "eye").font(.system(size: 10, weight: .medium))
                Text("\(count)").font(.system(.caption2, design: .monospaced).weight(.semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(theme.chip))
            .accessibilityLabel(count == 1 ? "1 attached agent" : "\(count) attached agents")
        }
    }
}
