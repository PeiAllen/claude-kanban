import SwiftUI
import OrchestraKit
import OrchestraUI

/// A single board card on the phone — the iOS reinterpretation of the desktop `CardView` (design §2).
/// Worktree cards show `repo/branch`; freeform cards (`.borrowed`/`.scratch`) are visually distinct
/// (mode chip, directory path, Read-only badge — §2a). Card contents: title, status pill, model,
/// context mini-gauge, diffstat, current-activity line.
struct BoardCardCell: View {
    let task: Task
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    private var isFreeform: Bool { task.origin != .worktree }
    private var ds: DisplayState { displayState(phase: task.phase, connection: model.connectionState) }
    private var sem: SemColor { theme.statusColor(ds.statusKey) }
    private var isLive: Bool { if case .live = task.phase { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(task.title)
                .font(.headline)
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !task.desc.isEmpty {
                Text(task.desc)
                    .font(.subheadline)
                    .foregroundStyle(task.waitReason != nil ? theme.amber.text : theme.text2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(task.waitReason != nil ? theme.waitingBorder : theme.cardBorder, lineWidth: 1)
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
            if isFreeform {
                // Freeform still shows its live status on the right so the page isn't stripped of it.
                StatusDot(sem: sem, live: isLive)
            }
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
    /// restack is needed. Mirrors the desktop `treeBadge`; hidden when in-sync / untracked.
    @ViewBuilder private var treeBadge: some View {
        if let ts = task.treeStat {
            // S3-3: the phone has no hover tooltip — carry the meaning in an accessibility label so the
            // otherwise-cryptic glyphs (↓N / restack / waiting) are legible to VoiceOver + long-press.
            switch ts.state {
            case .stale:
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down")
                    Text("\(ts.behind)")
                }
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(theme.amber.text)
                .accessibilityLabel("Parent branch is \(ts.behind) commit\(ts.behind == 1 ? "" : "s") ahead")
            case .restackNeeded:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(theme.red.text)
                    .accessibilityLabel("Parent history changed — restack needed")
            case .mergeRequested:
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(theme.amber.text)
                    .accessibilityLabel("Merge requested — waiting for the parent card")
            case .mergeStalled:
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(theme.red.text)
                    .accessibilityLabel("Merge-request unanswered after \(ts.nudges) reminders — "
                                        + "the parent card never merged this branch")
            case .inSync:
                EmptyView()
            }
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

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(sem: sem, live: live)
            if live {
                // Tick the age once a second so "Running · 3s" stays honest.
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
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
    }
}

/// A breathing pulse dot while the card is live (running/waiting), static otherwise.
private struct StatusDot: View {
    let sem: SemColor
    let live: Bool
    @State private var on = false
    var body: some View {
        Circle().fill(sem.dot).frame(width: 7, height: 7)
            .opacity(live ? (on ? 0.4 : 1) : 1)
            .onAppear {
                guard live else { return }
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

// The freeform mode chip, read-only badge, and context mini-gauge are now shared views in
// OrchestraUI/SharedUI.swift (used by the detail header too). See `ModeChip` / `ReadOnlyBadge` /
// `CtxGauge`.
