import SwiftUI
import OrchestraUI
import OrchestraCore
import OrchestraKit

/// A glance indicator on a target card for its **attached agents** — the read-only sub-cards
/// (reviewers / fork inspectors / browse-only borrows) embedded behind it. `👁 N`, tinted by the
/// roll-up liveness of those agents (green = all running/being-born, amber = one needs the human or
/// died). It is purely informational: the attached agents are reached by **selecting the target**,
/// which expands them as inline rows inside the card (see `AttachedAgentRow`) — no popover. It is the
/// card's whole subtree line (L4), so the count is spelled out ("👁 2 attached"): alone on its own
/// line, a bare glyph and a digit would read as debris rather than a summary of what hangs off the card.
struct AttachedAgentsBadge: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: OrchestraCore.Task

    var body: some View {
        // Hidden unless this card actually has attached agents (nil liveness ⇒ none).
        if let liveness = model.attachedLiveness(of: task) {
            let count = model.attachedAgents(of: task).count
            let tint = liveness == .allRunning ? theme.green.text : theme.amber.text
            HStack(spacing: 3) {
                Image(systemName: "eye").font(F.ui(8.5))
                Text("\(count) attached").font(F.mono(10, .medium))
            }
            .foregroundStyle(tint)
            .help(count == 1 ? "1 attached agent — select this card to expand it"
                             : "\(count) attached agents — select this card to expand them")
        }
    }
}

/// One compact PEEK ROW for a subordinate, rendered INSIDE its root card while the root (or one of its
/// descendants) is selected. Five zones (slice 2b, actionability-first): the child's OWN status **dot** ·
/// **title** · **desc/note** (dim, lowest precedence, truncates first) · **action slot** (a compact
/// diffstat for now; own-attention label is slice 3b) · **chip slot** — a stage-tinted column chip for a
/// lineage child (plan/impl/review), or the **eye** for an attached read-only reviewer (no column).
/// Indented by `depth` for a one-level-deeper reveal. Clicking selects the child, opening its inspector /
/// terminal like any card; highlighted when it is the current selection, so Esc out of its terminal lands
/// back on the visible row rather than into the void.
struct PeekRow: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: OrchestraCore.Task
    var depth: Int = 0

    private var isSelected: Bool { model.selectedId == task.id }
    private var isAttached: Bool { task.access == .readOnly }

    var body: some View {
        Button { model.selectAndEnterTerminal(task.id) } label: {
            HStack(spacing: 7) {
                Circle().fill(theme.statusColor(task.phaseDisplay).dot).frame(width: 6, height: 6)   // dot
                Text(task.title).font(F.ui(11.5)).foregroundColor(theme.text)
                    .lineLimit(1).layoutPriority(1)                                                   // title
                if !task.cardLine.isEmpty {
                    Text(task.cardLine).font(F.ui(10.5)).foregroundColor(theme.text3).lineLimit(1)    // desc/note (truncates first)
                }
                Spacer(minLength: 6)
                if let stat = task.diffStat, stat.filesChanged > 0 {
                    DiffStatNumbers(stat: stat)                                                       // action slot: compact diff
                }
                chip                                                                                  // chip slot
            }
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? theme.accent.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // During a `/` search this row is revealed in place; dim it unless it's one of the matches.
        .opacity(model.searchActive && !model.isSearchMatch(task) ? 0.32 : 1)
    }

    /// Attached reviewer → the eye (read-only, no workflow column). Lineage child → a stage-tinted
    /// column chip. The stage hue matches the L4 subtree segments (`theme.stageColor`).
    @ViewBuilder private var chip: some View {
        if isAttached {
            Image(systemName: "eye").font(F.ui(9)).foregroundColor(theme.green.text)
        } else {
            let c = theme.stageColor(task.column)
            Text(stageLabel).font(F.ui(9, .medium)).tracking(0.3)
                .foregroundColor(c.text)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(c.tint))
        }
    }
    private var stageLabel: String {
        switch task.column { case .plan: return "PLAN"; case .impl: return "IMPL"; case .review: return "REVIEW" }
    }
}
