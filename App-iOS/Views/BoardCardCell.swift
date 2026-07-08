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
    private var sem: SemColor { theme.statusColor(task.status.rawValue) }
    private var isLive: Bool { task.status == .running || task.status == .waiting }

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
                    .foregroundStyle(task.status == .waiting ? theme.amber.text : theme.text2)
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
                .strokeBorder(task.status == .waiting ? theme.waitingBorder : theme.cardBorder, lineWidth: 1)
        )
        .overlay(alignment: .top) {
            if task.status == .running {
                RoundedRectangle(cornerRadius: 2).fill(theme.green.dot)
                    .frame(height: 2).padding(.horizontal, 10)
            }
        }
        .shadow(color: theme.shadowCard, radius: 3, x: 0, y: 1)
        .opacity(task.status == .dead ? 0.72 : 1)
    }

    // MARK: header — status pill (worktree) or mode chip + read-only (freeform)

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            if isFreeform {
                ModeChip(origin: task.origin)
                if task.access == .readOnly { ReadOnlyBadge() }
            } else {
                StatusPill(status: task.status, sem: sem, updatedAt: task.updatedAt, live: isLive)
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
            if let pct = ctxPct { CtxMiniGauge(pct: pct, theme: theme) }
            meta
        }
    }

    /// Lineage status (branch-tree): `↓N` when the parent advanced (stale), a restack glyph when a
    /// restack is needed. Mirrors the desktop `treeBadge`; hidden when in-sync / untracked.
    @ViewBuilder private var treeBadge: some View {
        if let ts = task.treeStat {
            switch ts.state {
            case .stale:
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down")
                    Text("\(ts.behind)")
                }
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(theme.amber.text)
            case .restackNeeded:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(theme.red.text)
            case .mergeRequested:
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(theme.amber.text)
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
    let status: AgentStatus
    let sem: SemColor
    let updatedAt: Date
    let live: Bool

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
    private var label: String {
        switch status {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .done:    return "Done"
        case .dead:    return "Dead"
        }
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

// MARK: - Freeform chrome

/// The freeform mode chip — the user-facing label (`Freeform`/`Scratch`); the underlying `.borrowed`
/// origin is never surfaced (§2a).
private struct ModeChip: View {
    let origin: CardOrigin
    @Environment(\.theme) private var theme: Theme
    private var label: String { origin == .scratch ? "Scratch" : "Freeform" }
    private var sem: SemColor { origin == .scratch ? theme.gray : theme.indigo }
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: origin == .scratch ? "sparkles" : "folder")
            Text(label)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(sem.text)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(sem.tint))
    }
}

/// The orthogonal Read-only badge (`CardAccess.readOnly`) — separate from the mode chip (§2a).
private struct ReadOnlyBadge: View {
    @Environment(\.theme) private var theme: Theme
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock")
            Text("Read-only")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(theme.text3)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(theme.chip))
    }
}

// MARK: - Context mini-gauge

/// A compact context-window bar: fill proportional to `pct`, greening→ambering→reddening as it fills.
private struct CtxMiniGauge: View {
    let pct: Double
    let theme: Theme
    private var color: Color {
        if pct >= 90 { return theme.red.dot }
        if pct >= 70 { return theme.amber.dot }
        return theme.green.dot
    }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.chip)
                Capsule().fill(color)
                    .frame(width: max(2, geo.size.width * CGFloat(min(100, max(0, pct)) / 100)))
            }
        }
        .frame(width: 30, height: 5)
        .accessibilityLabel("Context \(Int(pct)) percent")
    }
}

/// Relative age like the desktop's `3s`/`4m`/`2h`/`1d`.
private func relativeAge(_ date: Date, now: Date = Date()) -> String {
    let s = Int(max(0, now.timeIntervalSince(date)))
    if s < 60 { return "\(s)s" }
    let m = s / 60; if m < 60 { return "\(m)m" }
    let h = m / 60; if h < 24 { return "\(h)h" }
    return "\(h / 24)d"
}
