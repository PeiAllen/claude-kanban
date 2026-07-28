import SwiftUI
import OrchestraKit
import OrchestraUI

/// The L4 **subtree line** on an iOS card (BT slice 5) — the phone reinterpretation of the desktop
/// `SubtreeSegments`. A card's subordinates summarised as stage-coloured segments (one per LIVE lineage
/// child, coloured by its column; plus the merged-green / dashed-planned slots the daemon `TreeStat`
/// counters carry), then the attached-agents eye, then the DESCENDANTS-ONLY attention chip trailing.
/// iOS renders its own views; the DATA all comes from base-store helpers (`StageSegment.segments`,
/// `attachedAgents`, `attentionLiveness`, `subtreeAttention`) so the phone and desktop can't drift.
///
/// Attention splits by SUBJECT across the card: the card's own reasons live on L1, everything below it
/// aggregates here — so this chip counts DESCENDANTS only (self excluded).
struct SubtreeLineIOS: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    let task: Task
    /// From the card-level clock — the subtree count is time-derived (a descendant can cross the stall
    /// threshold with no daemon traffic), so this line ticks with L1 rather than waiting for a broadcast.
    var now: Date = .distantPast
    /// FALSE in the drill banner: there the descendants ARE the columns below, each already showing its
    /// own chip, so a rollup would count the very cards you are looking at a second time.
    var showsSubtreeAttention: Bool = true

    private var liveChildren: [Task] {
        model.subordinates(of: task).filter { $0.access != .readOnly }
    }

    var body: some View {
        let ts = task.treeStat
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
            if showsSubtreeAttention,
               let text = Attention.subtreeChipText(model.subtreeAttention(of: task, now: now)) {
                AttentionChipIOS(text: text)
                    .accessibilityLabel("\(text) below this card")
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

    /// The eye: labelled ("👁 N attached") when ALONE on the line so the section reads intentional;
    /// compact ("👁N") alongside the lineage segments. Absent when the card has no attached agents. Tinted
    /// by the fold-derived `attentionLiveness` (retiring the phase-only `attachedLiveness`) so an amber eye
    /// and an amber chip are one fact.
    @ViewBuilder private func eye(compact: Bool) -> some View {
        let agents = model.attachedAgents(of: task)
        if !agents.isEmpty, let liveness = model.attentionLiveness(of: task) {
            HStack(spacing: 3) {
                Image(systemName: "eye").font(.system(size: 9, weight: .medium))
                Text(compact ? "\(agents.count)" : "\(agents.count) attached")
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .chipText()
            }
            .foregroundStyle(theme.eyeTint(liveness))
        }
    }
}
