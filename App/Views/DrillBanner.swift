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
            VStack(alignment: .leading, spacing: 8) {
                breadcrumb
                banner(root)
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
                    Text(node.title).font(F.ui(12, .semibold)).foregroundStyle(theme.text)   // current
                } else {
                    Button { model.setDrillScope(node.id) } label: {
                        Text(node.title).font(F.ui(12)).foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func banner(_ root: OrchestraCore.Task) -> some View {
        let sem = theme.statusColor(root.phaseDisplay)
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

            SubtreeSegments(root: root)   // the root's OWN live-children bar (no rollup)

            Spacer(minLength: 8)
            // The root left the columns to become this banner, so this is how you reach its own agent.
            Button { model.selectAndEnterTerminal(root.id) } label: {
                Text("open agent ↗").font(F.ui(11)).foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .help("Open this root's own agent terminal")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.colBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.hair, lineWidth: 1)
        )
    }
}
