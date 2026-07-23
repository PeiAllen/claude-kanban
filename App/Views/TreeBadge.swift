import SwiftUI
import OrchestraUI
import OrchestraCore

/// A child card's lineage state against its parent branch, as one compact glyph: `↓N` while the
/// parent has advanced past the recorded base, a restack arrow once that base is no longer an
/// ancestor, a clock while a merge-request waits, and a red warning once the merge-request has been
/// given up on. Rendered on the board card's footer and in the shared inspector header — one view,
/// so the two surfaces can't drift apart on glyph or colour.
///
/// Nothing renders for `inSync` (and the call sites render nothing at all for a nil `treeStat`):
/// absence is the in-sync signal, so an untracked card and a synced one both stay quiet rather than
/// carry a placeholder that trains the eye to ignore this slot.
///
/// The hover text names the **parent branch** whenever the card records one, because the glyph alone
/// says a parent moved without saying which — the one question a `↓3` immediately raises.
struct TreeBadge: View {
    @Environment(\.theme) var theme: Theme
    let stat: TreeStat
    let parentBranch: String?

    /// Sentence subject for the two help strings that open on the parent: "Parent branch feat/x" when
    /// the name is known, a bare "The parent branch" when it isn't. The other two mention the parent
    /// mid-sentence and interpolate it themselves, since neither reads as a subject.
    private var parentSubject: String {
        parentBranch.map { "Parent branch \($0)" } ?? "The parent branch"
    }

    var body: some View {
        // The give-up flag outranks the tracking state: a stalled card still computes stale/↓N
        // underneath, but "nobody answered the merge-request" is what the human needs to see first.
        if stat.mergeStalled {
            Image(systemName: "exclamationmark.triangle.fill").font(F.ui(8.5))
                .foregroundStyle(theme.red.text)
                // `nudges` really can be 0 here: `giveUp` is also reached with an already-exhausted
                // budget, which gives up without sending anything.
                .help("Merge-request unanswered — \(stat.nudges) reminder\(stat.nudges == 1 ? "" : "s") sent and "
                      + "\(parentBranch ?? "the parent") never merged this branch. "
                      + "Merge it yourself, or re-send the merge-request.")
        } else {
            switch stat.state {
            case .stale:
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down").font(F.ui(8.5))
                    Text("\(stat.behind)").font(F.mono(10, .medium))
                }
                .foregroundStyle(theme.amber.text)
                .help("\(parentSubject) is \(stat.behind) commit\(stat.behind == 1 ? "" : "s") ahead "
                      + "of this card — the agent will merge it down")
            case .restackNeeded:
                Image(systemName: "arrow.triangle.2.circlepath").font(F.ui(8.5))
                    .foregroundStyle(theme.red.text)
                    .help("\(parentSubject)'s history changed (rebased/shipped) — the agent will "
                          + "restack this branch onto it")
            case .mergeRequested:
                Image(systemName: "clock.arrow.circlepath").font(F.ui(8.5))
                    .foregroundStyle(theme.amber.text)
                    .help("Merge requested — waiting for the parent card"
                          + (parentBranch.map { " on \($0)" } ?? "")
                          + " to squash-merge this branch")
            case .inSync:
                EmptyView()
            }
        }
    }
}
