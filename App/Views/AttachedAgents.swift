import SwiftUI
import OrchestraUI
import OrchestraCore
import OrchestraKit

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
            // Liveness-tinted eye — the same three-tier mapping as the L4 roll-up eye, for this one agent:
            // green (active) · grey (finished its turn) · amber (blocked on a permission prompt / dead).
            Image(systemName: "eye").font(F.ui(9))
                .foregroundColor(theme.eyeTint(BoardStore.AttachedLiveness(phase: task.phase)))
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
