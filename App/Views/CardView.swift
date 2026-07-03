import SwiftUI
import OrchestraCore

/// A single board card (ui-spec §3.4, §4.3).
struct CardView: View {
    let task: OrchestraCore.Task

    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    private var isSelected: Bool { model.selectedId == task.id }
    private var statusKey: String { task.status.rawValue }
    private var sem: SemColor { theme.statusColor(statusKey) }
    private var isRunning: Bool { task.status == .running }
    private var isWaiting: Bool { task.status == .waiting }
    private var isDead: Bool { task.status == .dead }

    private var borderColor: Color {
        if isSelected { return theme.accent }
        if isWaiting { return theme.waitingBorder }
        return theme.cardBorder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusPill
            title
            description
            footer
        }
        .padding(model.density.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card)
        )
        .overlay(alignment: .top) { shimmerBar }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? theme.accent : Color.clear, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: theme.shadowCard,
                radius: isSelected ? 10 : 1,
                x: 0, y: isSelected ? 8 : 1)
        .opacity(dimmed ? 0.32 : (isDead ? 0.72 : 1))
        .overlay(alignment: .topLeading) { hintBadge }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Clicking a card is a board-level select — land in the board zone (don't inherit a stale
        // terminal zone from a previously-descended card).
        .onTapGesture { model.selectedId = task.id; model.focusZone = .board }
    }

    /// Dim when a `/` search is active and this card doesn't match.
    private var dimmed: Bool { model.searchActive && !model.isSearchMatch(task) }

    /// The `f` link-hint label badge, shown over each card while hint mode is active.
    @ViewBuilder private var hintBadge: some View {
        if model.hintActive, let label = model.hintLabels[task.id] {
            Text(label.uppercased())
                .font(F.mono(11, .heavy)).foregroundStyle(.white)
                .padding(.horizontal, 6).frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.accent))
                .shadow(color: Color(r: 0, g: 0, b: 0, a: 0.3), radius: 3, y: 1)
                .padding(6)
        }
    }

    // MARK: - Running shimmer (2px top bar)

    @ViewBuilder private var shimmerBar: some View {
        if isRunning {
            ShimmerBar(color: theme.green.dot)
                .frame(height: 2)
        }
    }

    // MARK: - Status pill

    @ViewBuilder private var statusPill: some View {
        if isRunning || isWaiting {
            // Live age: re-render the label once a second so "Running · 3s" actually ticks.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                pill(theme.statusLabel(statusKey) + " · " + relativeAge(task.updatedAt, now: ctx.date))
            }
        } else {
            pill(theme.statusLabel(statusKey))
        }
    }

    private func pill(_ label: String) -> some View {
        HStack(spacing: 6) {
            BreathingDot(color: sem.dot, size: 6, active: isRunning || isWaiting)
            Text(label)
                .font(F.ui(10.5, .semibold))
                .tracking(0.0525)
                .foregroundStyle(sem.text)
        }
        .padding(.init(top: 3, leading: 7, bottom: 3, trailing: 8))
        .background(Capsule(style: .continuous).fill(sem.tint))
    }

    // MARK: - Title

    private var title: some View {
        Text(task.title)
            .font(F.ui(model.density.cardTitle, .semibold))
            .tracking(-0.135)
            .foregroundStyle(theme.text)
            .lineSpacing(model.density.cardTitle * 0.32)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 9)
            .padding(.bottom, 5)
    }

    // MARK: - Description

    @ViewBuilder private var description: some View {
        if !task.desc.isEmpty {
            Text(task.desc)
                .font(F.ui(11.5))
                .foregroundStyle(isWaiting ? theme.amber.text : theme.text2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            if task.origin == .worktree {
                Text("\((task.repo as NSString).lastPathComponent) · \(task.branch)")
                    .font(F.mono(10.5))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                // Freeform card: it has no repo/branch — show the borrowed dir name instead.
                Text((task.cwd as NSString).lastPathComponent)
                    .font(F.mono(10.5))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if task.access == .readOnly {
                Image(systemName: "eye")
                    .font(F.ui(9))
                    .foregroundStyle(theme.text3)
                    .help("Read-only")
            }
            worktreeBadge
            Spacer(minLength: 6)
            meta
                .frame(maxWidth: 148, alignment: .trailing)
        }
        .padding(.top, 11)
    }

    /// Passive count of other agents sharing this card's worktree. Hover lists their ids; opening the
    /// card's inspector exposes the clickable jump-to-sibling list. Hidden when the worktree is solo.
    @ViewBuilder private var worktreeBadge: some View {
        let siblings = model.worktreeSiblings(of: task)
        if !siblings.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").font(F.ui(8.5))
                Text("\(siblings.count)").font(F.mono(10, .medium))
            }
            .foregroundStyle(theme.text3)
            .help(model.worktreeSiblingsHelp(of: task))
        }
    }

    /// Right-side meta: the branch diffstat (`k files · +N −M`) when the daemon has computed one for a
    /// git card (axis 7 — code review on the board); otherwise the selected model. Zero-change / non-git
    /// cards carry no `diffStat`, so they fall back to the model name rather than fabricate a stat.
    @ViewBuilder private var meta: some View {
        if let stat = task.diffStat, stat.filesChanged > 0 {
            HStack(spacing: 5) {
                Text("\(stat.filesChanged)f").foregroundStyle(theme.text3)
                Text("+\(stat.insertions)").foregroundStyle(theme.green.text)
                Text("−\(stat.deletions)").foregroundStyle(theme.red.text)
            }
            .font(F.mono(10.5, .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .help("\(stat.filesChanged) files changed · +\(stat.insertions) −\(stat.deletions)")
        } else if !task.model.id.isEmpty {
            Text(task.model.displayName)
                .font(F.mono(10.5, .medium))
                .foregroundStyle(theme.text2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: - Age formatting

    private func relativeAge(_ date: Date, now: Date = Date()) -> String {
        let s = Int(max(0, now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        return "\(h / 24)d"
    }
}

// MARK: - Helpers

/// A breathing pulse dot (ccPulse: opacity 1↔.35, scale 1↔.78).
private struct BreathingDot: View {
    let color: Color
    let size: CGFloat
    var active: Bool
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(active ? (on ? 0.35 : 1) : 1)
            .scaleEffect(active ? (on ? 0.78 : 1) : 1)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

/// A 2px running shimmer bar: transparent → green → transparent, sweeping horizontally.
private struct ShimmerBar: View {
    let color: Color
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [color.opacity(0), color, color.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width)
            .opacity(0.9)
            .offset(x: phase * geo.size.width)
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
    }
}
