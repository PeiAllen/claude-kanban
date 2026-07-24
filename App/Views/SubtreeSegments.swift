import SwiftUI
import OrchestraUI
import OrchestraCore
import OrchestraKit

/// The L4 subtree line (slice 2b): a card's subordinates summarised as a row of stage-coloured segments
/// — one per LIVE lineage child, coloured by its column (plan=purple, impl=blue, review=teal) — followed
/// by the attached-agents eye. This component ends with a trailing `Spacer` reserving the right edge for
/// the slice-3b descendants-attention chip. `CardView.subtreeLine` prepends the `drill ›` tile at the
/// LEADING edge (external to this view), so the trailing edge stays clear for that attention chip.
///
/// Merged (green) and not-started (dashed) slots come from the daemon's `mergedChildren`/`plannedChildren`
/// counters on `TreeStat`: a positive `mergedChildren` prepends that many green slots, a positive
/// `plannedChildren` pads dashed placeholders up to the planned total. When neither is set (both 0) the
/// bar falls back to the live-children-only mode and simply grows as children spawn.
struct SubtreeSegments: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let root: OrchestraCore.Task

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
            // Trailing edge reserved for the slice-3b descendants-attention chip. The drill tile leads
            // the bar (prepended by `CardView.subtreeLine`), so this right edge stays clear for it.
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
    @ViewBuilder private func eye(compact: Bool) -> some View {
        if let liveness = model.attachedLiveness(of: root) {
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
