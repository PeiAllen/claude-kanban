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

    /// Uniform compact row height. Fixing it lets the row use a `GeometryReader` for width without the
    /// reader's fill-both-axes behaviour blowing the row up — and one fixed height IS the spec ("row
    /// height uniform"). Sized to the tallest zone (the title at `F.ui(11.5)`), a hair over its line box.
    private let rowH: CGFloat = 18

    /// The squish ladder — the loss order as the row narrows, matching the peek-row spec's precedence:
    /// desc/note drops first, then the stage chip collapses word→letter, then the diffstat sheds its file
    /// count (the lowest-value part — `+N −M` answers "how big"), then the whole diffstat drops. The title
    /// (kept to its first few words) and the chip itself are never lost. `w` is the row's measured content
    /// width; the real board floor is ~150pt, so a direct child keeps title+letter.
    ///
    /// SEAM for slice 3b (`feat/attention-system`): the own-attention **alert** lands in the action slot
    /// AHEAD of the diffstat, at the TOP of the keep-order — shown at every width, even before the title's
    /// words. 3b derives it from the attention registry (not an ad-hoc phase check), so it is deliberately
    /// NOT built here; when it arrives it slots in at the `// alert` mark below. It MUST be intrinsically
    /// sized (`.fixedSize()` + `.lineLimit(1)`, same discipline as the diffstat/chip) — a flexible alert
    /// Text would wrap into a tall pill (the very bug this file fixes) or, if high-priority, push the title out.
    var body: some View {
        Button { model.selectAndEnterTerminal(task.id) } label: {
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 7) {
                    Circle().fill(theme.statusColor(task.phaseDisplay).dot).frame(width: 6, height: 6)   // dot
                    Text(task.title).font(F.ui(11.5)).foregroundColor(theme.text)
                        .lineLimit(1).layoutPriority(1)                                                   // title — keeps its first words
                    if w >= 280, !task.cardLine.isEmpty {
                        Text(task.cardLine).font(F.ui(10.5)).foregroundColor(theme.text3).lineLimit(1)    // desc/note (drops first)
                    }
                    Spacer(minLength: 6)
                    // alert — slice 3b's own-attention label goes HERE, ahead of the diffstat, highest keep-priority.
                    if w >= 170, let stat = task.diffStat, stat.filesChanged > 0 {
                        // `.fixedSize()` so a starved diffstat never wraps its `+N −M` digits char-by-char
                        // into a tall pill (the peek-row bug). It drops out whole below 170 rather than
                        // shrink; from 240 down it first sheds the file count (`showFiles`) so the title's
                        // words survive the tightest pinch (wide diff + word chip) instead of crushing to "…".
                        DiffStatNumbers(stat: stat, showFiles: w >= 240).fixedSize()                     // action slot: compact diff
                    }
                    chip(word: w >= 200)                                                                  // chip slot: word, or a single letter when tight
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)                    // fill + vertically centre in the fixed row
            }
            .frame(height: rowH)
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
    @ViewBuilder private func chip(word: Bool) -> some View {
        if isAttached {
            // Liveness-tinted eye — the same three-tier mapping as the L4 roll-up eye, for this one agent:
            // green (active) · grey (finished its turn) · amber (blocked on a permission prompt / dead).
            Image(systemName: "eye").font(F.ui(9))
                .foregroundColor(theme.eyeTint(BoardStore.AttachedLiveness(phase: task.phase)))
        } else {
            // Full stage word when the row has room (`word`), else a single-letter pill — the letter frees
            // ~30pt so the title keeps its first few words instead of collapsing to "…". The form is chosen
            // from the MEASURED row width (not `ViewThatFits`, which the greedy `.layoutPriority(1)` title
            // starves to always pick the letter). `.lineLimit(1).fixedSize()` keeps it one horizontal line.
            stagePill(word ? stageLabel : stageLetter, theme.stageColor(task.column))
        }
    }
    private func stagePill(_ text: String, _ c: SemColor) -> some View {
        Text(text).font(F.ui(9, .medium)).tracking(0.3)
            .foregroundColor(c.text)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(c.tint))
    }
    private var stageLabel: String {
        switch task.column { case .plan: return "PLAN"; case .impl: return "IMPL"; case .review: return "REVIEW" }
    }
    private var stageLetter: String {
        switch task.column { case .plan: return "P"; case .impl: return "I"; case .review: return "R" }
    }
}
