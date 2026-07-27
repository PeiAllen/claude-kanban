import SwiftUI
import OrchestraKit
import OrchestraUI

/// The drill chrome (BT slice 5), shown above the pager when the board is scoped to a root's subtree
/// (`model.drillScope != nil`): a breadcrumb + a banner. The pager below is the root's descendants, scoped
/// by `visibleTasks`/`cards(in:)` (which read the overridden `isEmbedded`), so the banner deliberately
/// carries NO subtree rollup (the descendants report their own state). It is the root's own status strip +
/// identity laid flat — the phone reinterpretation of the desktop `DrillHeader`.
struct DrillHeaderIOS: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        if let root = model.drillScopeCard {
            // One clock for the WHOLE header: the hosted reviewer rows carry time-derived attention labels
            // and the banner's subtree line a time-derived count, so wrapping only the banner would leave
            // those frozen until the next daemon broadcast.
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                VStack(alignment: .leading, spacing: 8) {
                    breadcrumb
                    banner(root, now: ctx.date)
                    // The root's OWN attached reviewers are embedded in its drill (the root is this banner,
                    // not a peekable card), so host them here as tappable rows — otherwise they'd be
                    // unreachable in their target's drill. Its lineage children are the pager columns below.
                    let rows = model.drillHostedRows()
                    if !rows.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(rows) { PeekRow(task: $0, now: ctx.date) }
                        }
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 1))
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
        }
    }

    /// `‹ All projects / <scopePath>` — each ancestor a tap that re-scopes there; the current scope is the
    /// bold tail. Recursive drills climb through every ancestor in `scopePath`.
    private var breadcrumb: some View {
        HStack(spacing: 5) {
            Button { model.setDrillScope(nil) } label: {
                Text("‹ All projects").font(.footnote).foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            ForEach(Array(model.scopePath.enumerated()), id: \.element.id) { idx, node in
                Text("/").font(.footnote).foregroundStyle(theme.text3)
                if idx == model.scopePath.count - 1 {
                    Text(node.title).font(.footnote.weight(.semibold)).foregroundStyle(theme.text).lineLimit(1)
                } else {
                    Button { model.setDrillScope(node.id) } label: {
                        Text(node.title).font(.footnote).foregroundStyle(theme.accent).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The banner IS the root card, laid flat: status pill + title + note/desc + `#id` + the root's OWN
    /// attention chip + its live-children bar (rollup chip explicitly OFF — the descendants are the pager
    /// below, each already carrying its own chip). Tapping it selects the root and pushes its detail.
    private func banner(_ root: Task, now: Date) -> some View {
        let sem = theme.statusColor(root.phaseDisplay)
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(sem.dot).frame(width: 7, height: 7)
                Text("\(theme.statusLabel(root.phaseDisplay)) · \(relativeAge(root.phaseChangedAt))")
                    .font(.caption2.weight(.semibold)).foregroundStyle(sem.text)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(sem.tint))

            Text(root.title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text).lineLimit(1)
            if !root.cardLine.isEmpty {
                Text(root.cardLine).font(.caption2).foregroundStyle(theme.text3).lineLimit(1)
            }
            // The root's OWN attention only — its subtree IS the pager below, so a rollup would double-count.
            if let text = Attention.chipText(model.ownAttention(of: root, now: now)) {
                AttentionChipIOS(text: text)
            }
            Spacer(minLength: 8)
            SubtreeLineIOS(task: root, now: now, showsSubtreeAttention: false)
                .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { model.selectedId = root.id }
        .accessibilityHint("Open this root's card")
    }
}
