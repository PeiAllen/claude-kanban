import SwiftUI
import OrchestraKit
import OrchestraUI

/// A single board card on the phone — the iOS reinterpretation of the desktop `CardView` (design §2).
/// Worktree cards show `repo/branch`; freeform cards (`.borrowed`/`.scratch`) are visually distinct
/// (mode chip, directory path, Read-only badge — §2a). Card contents: title, status pill, model,
/// context mini-gauge, diffstat, current-activity line.
struct BoardCardCell: View {
    let task: Task
    /// When the peek accordion is expanded, the card's bottom corners square off so the `PeekRows` block
    /// drawn directly below merges into one continuous frame (not a separate tile). Default
    /// false — freeform cards and collapsed targets keep the full round. Also hides the L4 summary (the
    /// rows replace it).
    var expanded: Bool = false
    /// The card-level clock, from `MovableCard`'s `TimelineView` — attention is time-derived, so the L1
    /// chip and the L4 subtree line must tick rather than wait for a daemon event.
    var now: Date = .distantPast
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    private var isFreeform: Bool { task.origin != .worktree }
    private var ds: DisplayState { displayState(phase: task.phase, connection: model.connectionState) }
    private var sem: SemColor { theme.statusColor(ds.statusKey) }
    private var isLive: Bool { if case .live = task.phase { return true } else { return false } }

    /// The card outline — fully rounded, or squared at the bottom when the accordion is open.
    private var cardShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: expanded ? 0 : 14,
                               bottomTrailingRadius: expanded ? 0 : 14, topTrailingRadius: 14,
                               style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(task.title)
                .font(.headline)
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            // `note ?? desc` — the authored line wins over the volatile status blurb (Task.cardLine).
            if !task.cardLine.isEmpty {
                Text(task.cardLine)
                    .font(.subheadline)
                    .foregroundStyle(task.agentState?.isWaiting == true ? theme.amber.text : theme.text2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
            subtreeLine
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape.fill(theme.card))
        .overlay(
            cardShape.strokeBorder(task.agentState?.isWaiting == true ? theme.waitingBorder : theme.cardBorder, lineWidth: 1)
        )
        .overlay(alignment: .top) {
            if task.phaseDisplay == .running {
                RoundedRectangle(cornerRadius: 2).fill(theme.green.dot)
                    .frame(height: 2).padding(.horizontal, 10)
            }
        }
        .shadow(color: theme.shadowCard, radius: 3, x: 0, y: 1)
        .opacity((task.phaseDisplay == .dead || ds.isStale) ? 0.72 : 1)
    }

    // MARK: header — status pill (worktree) or mode chip + read-only (freeform)

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            if isFreeform {
                ModeChip(origin: task.origin)
                if task.access == .readOnly { ReadOnlyBadge() }
            } else {
                StatusPill(status: ds.statusKey, label: ds.label, sem: sem, updatedAt: task.updatedAt, live: isLive)
            }
            Spacer(minLength: 4)
            // OWN attention (L1) — a compact SOLID amber chip is the "scan for solid amber = needs you"
            // signal, and it replaces the quiet right-side cluster when present (design §"Card anatomy").
            if let attn = Attention.chipText(model.ownAttention(of: task, now: now)) {
                AttentionChipIOS(text: attn)
            } else if isFreeform {
                // Freeform still shows its live status on the right so the page isn't stripped of it.
                StatusDot(sem: sem, live: isLive)
            }
        }
    }

    // MARK: L4 — subtree line (segments · eye · descendants attention chip)

    /// A root that has already SHIPPED all its children (no live subordinate but `mergedChildren > 0`)
    /// keeps its progress bar, so the line shows on non-zero counters too.
    private var hasProgressCounters: Bool {
        guard let ts = task.treeStat else { return false }
        return ts.mergedChildren > 0 || ts.plannedChildren > 0
    }

    /// The card's subordinates, summarised — shown whenever the card has a live subordinate OR non-zero
    /// progress counters, and it is NOT peek-expanded (the peek rows replace the summary, so the two never
    /// show at once). Non-interactive, so it lives in the card body (below the move-gesture overlay) safely.
    @ViewBuilder private var subtreeLine: some View {
        if !expanded, !model.subordinates(of: task).isEmpty || hasProgressCounters {
            Rectangle().fill(theme.hair).frame(height: 0.5).padding(.top, 2)
            SubtreeLineIOS(task: task, now: now).padding(.top, 2)
        }
    }

    // MARK: footer — path/branch (mono) · ctx gauge · diffstat|model

    private var footer: some View {
        HStack(spacing: 8) {
            Text(pathLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            treeBadge
            parentChip
            Spacer(minLength: 6)
            if let pct = ctxPct { CtxGauge(pct: pct, theme: theme, width: 30, height: 5, minFill: 2, showPercent: false) }
            meta
        }
    }

    /// Lineage status (branch-tree): `↓N` when the parent advanced (stale), a restack glyph when a
    /// restack is needed. Mirrors the desktop `treeBadge`; hidden when in-sync / untracked. The glyphs
    /// themselves live in `TreeBadge`, shared with the card-detail header.
    @ViewBuilder private var treeBadge: some View {
        if let ts = task.treeStat {
            TreeBadge(stat: ts, parentBranch: task.parentBranch)
        }
    }

    /// Parent-branch chip: `⤴ <parent>` when the card has a parent branch. Tapping navigates to the
    /// live parent card's detail (sets `selectedId`); a no-op when no live card owns the branch.
    @ViewBuilder private var parentChip: some View {
        if let parent = task.parentBranch {
            let target = model.parentCard(of: task)
            Button {
                if let target { model.selectedId = target.id }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.turn.left.up")
                    Text(parent).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(target != nil ? theme.accent : theme.text3)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(theme.chip))
            }
            .buttonStyle(.plain)
            .disabled(target == nil)
            .frame(maxWidth: 130, alignment: .leading)
        }
    }

    /// `repo/branch` for worktree cards; the borrowed directory path for freeform cards (§2a).
    private var pathLabel: String {
        if isFreeform { return abbreviatedPath(task.cwd) }
        return "\((task.repo as NSString).lastPathComponent)/\(task.branch)"
    }

    /// Context-window usage, only when the agent has reported a non-zero fraction.
    private var ctxPct: Double? { task.ctxPct > 0 ? task.ctxPct : nil }

    /// Diffstat when the daemon computed a non-empty one; otherwise the model name (matches desktop).
    @ViewBuilder private var meta: some View {
        if let s = task.diffStat, s.filesChanged > 0 {
            HStack(spacing: 5) {
                Text("+\(s.insertions)").foregroundStyle(theme.green.text)
                Text("−\(s.deletions)").foregroundStyle(theme.red.text)
                Text("\(s.filesChanged)f").foregroundStyle(theme.text3)
            }
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .lineLimit(1)
        } else if !task.model.id.isEmpty {
            Text(task.model.displayName)
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(theme.text2)
                .lineLimit(1)
        }
    }
}

/// Collapse a long borrowed path to `…/parent/dir` so it fits the footer without eating the whole row.
private func abbreviatedPath(_ path: String) -> String {
    let parts = (path as NSString).pathComponents.filter { $0 != "/" }
    guard parts.count > 2 else { return path }
    return "…/" + parts.suffix(2).joined(separator: "/")
}

// MARK: - Status pill / dot

private struct StatusPill: View {
    let status: PhaseDisplayKey
    let label: String
    let sem: SemColor
    let updatedAt: Date
    let live: Bool
    @Environment(\.theme) private var theme: Theme
    @Environment(\.animationsActive) private var animationsActive

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(sem: sem, live: live)
            if live {
                // Coarsen once the stamp reads in minutes (ageRefreshInterval: 1s only in the first minute,
                // then 60s), and pause entirely while the app is backgrounded / this cell is scrolled off.
                TimelineView(PausableTimelineSchedule(.periodic(from: .now, by: ageRefreshInterval(updatedAt)),
                                                      paused: !animationsActive)) { ctx in
                    Text(label + " · " + relativeAge(updatedAt, now: ctx.date))
                }
            } else {
                Text(label)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(sem.text)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(sem.tint))
        // Intrinsically sized, like the card-detail header's twin of this pill: without it a narrow card
        // squeezes "Running · 3s" and wraps it into a multi-line blob that inflates the header's height.
        .fixedSize()
    }
}

/// A breathing pulse dot while the card is live (running/waiting), static otherwise. The phone dot is
/// opacity-only (no scale on a 7px dot); `PulseDot` carries the shared idle-CPU gating.
private struct StatusDot: View {
    let sem: SemColor
    let live: Bool
    var body: some View {
        PulseDot(color: sem.dot, size: 7, active: live, dim: 0.4, scaleTo: nil)
    }
}

// The freeform mode chip, read-only badge, and context mini-gauge are now shared views in
// OrchestraUI/SharedUI.swift (used by the detail header too). See `ModeChip` / `ReadOnlyBadge` /
// `CtxGauge`.
