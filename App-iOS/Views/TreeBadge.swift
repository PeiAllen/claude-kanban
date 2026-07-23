import SwiftUI
import OrchestraKit
import OrchestraUI

/// The phone mirror of the desktop `TreeBadge`: a card's lineage state against its parent branch as
/// one compact glyph, shared by the board cell's footer and the card-detail header. `inSync` renders
/// nothing, and the call sites render nothing for a nil `treeStat` — absence IS the in-sync signal.
/// With no hover to hold a tooltip, the meaning rides an **accessibility label** (VoiceOver, and what
/// a long-press surfaces) instead.
struct TreeBadge: View {
    @Environment(\.theme) private var theme: Theme
    let stat: TreeStat
    let parentBranch: String?

    private var parentSubject: String {
        parentBranch.map { "Parent branch \($0)" } ?? "The parent branch"
    }

    var body: some View {
        // The give-up flag outranks the state: a stalled card still computes stale/↓N underneath, but
        // "nobody answered the merge-request" is what the human needs first.
        if stat.mergeStalled {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(theme.red.text)
                // `nudges` can be 0 — the daemon also gives up with an already-exhausted budget.
                .accessibilityLabel("Merge-request unanswered after \(stat.nudges) "
                                    + "reminder\(stat.nudges == 1 ? "" : "s") — "
                                    + "\(parentBranch ?? "the parent branch") never merged this")
        } else {
            switch stat.state {
            case .stale:
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down")
                    Text("\(stat.behind)")
                }
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(theme.amber.text)
                .accessibilityLabel("\(parentSubject) is \(stat.behind) "
                                    + "commit\(stat.behind == 1 ? "" : "s") ahead")
            case .restackNeeded:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(theme.red.text)
                    .accessibilityLabel("\(parentSubject) rewrote its history — restack needed")
            case .mergeRequested:
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(theme.amber.text)
                    .accessibilityLabel("Merge requested — waiting for the parent card"
                                        + (parentBranch.map { " on \($0)" } ?? ""))
            case .inSync:
                EmptyView()
            }
        }
    }
}
