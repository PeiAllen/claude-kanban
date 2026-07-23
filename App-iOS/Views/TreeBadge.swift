import SwiftUI
import OrchestraKit
import OrchestraUI

/// A card's lineage state against its parent branch, as one compact glyph: `↓N` while the parent has
/// advanced past the recorded base, a restack arrow once that base is no longer an ancestor, a clock
/// while a merge-request waits, and a red warning once that request has been given up on. Rendered on
/// the board cell's footer and in the card-detail header — one view, so the two surfaces can't drift.
/// The phone mirror of the desktop `TreeBadge`.
///
/// Nothing renders for `inSync` (and the call sites render nothing at all for a nil `treeStat`):
/// absence is the in-sync signal, so an untracked card and a synced one both stay quiet rather than
/// carry a placeholder that trains the eye to ignore this slot.
///
/// The phone has no hover, so the meaning rides an **accessibility label** instead of a tooltip —
/// which is what VoiceOver reads and what a long-press surfaces. Like the desktop's help text it names
/// the PARENT BRANCH when the card records one: a bare `↓3` says a parent moved without saying which.
struct TreeBadge: View {
    @Environment(\.theme) private var theme: Theme
    let stat: TreeStat
    let parentBranch: String?

    /// Sentence subject for the labels that open on the parent: "Parent branch feat/x" when the name is
    /// known, a bare "The parent branch" when it isn't.
    private var parentSubject: String {
        parentBranch.map { "Parent branch \($0)" } ?? "The parent branch"
    }

    var body: some View {
        // The give-up flag outranks the tracking state: a stalled card still computes stale/↓N
        // underneath, but "nobody answered the merge-request" is what the human needs to see first.
        if stat.mergeStalled {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(theme.red.text)
                // `nudges` really can be 0 here: the daemon also gives up with an exhausted budget,
                // which stops without sending anything.
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
