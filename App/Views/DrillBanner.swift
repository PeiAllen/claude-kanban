import SwiftUI
import OrchestraUI
import OrchestraCore
import OrchestraKit

/// The drill chrome (slice 2b), shown above the columns when the board is scoped to a root's subtree
/// (`model.drillScope != nil`): a breadcrumb and a banner. The board below is the root's descendants,
/// scoped by `visibleTasks` — so the banner deliberately carries NO subtree rollup (the descendants
/// report their own state). It is the root's own status strip + identity laid flat.
struct DrillHeader: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    var body: some View {
        if let root = model.drillScopeCard {
            // One clock for the WHOLE header, not just the banner: the hosted rows below carry their own
            // time-derived attention labels, and the banner's `SubtreeSegments` a time-derived count, so
            // wrapping only `banner(root)` would leave those frozen until the next daemon broadcast.
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                VStack(alignment: .leading, spacing: 8) {
                    breadcrumb
                    banner(root, now: ctx.date)
                    // The root's OWN attached reviewers are embedded in its drill (the root is this
                    // banner, not a peekable card), so host them here as interactive rows — otherwise
                    // they'd be unreachable in their target's drill. Its lineage children are the board
                    // columns below.
                    let rows = model.drillHostedRows()
                    if !rows.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(rows, id: \.task.id) {
                                PeekRow(task: $0.task, depth: $0.depth, now: ctx.date)
                            }
                        }
                        .padding(.leading, 4)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12)
        }
    }

    /// `‹ All projects / <scopePath>` — each ancestor a click that re-scopes there; the current scope is
    /// the bold tail. `‹` and the leading crumb pop toward the top level (recursive drills climb through
    /// every ancestor in `scopePath`).
    private var breadcrumb: some View {
        HStack(spacing: 5) {
            Button { model.setDrillScope(nil) } label: {
                Text("‹ All projects").font(F.ui(12)).foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            ForEach(Array(model.scopePath.enumerated()), id: \.element.id) { idx, node in
                Text("/").font(F.ui(12)).foregroundStyle(theme.text3)
                if idx == model.scopePath.count - 1 {
                    Text(node.title).font(F.ui(12, .semibold)).foregroundStyle(theme.text)
                } else {
                    Button { model.setDrillScope(node.id) } label: {
                        Text(node.title).font(F.ui(12)).foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The banner IS the root card, laid flat — so clicking the box selects the root and opens its
    /// agent, the same `selectAndEnterTerminal` a column card's click runs (this replaces the old
    /// "open agent ↗" button). When that selection lands on the root, the box wears the accent border a
    /// selected card wears, so "you are looking at the parent" reads at a glance. Only the box is the
    /// click target: the hosted reviewer rows sit OUTSIDE it (in `body`'s VStack) and keep their own taps.
    private func banner(_ root: OrchestraCore.Task, now: Date) -> some View {
        let sem = theme.statusColor(root.phaseDisplay)
        let isSelected = model.selectedId == root.id
        return HStack(spacing: 10) {
            // The root's own status pill (dot + state + time-in-state), the same fact the card showed.
            HStack(spacing: 6) {
                Circle().fill(sem.dot).frame(width: 7, height: 7)
                Text("\(theme.statusLabel(root.phaseDisplay)) · \(relativeAge(root.phaseChangedAt))")
                    .font(F.ui(10.5, .semibold)).foregroundStyle(sem.text)
            }
            .padding(.init(top: 3, leading: 7, bottom: 3, trailing: 8))
            .background(Capsule(style: .continuous).fill(sem.tint))

            Text(root.title).font(F.ui(12.5, .semibold)).foregroundStyle(theme.text).lineLimit(1)
            if !root.cardLine.isEmpty {
                Text(root.cardLine).font(F.ui(11)).foregroundStyle(theme.text3).lineLimit(1)
            }
            Text("#\(root.shortId)").font(F.mono(9.5)).foregroundStyle(theme.text3)

            // The root's OWN attention only. Its subtree IS the board below — every card that needs you
            // is already visible as a column citizen — so a rollup here would double-count the very
            // thing you are looking at.
            if let text = Attention.chipText(model.ownAttention(of: root, now: now)) {
                AttentionChip(text: text)
            }

            SubtreeSegments(root: root, now: now)   // the root's OWN live-children bar (no rollup)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.colBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? theme.accent : theme.hair, lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { model.selectAndEnterTerminal(root.id) }
        .help("Open this root's own agent terminal")
    }
}
