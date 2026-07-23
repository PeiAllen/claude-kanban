import SwiftUI
import OrchestraUI
import OrchestraCore

/// A card's lineage state against its parent branch, as one compact glyph. Shared by the DESKTOP
/// board card's quiet cluster and the desktop inspector header so the two can't drift on glyph or
/// colour. `inSync` renders nothing, and the call sites render nothing for a nil `treeStat`: absence
/// IS the in-sync signal. (The iOS client has its own `TreeBadge` — its palette migrates with the
/// phone's card anatomy in a later slice.)
///
/// The colours say WHO the state is waiting on, which is the only thing you'd act on. Muted blue —
/// behind the parent, or needing a restack — means the card's own agent reconciles it without you.
/// Grey means the wait belongs to someone else (the parent card owes this branch a merge). Only the
/// stalled case, where nobody ever answered, keeps a warning colour. None of them is amber: on the
/// desktop board, saturated amber is being reserved for "needs YOU", and a card whose agent is about
/// to merge its parent down is precisely not that.
struct TreeBadge: View {
    @Environment(\.theme) var theme: Theme
    let stat: TreeStat
    let parentBranch: String?

    /// Whether this draws anything — a caller that puts the badge on its own surface (the inspector
    /// chips it) must know before laying out, or an in-sync card gets an empty chip.
    static func renders(_ stat: TreeStat) -> Bool { stat.mergeStalled || stat.state != .inSync }

    private var parentSubject: String {
        parentBranch.map { "Parent branch \($0)" } ?? "The parent branch"
    }

    var body: some View {
        // The give-up flag outranks the state: a stalled card still computes stale/↓N underneath, but
        // "nobody answered the merge-request" is what the human needs first.
        if stat.mergeStalled {
            Image(systemName: "exclamationmark.triangle.fill").font(F.ui(8.5))
                .foregroundStyle(theme.red.text)
                // `nudges` can be 0 — the daemon also gives up with an already-exhausted budget.
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
                .foregroundStyle(theme.blue.text)
                .help("\(parentSubject) is \(stat.behind) commit\(stat.behind == 1 ? "" : "s") ahead "
                      + "of this card — the agent will merge it down")
            case .restackNeeded:
                Image(systemName: "arrow.triangle.2.circlepath").font(F.ui(8.5))
                    .foregroundStyle(theme.blue.text)
                    .help("\(parentSubject)'s history changed (rebased/shipped) — the agent will "
                          + "restack this branch onto it")
            case .mergeRequested:
                Image(systemName: "clock.arrow.circlepath").font(F.ui(8.5))
                    .foregroundStyle(theme.text3)
                    .help("Merge requested — waiting for the parent card"
                          + (parentBranch.map { " on \($0)" } ?? "")
                          + " to squash-merge this branch")
            case .inSync:
                EmptyView()
            }
        }
    }
}
