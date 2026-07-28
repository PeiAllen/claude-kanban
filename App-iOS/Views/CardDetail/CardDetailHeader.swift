import SwiftUI
import OrchestraKit
import OrchestraUI

/// The card-detail **pinned header** (design §3): title, status pill, model chip, context-window gauge,
/// and the worktree breadcrumb (`repo/branch → path`). Stays pinned above the tab bar while the tab body
/// scrolls. Reads a live `Task` (the detail view resolves it from `BoardModel` by id), so the pill/gauge
/// tick as the daemon streams events.
struct CardDetailHeader: View {
    let task: Task
    let connection: ConnectionState
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    private var ds: DisplayState { displayState(phase: task.phase, connection: connection) }
    private var sem: SemColor { theme.statusColor(ds.statusKey) }
    private var isLive: Bool { if case .live = task.phase { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(task.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                DetailStatusPill(status: ds.statusKey, label: ds.label, sem: sem, updatedAt: task.updatedAt, live: isLive)
            }

            // A freeform card with a big diffstat and a long model name overruns this row on a phone —
            // the mode chip wraps to two lines and the context gauge loses its percentage off the
            // trailing edge. So the diffstat gives ground before its neighbours do: full chip, then
            // without the file count, then gone. (The desktop inspector header degrades the same way.)
            //
            // The tree badge inside the row is NOT part of that ladder: it is one glyph plus at most a
            // couple of digits, and it is the row's only signal that this branch has fallen behind its
            // parent — the diffstat can shrink to buy that room, which is exactly what the rungs below
            // do before anything else gives.
            ViewThatFits(in: .horizontal) {
                chipRow(stat: .full)
                chipRow(stat: .compact)
                chipRow(stat: .hidden)
            }

            Text(breadcrumb)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)

            // The revealed subordinates (gated by `showsInlineRows` = the tap-expand state) — lineage
            // children AND attached reviewers, one hop. This is the path that reveals a nested reviewer R2:
            // R1's detail expands `subordinates(of: R1) = [R2]`. Each row is a `NavigationLink` that PUSHES
            // the card's detail onto whatever stack this detail is in — NOT a `selectedId` write. The card
            // detail is presented from BOTH the Board tab (selectedId-driven) AND the Needs You tab (its
            // own `$route`); a `selectedId` write would be a dead tap on Needs You and a phantom Board push.
            peekRowsSection
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card)
        .overlay(Rectangle().fill(theme.hair).frame(height: 0.5), alignment: .bottom)
    }

    private var breadcrumb: String {
        cardBreadcrumb(repo: task.repo, branch: task.branch, cwd: task.cwd, origin: task.origin)
    }

    /// The revealed peek rows (subordinates), each a stack-relative `NavigationLink`. Own clock so the
    /// rows' time-derived own-attention labels tick without a daemon event.
    @ViewBuilder private var peekRowsSection: some View {
        let rows = model.expandedRows(for: task)
        if !rows.isEmpty {
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, sub in
                        if idx > 0 { Rectangle().fill(theme.hair).frame(height: 0.5) }
                        NavigationLink { CardDetailView(taskId: sub.id) } label: {
                            PeekRowLabel(task: sub, now: ctx.date)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.winBg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
            }
        }
    }

    @ViewBuilder private func chipRow(stat: DiffStatChip.Size) -> some View {
        HStack(spacing: 8) {
            if task.origin != .worktree { ModeAccessChips(origin: task.origin, access: task.access) }
            ModelChip(model: task.model)
            // How big the card's change is, in the same chip language as its neighbours — the desktop
            // shows this in its inspector header for the same reason: the Diff tab is a tab away, and
            // "how much changed" is a decision you make before opening it.
            DiffStatChip(task: task, size: stat)
            // Jump UP the lineage. Generic across card kinds — not reviewer-specific.
            ParentChip(task: task)
            // ...and the state of that lineage, the same glyph the board cell carries. It belongs
            // beside the parent chip (which says WHO the parent is, not whether this branch is current
            // with it), and in this header rather than a tab, because the header is pinned above all of
            // them — so branch-sync status reads from Diff and Terminal alike, without going back to
            // the board. Nothing renders while the card is in sync or untracked.
            if let ts = task.treeStat {
                TreeBadge(stat: ts, parentBranch: task.parentBranch)
            }
            // The peek affordance in the detail (parity with the board accordion): the toggle expands the
            // card's subordinates as inline rows below. Subordinates-gated (NOT `attachedLiveness`), so a
            // nested reviewer's or a pure-lineage-child card's detail still reveals. Same tap-expand state
            // as the board, so it stays consistent.
            PeekToggle(task: task)
            Spacer(minLength: 6)
            if task.ctxPct > 0 { CtxGauge(pct: task.ctxPct, theme: theme) }
        }
    }
}

// MARK: - Header pieces

/// Status pill matching the board cell's language, scaled up a touch for the header.
private struct DetailStatusPill: View {
    let status: PhaseDisplayKey
    let label: String
    let sem: SemColor
    let updatedAt: Date
    let live: Bool
    @Environment(\.theme) private var theme: Theme
    @Environment(\.animationsActive) private var animationsActive

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(sem.dot).frame(width: 7, height: 7)
            if live {
                // Coarsen past the first minute, and pause when the app is backgrounded.
                TimelineView(PausableTimelineSchedule(.periodic(from: .now, by: ageRefreshInterval(updatedAt)),
                                                      paused: !animationsActive)) { ctx in
                    Text(label + " · " + relativeAge(updatedAt, now: ctx.date))
                }
            } else {
                Text(label)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(sem.text)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(sem.tint))
        .fixedSize()
    }
}

/// The card's PARENT as a tappable chip (`⤴ <parent title>`) — the "go up the lineage" affordance, and
/// the mirror of the attached-agents accordion that goes down it. Deliberately **generic across card
/// kinds**, not reviewer-specific: one rule, `attachedTarget ?? parentCard`, resolves
///  • an embedded read-only reviewer → the card it reviews (`attachedTarget` — which also covers the
///    branchless `.borrowed` reviewer that has no `parentBranch` and so no lineage parent), and
///  • any ordinary stacked child card (spawned with `base:`) → its lineage parent (`parentCard`).
/// For a worktree reviewer the two coincide, so the fallback is only ever load-bearing for the other two.
/// It resolves ONE hop (a nested reviewer goes to its immediate target, not the flattened root), which is
/// what "parent" means here. This is the only way back up from an embedded reviewer: its board-cell
/// `parentChip` never renders, because an embedded card is never drawn as a board cell.
///
/// A `NavigationLink` (not a `selectedId` write) so it pushes onto whatever stack this detail is in — the
/// Board tab presents card details off `selectedId` but the Needs You tab presents them off its own
/// `$route`, and a `selectedId` write is a dead tap there. Self-hides when no parent is derivable.
private struct ParentChip: View {
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    let task: Task

    var body: some View {
        if let parent = model.attachedTarget(of: task) ?? model.parentCard(of: task) {
            NavigationLink { CardDetailView(taskId: parent.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.left.up").font(.caption2)
                    Text(parent.title).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(theme.chip))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 170, alignment: .leading)
            .accessibilityLabel("Open parent card: \(parent.title)")
        }
    }
}

/// The card's branch diffstat as a chip — `+214 −38 7f`, the board cell's ordering and colors
/// (`BoardCardCell.meta`) so the list and the detail read as one fact. Self-hides when the daemon has
/// no stat: non-git card, or nothing changed yet. Not tappable — the Diff tab is one tab away and this
/// is a glance, not a control.
///
/// The numbers measure the card's DEFAULT baseline (parent-relative when stacked, else branch), which
/// is also what the Diff tab opens on; switch that tab's baseline picker to Working and it will
/// legitimately show a different range than this chip.
private struct DiffStatChip: View {
    /// How much of the stat this row can afford — `+N −M` is the part worth keeping longest, and the
    /// file count is the first thing to go (it is also in the accessibility label either way).
    enum Size { case full, compact, hidden }

    let task: Task
    var size: Size = .full
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        if size != .hidden, let s = task.diffStat, s.filesChanged > 0 {
            HStack(spacing: 4) {
                Text("+\(s.insertions)").foregroundStyle(theme.green.text)
                Text("−\(s.deletions)").foregroundStyle(theme.red.text)
                if size == .full { Text("\(s.filesChanged)f").foregroundStyle(theme.text3) }
            }
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(theme.chip))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(s.filesChanged) files changed, \(s.insertions) added, \(s.deletions) removed")
        }
    }
}

/// The model handle as a display chip (family-accented). Model *switching* is not a shipped RPC, so this
/// is intentionally a read-only chip, not a faked interactive selector — see the M2 handoff.
private struct ModelChip: View {
    let model: AgentModel
    @Environment(\.theme) private var theme: Theme
    private var sem: SemColor {
        switch model.family {
        case "claude": return theme.amber
        case "gpt":    return theme.green
        case "gemini": return theme.blue
        default:       return theme.gray
        }
    }
    var body: some View {
        if !model.id.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.caption2)
                Text(model.displayName).lineLimit(1)
            }
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .foregroundStyle(sem.text)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(sem.tint))
        }
    }
}

/// Freeform mode + read-only chips (a freeform card has no `repo/branch`, so the header surfaces its
/// mode/access instead — §2a language). Composed from the shared `ModeChip` / `ReadOnlyBadge`
/// (OrchestraUI); the wider percent gauge is the shared `CtxGauge`'s default configuration.
private struct ModeAccessChips: View {
    let origin: CardOrigin
    let access: CardAccess
    var body: some View {
        HStack(spacing: 6) {
            ModeChip(origin: origin)
            if access == .readOnly { ReadOnlyBadge() }
        }
    }
}
