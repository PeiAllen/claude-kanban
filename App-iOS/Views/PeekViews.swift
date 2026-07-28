import SwiftUI
import OrchestraKit
import OrchestraUI

/// iOS **peek** affordance (BT slice 5) — the tap-toggled inline accordion inside a card, generalized from
/// the shipped attached-agents redesign to ALL subordinates (lineage children first, then attached
/// reviewers — `model.expandedRows(for:)` = `subordinates(of:)`). A non-root descendant is embedded behind
/// its root (`IOSBoardModel.isEmbedded`) and reached ONLY here: the card's `PeekToggle` reveals its direct
/// subordinates as rows *inside the card's frame*, and tapping a row opens that card's detail. Desktop
/// reveals on selection; iOS is tap-driven because selecting a card pushes a full-screen detail.

/// The peek disclosure toggle: an eye + count (tinted by the fold-derived `attentionLiveness`) when the
/// card has attached reviewers, else a subtree glyph + count; plus a chevron. Rides ABOVE the card's
/// move-gesture overlay (top-trailing) so its tap wins. Visible iff the card has ≥1 subordinate — NOT
/// gated on `attachedLiveness`, so a pure-lineage-child card (and a nested reviewer whose own
/// `attachedAgents` is empty) still gets a reveal.
struct PeekToggle: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    let task: Task

    var body: some View {
        let subs = model.subordinates(of: task)
        if !subs.isEmpty {
            let attached = model.attachedAgents(of: task)
            let expanded = model.isPeekExpanded(task)
            // Fold-derived tint (retires the phase-only `attachedLiveness` at this iOS site): amber when a
            // reviewer needs the human, green while active, grey when all concluded.
            let tint = attached.isEmpty ? theme.text2 : theme.eyeTint(model.attentionLiveness(of: task) ?? .idle)
            Button { model.togglePeek(task) } label: {
                HStack(spacing: 3) {
                    Image(systemName: attached.isEmpty ? "arrow.triangle.branch" : "eye")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(subs.count)").font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .chipText()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Capsule().fill(theme.chip))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(subs.count == 1 ? "1 subordinate" : "\(subs.count) subordinates")
            .accessibilityHint(expanded ? "Collapse" : "Expand")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
        }
    }
}

/// The expanded accordion body: the target's direct subordinates (`model.expandedRows(for:)`) as compact
/// peek rows, styled to read as the BOTTOM of the target card (squared-top / rounded-bottom fill, drawn
/// directly under it — one continuous frame). Rendered as a sibling BELOW the gestured header (never under
/// the move-gesture overlay), so its row `Button`s receive taps. `now` ticks the rows' own-attention labels.
struct PeekRows: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    let target: Task
    var now: Date = .distantPast

    private static let shape = UnevenRoundedRectangle(
        topLeadingRadius: 0, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 0,
        style: .continuous)

    var body: some View {
        let rows = model.expandedRows(for: target)
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, sub in
                if idx > 0 { Rectangle().fill(theme.hair).frame(height: 0.5).padding(.leading, 14) }
                PeekRow(task: sub, now: now)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.shape.fill(theme.card))
        .overlay(Self.shape.strokeBorder(theme.cardBorder, lineWidth: 1))
    }
}

/// The visual for one peek row (design §"Peek rows"): dot (the child's OWN phase) · shortId · title ·
/// desc/note (dim context, lowest precedence, truncates first) · action slot (own-attention label if any,
/// else compact diff) · chip slot (lineage child → a stage-tinted column chip; attached reviewer → a
/// liveness-tinted eye; columnless → "freeform"). Shared by the board row (a `Button` that selects) and the
/// detail-header row (a `NavigationLink` that pushes) so the two can't drift.
///
/// Laid out exactly like the desktop peek row (`App/Views/AttachedAgents.swift`) because it hit — and
/// solved — the same failure first: a FIXED row height plus a MEASURED-width squish ladder. Every chip is
/// intrinsically sized via `chipText()` (see `Chips.swift`), so a narrow row truncates the flexible title
/// and desc/note instead of wrapping a chip into a tall tower.
struct PeekRowLabel: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    let task: Task
    var now: Date = .distantPast
    var isSelected: Bool = false

    /// Uniform row height. This is the STRUCTURAL half of the fix: even if some future zone did manage
    /// to wrap, the row cannot grow to accommodate it, so a single starved chip can never inflate the
    /// list again. It also lets the `GeometryReader` measure width without filling vertically. Sized to
    /// the tallest zone (the `.subheadline` title) with a hair of slack.
    private let rowH: CGFloat = 21

    /// The loss order as the row narrows, matching the peek-row spec's precedence: the dim desc/note
    /// context drops first, then the stage chip collapses word→letter. The title (kept to its first
    /// words) and the chip itself are never lost. Thresholds sit above the desktop's because a phone row
    /// also carries a shortId and a chevron (~58pt the desktop row spends on neither).
    private enum W {
        // Below this the desc/note zone drops out ENTIRELY. Set above a standard iPhone board row
        // (~340pt) deliberately: the zone is the design's lowest-precedence field, so on a tight row it
        // must yield to the title rather than clip it — and a zone squeezed to a lone "…" is worse than
        // an absent one. It returns on the roomy rows (iPad, landscape) where it can say something.
        static let context: CGFloat = 380
        static let stageWord: CGFloat = 340 // below this, the stage chip collapses to its letter
        static let diff: CGFloat = 210      // below this, the diffstat drops (attention never does)
    }
    /// The context zone's share once it earns a place. A floor because the title is greedy
    /// (`layoutPriority(1)`) and would otherwise leave the zone a single vestigial "…"; a ceiling so a
    /// long note can't crowd out the title. Between them the zone is always a readable slice or absent.
    private static let contextWidth: ClosedRange<CGFloat> = 50...110

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 10) {
                Circle().fill(theme.statusColor(task.phaseDisplay).dot).frame(width: 6, height: 6)
                Text(task.shortId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.text3)
                    .chipText()                 // a wrapped 6-char id was its own tall tower
                Text(task.title)
                    .font(.subheadline)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .layoutPriority(1)          // title outranks the context zone, which truncates first
                // Dim context zone (design §"Peek rows": desc/note, lowest precedence). Gives a quiet
                // subordinate its hierarchy/work context; it is the first thing sacrificed when tight.
                if w >= W.context, !task.cardLine.isEmpty {
                    Text(task.cardLine)
                        .font(.caption2)
                        .foregroundStyle(theme.text3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: Self.contextWidth.lowerBound,
                               maxWidth: Self.contextWidth.upperBound, alignment: .leading)
                }
                Spacer(minLength: 8)
                actionSlot(w: w)
                chipSlot(word: w >= W.stageWord)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(theme.text3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: rowH)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(isSelected ? theme.accent.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
    }

    /// Own-attention label (solid amber) if the child needs you, else its compact diffstat. The attention
    /// chip sits at the TOP of the keep-order — it survives every width, because a row that needs you must
    /// say so even when there is no room left to say how big its diff is.
    @ViewBuilder private func actionSlot(w: CGFloat) -> some View {
        if let text = Attention.chipText(model.ownAttention(of: task, now: now)) {
            AttentionChipIOS(text: text)
        } else if w >= W.diff, let s = task.diffStat, s.filesChanged > 0 {
            HStack(spacing: 4) {
                Text("+\(s.insertions)").foregroundStyle(theme.green.text)
                Text("−\(s.deletions)").foregroundStyle(theme.red.text)
            }
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .chipText()                         // else a starved `+N −M` wraps its digits
        }
    }

    /// Attached reviewer → liveness-tinted eye; lineage child → stage-tinted column chip; columnless →
    /// "freeform".
    @ViewBuilder private func chipSlot(word: Bool) -> some View {
        if model.isAttached(task) {
            Image(systemName: "eye").font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.eyeTint(model.attentionTier(of: task)))
        } else if task.origin == .worktree {
            StagePillIOS(column: task.column, word: word)
        } else {
            FreeformChipIOS()
        }
    }
}

/// The BOARD peek row: a `Button` that selects the subordinate. On the board that's correct — the Board
/// tab's `navigationDestination(item: selectedCardBinding)` observes `selectedId` and pushes the card's
/// detail. NOTE: this selection path is Board-tab-specific — the card-DETAIL list uses a `NavigationLink`
/// instead (see `CardDetailHeader`), because that detail can be presented from the Needs You tab too,
/// whose stack does NOT observe `selectedId`.
struct PeekRow: View {
    @EnvironmentObject private var model: BoardModel
    let task: Task
    var now: Date = .distantPast

    var body: some View {
        Button { model.selectedId = task.id } label: {
            PeekRowLabel(task: task, now: now, isSelected: model.selectedId == task.id)
        }
        .buttonStyle(.plain)
    }
}
