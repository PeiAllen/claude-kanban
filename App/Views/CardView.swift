import SwiftUI
import OrchestraUI
import OrchestraCore

/// A single board card (ui-spec §3.4, §4.3).
struct CardView: View {
    let task: OrchestraCore.Task

    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    /// Transient state for the id watermark: the post-copy checkmark flash, the pointer being over
    /// the card (which wakes the id), and over the id itself (which fills its chip).
    @State private var idCopied = false
    @State private var idHover = false
    @State private var cardHover = false

    private var isSelected: Bool { model.selectedId == task.id }
    private var ds: DisplayState { displayState(phase: task.phase, connection: model.connectionState) }
    private var display: PhaseDisplayKey { ds.statusKey }
    private var sem: SemColor { theme.statusColor(ds.statusKey) }
    private var isRunning: Bool { display == .running }
    private var isWaiting: Bool { task.waitReason != nil }
    private var isDead: Bool { display == .dead }

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
        .opacity(dimmed ? 0.32 : ((isDead || ds.isStale) ? 0.72 : 1))
        .overlay(alignment: .topLeading) { hintBadge }
        .overlay(alignment: .topTrailing) { idBadge }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { cardHover = $0 }
        // Clicking a card selects it AND descends into its agent terminal, so the glow, the
        // inspector ring, and the real keyboard first responder all agree after the click.
        .onTapGesture { model.selectAndEnterTerminal(task.id) }
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

    // MARK: - Card reference watermark

    /// The card's short id (`shortId`), tucked into the opposite corner from the `f` hint badge. At
    /// rest it's a watermark: faint enough that the eye skips it while scanning the board. Hovering
    /// *the card* (not just the id) brings it to full contrast and grows the copy affordance leftward,
    /// so the id itself never moves. Click copies the card's short Orchestra URI; `y i` yanks the
    /// selected card's reference the same way.
    private var idBadge: some View {
        Button {
            model.copy(.id, of: task)
            idCopied = true
            _Concurrency.Task {
                try? await _Concurrency.Task.sleep(nanoseconds: 1_200_000_000)
                idCopied = false
            }
        } label: {
            HStack(spacing: 3) {
                // Trailing-anchored, so this only ever grows to the left — the id stays put.
                if awake {
                    Image(systemName: idCopied ? "checkmark" : "doc.on.doc")
                        .font(F.ui(8))
                }
                Text("#\(task.shortId)")
                    .font(F.mono(9.5, .medium))
                    .tracking(0.2)
            }
            .foregroundStyle(idCopied ? theme.green.dot : theme.text3)
            .opacity(awake ? 1 : 0.45)
            .padding(.horizontal, 4)
            .frame(height: 15)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(idHover ? theme.chip : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { idHover = $0 }
        .help(idCopied ? "Copied!" : "Copy card reference — \(task.ref(slugging: false))")
        .padding(.top, 7)
        .padding(.trailing, 7)
        .animation(.easeOut(duration: 0.12), value: awake)
    }

    /// The id is lit — the pointer is anywhere on the card, or a copy just landed.
    private var awake: Bool { cardHover || idCopied }

    // MARK: - Status pill

    @ViewBuilder private var statusPill: some View {
        if isRunning || isWaiting {
            // Live age: re-render the label once a second so "Running · 3s" actually ticks.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                pill(ds.label + " · " + relativeAge(task.updatedAt, now: ctx.date))
            }
        } else {
            pill(ds.label)
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
            parentChip
            worktreeBadge
            AttachedAgentsBadge(task: task)
            treeBadge
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

    /// Parent-branch chip: shows `⤴ <parent>` whenever the card has a parent branch. Clicking jumps to
    /// the live parent card (select + enter its terminal); a no-op with an explanatory tooltip when no
    /// live card owns that branch. Reads `Task` + the store's derived lookup — no new plumbing.
    @ViewBuilder private var parentChip: some View {
        if let parent = task.parentBranch {
            let target = model.parentCard(of: task)
            Button {
                // S3-3: select-only — a "look at my parent" chip shouldn't enter the parent's terminal
                // (a heavier action than the chip implies; matches iOS's lighter push).
                if let target { model.selectedId = target.id }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.turn.left.up").font(F.ui(8))
                    Text(parent).font(F.mono(9.5)).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(target != nil ? theme.accent : theme.text3)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule(style: .continuous).fill(theme.chip))
            }
            .buttonStyle(.plain)
            .disabled(target == nil)
            .frame(maxWidth: 120, alignment: .leading)
            .help(target != nil
                  ? "Select the parent card on \(parent)"
                  : "No live card on parent branch \(parent)")
        }
    }

    /// Lineage status (branch-tree): `↓N` when the parent has advanced past the recorded base (stale),
    /// a restack glyph when the branch needs re-basing (parent rewrote/shipped). Styled like the diffstat
    /// pill; hidden when in-sync or untracked (`treeStat == nil`). Reads `Task` directly — no store plumbing.
    @ViewBuilder private var treeBadge: some View {
        if let ts = task.treeStat {
            // The give-up flag outranks the tracking state: a stalled card still computes stale/↓N underneath,
            // but "nobody answered the merge-request" is what the human needs to see first.
            if ts.mergeStalled {
                Image(systemName: "exclamationmark.triangle.fill").font(F.ui(8.5))
                    .foregroundStyle(theme.red.text)
                    .help("Merge-request unanswered — \(ts.nudges) reminders sent and \(task.parentBranch ?? "the parent") "
                          + "never merged this branch. Merge it yourself, or re-send the merge-request.")
            } else {
                switch ts.state {
                case .stale:
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down").font(F.ui(8.5))
                        Text("\(ts.behind)").font(F.mono(10, .medium))
                    }
                    .foregroundStyle(theme.amber.text)
                    .help("Parent branch is \(ts.behind) commit\(ts.behind == 1 ? "" : "s") ahead of this card — the agent will merge it down")
                case .restackNeeded:
                    Image(systemName: "arrow.triangle.2.circlepath").font(F.ui(8.5))
                        .foregroundStyle(theme.red.text)
                        .help("Parent branch's history changed (rebased/shipped) — the agent will restack this branch onto it")
                case .mergeRequested:
                    Image(systemName: "clock.arrow.circlepath").font(F.ui(8.5))
                        .foregroundStyle(theme.amber.text)
                        .help("Merge requested — waiting for the parent card to squash-merge this branch")
                case .inSync:
                    EmptyView()
                }
            }
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
