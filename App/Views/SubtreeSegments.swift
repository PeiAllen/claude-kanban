import SwiftUI
import OrchestraUI
import OrchestraCore
import OrchestraKit

/// The L4 subtree line: a card's subordinates summarised as a row of stage-coloured segments — one per
/// LIVE lineage child, coloured by its column (plan=purple, impl=blue, review=teal) — then the
/// attached-agents eye, then the descendants-only attention chip pinned to the trailing edge.
/// `CardView.subtreeLine` prepends the `drill ›` tile at the LEADING edge (external to this view), which
/// is what keeps the trailing edge clear for that chip.
///
/// Attention splits by SUBJECT across the card: the card's own reasons live on L1, and everything
/// below it aggregates here. So this chip counts DESCENDANTS only (self excluded) — "2 need you" means
/// two cards under this one, never this one — and position alone tells you whether to look at the card
/// or into its tree.
///
/// Merged (green) and not-started (dashed) slots come from the daemon's `mergedChildren`/`plannedChildren`
/// counters on `TreeStat`: a positive `mergedChildren` prepends that many green slots, a positive
/// `plannedChildren` pads dashed placeholders up to the planned total. When neither is set (both 0) the
/// bar falls back to the live-children-only mode and simply grows as children spawn.
struct SubtreeSegments: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let root: OrchestraCore.Task
    /// From the card-level clock — the subtree count is time-derived (a descendant can cross the stall
    /// threshold with no daemon traffic at all), so this line must tick with L1 rather than wait for a
    /// broadcast.
    let now: Date
    /// Whether to draw the descendants-only rollup chip. True on a board card. FALSE in the drill
    /// banner: there the descendants ARE the columns below, each already showing its own chip, so a
    /// rollup would count the very cards you are looking at a second time.
    var showsSubtreeAttention: Bool = true

    private var liveChildren: [OrchestraCore.Task] {
        model.subordinates(of: root).filter { $0.access != .readOnly }
    }

    var body: some View {
        // The daemon's child-progress counters (merged/planned) now exist on TreeStat: merged prepends
        // green slots, a set plannedChildren pads dashed placeholders. 0 means "unset" → nil, so the bar
        // falls back to the live-children-only mode (grows as children spawn) rather than padding to 0.
        let ts = root.treeStat
        let merged = (ts?.mergedChildren).flatMap { $0 > 0 ? $0 : nil }
        let planned = (ts?.plannedChildren).flatMap { $0 > 0 ? $0 : nil }
        let styles = StageSegment.segments(liveChildren: liveChildren, merged: merged, planned: planned)
        HStack(spacing: 8) {
            if !styles.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(styles.enumerated()), id: \.offset) { _, s in segment(s) }
                }
            }
            eye(compact: !styles.isEmpty)
            Spacer(minLength: 0)
            // The trailing edge the drill tile's leading placement keeps clear.
            if showsSubtreeAttention,
               let text = Attention.subtreeChipText(model.subtreeAttention(of: root, now: now)) {
                AttentionChip(text: text)
                    .help("\(text) below this card — select it to see which")
            }
        }
    }

    @ViewBuilder private func segment(_ s: SegStyle) -> some View {
        switch s {
        case .merged:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(theme.green.dot.opacity(0.75)).frame(width: 7, height: 7)
        case .stage(let col):
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(theme.stageColor(col).dot.opacity(0.85)).frame(width: 7, height: 7)
        case .todo:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(theme.text3.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2]))
                .frame(width: 7, height: 7)
        }
    }

    /// The eye: labelled ("👁 N attached") when it's ALONE on the line so the section reads intentional;
    /// compact ("👁N") alongside the lineage segments. Absent when the card has no attached agents.
    ///
    /// Its tint is the ROLL-UP of the same attention fold the chip beside it counts (`attentionLiveness`,
    /// not the old phase-only mapping), so an amber eye and an amber chip are one fact. No `now`: an
    /// attached agent never stalls, so the tiers are time-independent.
    @ViewBuilder private func eye(compact: Bool) -> some View {
        if let liveness = model.attentionLiveness(of: root) {
            let count = model.attachedAgents(of: root).count
            let tint = theme.eyeTint(liveness)
            HStack(spacing: 3) {
                Image(systemName: "eye").font(F.ui(8.5))
                Text(compact ? "\(count)" : "\(count) attached").font(F.mono(10, .medium))
            }
            .foregroundStyle(tint)
            .help(count == 1 ? "1 attached agent — select this card to expand it"
                             : "\(count) attached agents — select this card to expand them")
        }
    }
}
