import SwiftUI
import OrchestraKit
import OrchestraUI

/// iOS **peek** affordance (BT slice 5) — the tap-toggled inline accordion inside a card, generalized from
/// the shipped attached-agents redesign to ALL subordinates (lineage children first, then attached
/// reviewers — `model.expandedRows(for:)` = `subordinates(of:)`). A non-root descendant is embedded behind
/// its root (`IOSBoardModel.isEmbedded`) and reached ONLY here: the card's `PeekToggle` reveals its direct
/// subordinates as rows *inside the card's frame*, and tapping a row opens that card's detail. Desktop
/// reveals on selection; iOS is tap-driven because selecting a card pushes a full-screen detail.

/// The peek disclosure toggle: an eye + count (tinted by the fold-derived `attentionLiveness`) when the
/// card has attached reviewers, else a subtree glyph + count; plus a chevron. Rides ABOVE the card's
/// move-gesture overlay (top-trailing) so its tap wins. Visible iff the card has ≥1 subordinate — NOT
/// gated on `attachedLiveness`, so a pure-lineage-child card (and a nested reviewer whose own
/// `attachedAgents` is empty) still gets a reveal.
struct PeekToggle: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    let task: Task

    var body: some View {
        let subs = model.subordinates(of: task)
        if !subs.isEmpty {
            let attached = model.attachedAgents(of: task)
            let expanded = model.isPeekExpanded(task)
            // Fold-derived tint (retires the phase-only `attachedLiveness` at this iOS site): amber when a
            // reviewer needs the human, green while active, grey when all concluded.
            let tint = attached.isEmpty ? theme.text2 : theme.eyeTint(model.attentionLiveness(of: task) ?? .idle)
            Button { model.togglePeek(task) } label: {
                HStack(spacing: 3) {
                    Image(systemName: attached.isEmpty ? "arrow.triangle.branch" : "eye")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(subs.count)").font(.system(.caption2, design: .monospaced).weight(.semibold))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Capsule().fill(theme.chip))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(subs.count == 1 ? "1 subordinate" : "\(subs.count) subordinates")
            .accessibilityHint(expanded ? "Collapse" : "Expand")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
        }
    }
}

/// The expanded accordion body: the target's direct subordinates (`model.expandedRows(for:)`) as compact
/// peek rows, styled to read as the BOTTOM of the target card (squared-top / rounded-bottom fill, drawn
/// directly under it — one continuous frame). Rendered as a sibling BELOW the gestured header (never under
/// the move-gesture overlay), so its row `Button`s receive taps. `now` ticks the rows' own-attention labels.
struct PeekRows: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    let target: Task
    var now: Date = .distantPast

    private static let shape = UnevenRoundedRectangle(
        topLeadingRadius: 0, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 0,
        style: .continuous)

    var body: some View {
        let rows = model.expandedRows(for: target)
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, sub in
                if idx > 0 { Rectangle().fill(theme.hair).frame(height: 0.5).padding(.leading, 14) }
                PeekRow(task: sub, now: now)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.shape.fill(theme.card))
        .overlay(Self.shape.strokeBorder(theme.cardBorder, lineWidth: 1))
    }
}

/// The visual for one peek row (design §"Peek rows"): dot (the child's OWN phase) · shortId · title ·
/// desc/note (dim context, lowest precedence, truncates first) · action slot (own-attention label if any,
/// else compact diff) · chip slot (lineage child → a stage-tinted column chip; attached reviewer → a
/// liveness-tinted eye; columnless → "freeform"). Shared by the board row (a `Button` that selects) and the
/// detail-header row (a `NavigationLink` that pushes) so the two can't drift.
struct PeekRowLabel: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    let task: Task
    var now: Date = .distantPast
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(theme.statusColor(task.phaseDisplay).dot).frame(width: 6, height: 6)
            Text(task.shortId)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.text3)
            Text(task.title)
                .font(.subheadline)
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .layoutPriority(1)          // title outranks the context zone, which truncates first
            // Dim context zone (design §"Peek rows": desc/note, lowest precedence). Gives a quiet
            // subordinate its hierarchy/work context; `layoutPriority` above lets it yield space to the title.
            if !task.cardLine.isEmpty {
                Text(task.cardLine)
                    .font(.caption2)
                    .foregroundStyle(theme.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            actionSlot
            chipSlot
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(isSelected ? theme.accent.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
    }

    /// Own-attention label (solid amber) if the child needs you, else its compact diffstat.
    @ViewBuilder private var actionSlot: some View {
        if let text = Attention.chipText(model.ownAttention(of: task, now: now)) {
            Text(text)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(theme.attentionChipText)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(theme.attentionChipFill))
        } else if let s = task.diffStat, s.filesChanged > 0 {
            HStack(spacing: 4) {
                Text("+\(s.insertions)").foregroundStyle(theme.green.text)
                Text("−\(s.deletions)").foregroundStyle(theme.red.text)
            }
            .font(.system(.caption2, design: .monospaced).weight(.medium))
        }
    }

    /// Attached reviewer → liveness-tinted eye; lineage child → stage-tinted column chip; columnless →
    /// "freeform".
    @ViewBuilder private var chipSlot: some View {
        if model.isAttached(task) {
            Image(systemName: "eye").font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.eyeTint(model.attentionTier(of: task)))
        } else if task.origin == .worktree {
            Text(task.column.displayName)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(theme.stageColor(task.column).text)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(theme.stageColor(task.column).tint))
        } else {
            Text("freeform").font(.caption2).foregroundStyle(theme.text3)
        }
    }
}

/// The BOARD peek row: a `Button` that selects the subordinate. On the board that's correct — the Board
/// tab's `navigationDestination(item: selectedCardBinding)` observes `selectedId` and pushes the card's
/// detail. NOTE: this selection path is Board-tab-specific — the card-DETAIL list uses a `NavigationLink`
/// instead (see `CardDetailHeader`), because that detail can be presented from the Needs You tab too,
/// whose stack does NOT observe `selectedId`.
struct PeekRow: View {
    @EnvironmentObject private var model: BoardModel
    let task: Task
    var now: Date = .distantPast

    var body: some View {
        Button { model.selectedId = task.id } label: {
            PeekRowLabel(task: task, now: now, isSelected: model.selectedId == task.id)
        }
        .buttonStyle(.plain)
    }
}
