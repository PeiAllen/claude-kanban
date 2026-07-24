import SwiftUI
import OrchestraUI
import OrchestraCore
import OrchestraKit

/// One compact PEEK ROW for a subordinate, rendered INSIDE its root card while the root (or one of its
/// descendants) is selected. Five zones (actionability-first): the child's OWN status **dot** ·
/// **title** · **desc/note** (dim, lowest precedence, truncates first) · **action slot** (its own
/// attention label if it needs you, else a compact diffstat) · **chip slot** — a stage-tinted column
/// chip for a lineage child (plan/impl/review), or the **eye** for an attached read-only reviewer.
/// Indented by `depth` for a one-level-deeper reveal. Clicking selects the child, opening its inspector /
/// terminal like any card; highlighted when it is the current selection, so Esc out of its terminal lands
/// back on the visible row rather than into the void.
struct PeekRow: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: OrchestraCore.Task
    var depth: Int = 0
    /// From the enclosing card's (or drill header's) clock — the action label can be a stall, which
    /// crosses its threshold on time alone.
    var now: Date = .now

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
                actionSlot                                                                            // action slot
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

    /// What this row wants you to DO: its own attention label when it needs you, else how big its
    /// change is. Attention outranks the diffstat because the row's job is actionability — "permission"
    /// is what you act on; "+412 −96" is context you read afterwards.
    @ViewBuilder private var actionSlot: some View {
        if let text = Attention.chipText(model.ownAttention(of: task, now: now)) {
            AttentionChip(text: text)
        } else if let stat = task.diffStat, stat.filesChanged > 0 {
            DiffStatNumbers(stat: stat)
        }
    }

    /// Attached reviewer → the eye (read-only, no workflow column). Lineage child → a stage-tinted
    /// column chip. The stage hue matches the L4 subtree segments (`theme.stageColor`).
    @ViewBuilder private var chip: some View {
        if isAttached {
            // PER-AGENT tier for this one row (never the target roll-up, which would be nil here — a
            // leaf reviewer has no attached agents of its own and the eye would vanish). Derived from
            // the same attention fold as the chip: green (active) · grey (concluded) · amber (needs you).
            Image(systemName: "eye").font(F.ui(9))
                .foregroundColor(theme.eyeTint(model.attentionTier(of: task)))
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
