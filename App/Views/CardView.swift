import SwiftUI
import OrchestraUI
import OrchestraCore

/// A single board card, in four lines (ui-spec §3.4, §4.3):
///
/// * **L1 — status strip:** the status pill (the card's OWN lifecycle: tinted wash, state word,
///   time-in-state, breathing dot) with the quiet cluster right-aligned beside it — diffstat,
///   treeStat glyph, model. Width pressure is resolved by `CardL1Layout`'s ordered drop, not by
///   whichever text truncates first.
/// * **L2 — identity:** the card's name on its own uncontested line, with a muted source prefix
///   only while the board holds more than one repo.
/// * **L3 — context:** `note ?? desc`, one line, with the card ref at its right end.
/// * **L4 — subtree:** the attached-agents summary, when there is one and the card isn't expanded.
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

    /// One of this card's attached rows is selected (the card itself isn't). Keeps a retained cue on the
    /// parent so "which card am I in" stays legible while `↑`/`↓` walk its rows.
    private var rowSelectedInGroup: Bool { !isSelected && model.revealsAttached(task) }

    private var borderColor: Color {
        if isSelected { return theme.accent }
        if rowSelectedInGroup { return theme.accent.opacity(0.5) }
        if isWaiting { return theme.waitingBorder }
        return theme.cardBorder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusStrip
            identityLine
            contextLine
            subtreeLine
            attachedRows
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
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Double-click a root that has a subtree to drill in — the folder-open idiom, same re-scope
        // as `→`. Only attached where it can act: registering a count-2 handler makes SwiftUI stall
        // every single click to see if a second lands, so leaf cards keep an undelayed select.
        .drillOnDoubleClick(enabled: model.hasLineageChildren(task)) { enterDrill() }
        .onHover { cardHover = $0 }
        // Clicking a card selects it AND descends into its agent terminal, so the glow, the
        // inspector ring, and the real keyboard first responder all agree after the click.
        .onTapGesture { model.selectAndEnterTerminal(task.id) }
    }

    /// Re-scope the board to this card's subtree — the shared path `→` and the drill affordances take.
    /// Select the root first: `→` only ever fires with the root already selected (you selected it to
    /// press the key), but a chip-click / double-click suppresses the card's own select, so without this
    /// a mouse-drill would re-scope while the inspector still showed a now-out-of-scope card and no board
    /// card was selected. Selecting the anchor keeps parity and lights the banner's "you're here" border.
    private func enterDrill() {
        let anchor = model.cardLevelAnchor(task.id)
        model.selectedId = anchor
        model.drillInto(anchor)
        model.focusZone = .board
    }

    /// Dim when a `/` search is active and this card neither matches NOR hosts a matching attached row —
    /// a host stays bright so its revealed reviewer match is visible in place.
    private var dimmed: Bool {
        model.searchActive && !model.isSearchMatch(task) && !model.revealsSearchMatchRow(task)
    }

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

    // MARK: - L1 · status strip (pill + quiet cluster)

    /// The pill and the quiet cluster share one line, because a card's state and the quiet facts
    /// about it are the same kind of information. When the line runs short, `CardL1Layout` decides
    /// what goes and in what order; `ViewThatFits` only measures, picking the first rung that fits.
    ///
    /// The `TimelineView` is deliberately OUTSIDE `ViewThatFits`: inside, every one of the five
    /// measured candidates would run its own 1 Hz schedule, and the winning rung could be chosen
    /// against labels rendered at different instants. Live cards tick every second (seconds are
    /// meaningful there); everything else ticks once a minute, which is all its age can change.
    private var statusStrip: some View {
        // Cadence follows the AGE, not the phase: 1 Hz while the stamp still reads in seconds, then
        // once a minute. Keying it off `isRunning || isWaiting` left a just-spawned or just-dead card
        // frozen at "· 0s" for its whole first minute — its age is in seconds too.
        TimelineView(.periodic(from: .now, by: ageRefreshInterval(task.phaseChangedAt))) { ctx in
            ViewThatFits(in: .horizontal) {
                strip(CardL1Layout.rung(dropping: 0), now: ctx.date)
                strip(CardL1Layout.rung(dropping: 1), now: ctx.date)
                strip(CardL1Layout.rung(dropping: 2), now: ctx.date)
                strip(CardL1Layout.rung(dropping: 3), now: ctx.date)
                strip(CardL1Layout.rung(dropping: 4), now: ctx.date)
            }
        }
    }

    private func strip(_ rung: L1Rung, now: Date) -> some View {
        HStack(spacing: 0) {
            pill(rung, now: now)
            Spacer(minLength: 8)
            quietCluster(rung)
        }
    }

    /// The status pill. Its dot and its time-in-state never drop — under full squish the pill IS
    /// "● 47m", which still carries the state in the dot's colour. The age is time-in-state
    /// (`phaseChangedAt`), not last-touched: a report tick moves `updatedAt`, which would reset the
    /// very number "Waiting · 10h" exists to show.
    private func pill(_ rung: L1Rung, now: Date) -> some View {
        let age = relativeAge(task.phaseChangedAt, now: now)
        return HStack(spacing: 6) {
            BreathingDot(color: sem.dot, size: 6, active: isRunning || isWaiting)
            Text(rung.showsStateWord ? "\(ds.label) · \(age)" : age)
                .font(F.ui(10.5, .semibold))
                .tracking(0.0525)
                .foregroundStyle(sem.text)
        }
        .padding(.init(top: 3, leading: 7, bottom: 3, trailing: 8))
        .background(Capsule(style: .continuous).fill(sem.tint))
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Quiet facts about THIS card, in the order you'd act on them: how big the change is, whether
    /// the branch is behind its parent, which model is driving. Muted throughout — saturated colour
    /// on a board card means "needs you", and none of these do.
    @ViewBuilder private func quietCluster(_ rung: L1Rung) -> some View {
        HStack(spacing: 9) {
            if rung.showsDiffstat, let stat = task.diffStat, stat.filesChanged > 0 {
                DiffStatNumbers(stat: stat)
                    .help(diffStatHelp(stat))
            }
            if rung.showsTreeGlyph { treeGlyph }
            if rung.showsModel, !task.model.id.isEmpty {
                Text(task.model.displayName)
                    .font(F.mono(10, .medium))
                    .foregroundStyle(theme.text3)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 0.5)
                    .background(Capsule(style: .continuous).fill(theme.chip))
                    .help("Model — \(task.model.displayName)")
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// Lineage status against the parent branch, in ONE slot. The glyphs and their help text live in
    /// `TreeBadge`, shared with the inspector header so the two surfaces can't drift.
    @ViewBuilder private var treeGlyph: some View {
        if let ts = task.treeStat {
            TreeBadge(stat: ts, parentBranch: task.parentBranch)
        }
    }

    // MARK: - L2 · identity

    /// The card's name, uncontested: nothing on this line competes with it for width. The source
    /// prefix appears only while the board holds more than one repo (`BoardStore.repoPrefix`), and
    /// the ref rides here only when there is no context line below to carry it.
    private var identityLine: some View {
        HStack(alignment: .lastTextBaseline, spacing: 5) {
            // The prefix and the title are ONE text run, not two views: as separate views the prefix
            // got its own truncation ("orchest… live-wake-delivery") and, once the title wrapped,
            // sat beside the title's LAST line instead of leading its first. Concatenated, they flow
            // as a single paragraph — the prefix always leads, and only the title's tail is ever lost.
            (identityPrefix + Text(task.title)
                .font(F.ui(model.density.cardTitle, .semibold))
                .foregroundStyle(theme.text))
                .tracking(-0.135)
                .lineSpacing(model.density.cardTitle * 0.32)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            if task.cardLine.isEmpty {
                Spacer(minLength: 6)
                idBadge
            }
        }
        .padding(.top, 7)
    }

    /// `repo · ` ahead of the title, or nothing at all on an unambiguous board.
    private var identityPrefix: Text {
        guard let prefix = model.repoPrefix(of: task) else { return Text("") }
        return Text("\(prefix) · ")
            .font(F.ui(model.density.cardTitle - 1.5))
            .foregroundColor(theme.text3)
    }

    // MARK: - L3 · context

    /// `note ?? desc` — the authored line wins over the volatile status blurb (`Task.cardLine`) —
    /// with the ref at its right end. The ref holds its slot (`layoutPriority`), so the context
    /// truncates before the ref ever moves.
    @ViewBuilder private var contextLine: some View {
        if !task.cardLine.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(task.cardLine)
                    .font(F.ui(11.5))
                    .foregroundStyle(isWaiting ? theme.amber.text : theme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                idBadge.layoutPriority(1)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Card reference

    /// The card's short id, at the right end of the card's last content line. At rest it's a
    /// watermark: faint enough that the eye skips it while scanning the board. Hovering *the card*
    /// (not just the id) brings it to full contrast and lights the copy affordance — which keeps
    /// its slot in the layout at all times, so waking it can never re-truncate the line beside it.
    /// Click copies the card's short Orchestra URI; `y i` yanks the selected card's the same way.
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
                Image(systemName: idCopied ? "checkmark" : "doc.on.doc")
                    .font(F.ui(8))
                    .opacity(awake ? 1 : 0)
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
        .fixedSize()
        .onHover { idHover = $0 }
        .help(idCopied ? "Copied!" : "Copy card reference — \(task.ref(slugging: false))")
        .animation(.easeOut(duration: 0.12), value: awake)
    }

    /// The id is lit — the pointer is anywhere on the card, or a copy just landed.
    private var awake: Bool { cardHover || idCopied }

    // MARK: - L4 · subtree line

    /// The card's subordinates, summarised: stage-coloured segments (one per live lineage child, plus the
    /// merged-green / dashed-planned slots the daemon counters carry) and the attached-agents eye
    /// (`SubtreeSegments`). Shown whenever the card has a live subordinate OR non-zero progress counters —
    /// so a root that has already SHIPPED all its children (no live subordinate, but `mergedChildren > 0`)
    /// keeps its progress bar — and isn't currently expanded; it gives way to the peek rows once the card
    /// (or a descendant) is selected, so the summary and the detail never show at once.
    private var hasProgressCounters: Bool {
        guard let ts = task.treeStat else { return false }
        return ts.mergedChildren > 0 || ts.plannedChildren > 0
    }
    @ViewBuilder private var subtreeLine: some View {
        if (!model.subordinates(of: task).isEmpty || hasProgressCounters), model.peekRows(of: task).isEmpty {
            Rectangle().fill(theme.hair).frame(height: 0.5).padding(.top, 9)
            HStack(spacing: 8) {
                SubtreeSegments(root: task)
                drillChevron
            }
            .padding(.top, 6)
        }
    }

    /// The mouse path into the subtree: a "drill ›" chip riding the L4 line's reserved trailing slot,
    /// shown only on cards that actually have a subtree to enter (`hasLineageChildren` — the same gate
    /// `→` obeys). Like the id watermark it's a faint watermark at rest — enough to be found, since the
    /// whole gap is that drill was invisible — and brightens when the pointer is on the card. Its
    /// tooltip names the key so the click teaches the keyboard, and its slot never reflows the segments.
    @ViewBuilder private var drillChevron: some View {
        if model.hasLineageChildren(task) {
            Button(action: enterDrill) {
                HStack(spacing: 2) {
                    Text("drill").font(F.ui(8.5, .semibold)).tracking(0.2)
                    Image(systemName: "chevron.right").font(F.ui(8, .bold))
                }
                .foregroundStyle(theme.text3)
                .opacity(cardHover ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Drill into subtree — →")
            .animation(.easeOut(duration: 0.12), value: cardHover)
        }
    }

    // MARK: - Attached-agent rows (inline accordion)

    /// The card's subordinates — lineage children AND attached reviewers — revealed as compact peek rows
    /// INSIDE the card's frame when the card (or one of its descendants) is selected. `peekRows` carries
    /// the reveal + `/`-search gate and the one-level-deeper indent depth, so this is empty (and the card
    /// renders as today) whenever it shouldn't expand.
    @ViewBuilder private var attachedRows: some View {
        let rows = model.peekRows(of: task)
        if !rows.isEmpty {
            Rectangle().fill(theme.hair).frame(height: 0.5).padding(.top, 9)
            VStack(spacing: 2) {
                ForEach(rows, id: \.task.id) { row in PeekRow(task: row.task, depth: row.depth) }
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - Helpers

private extension View {
    /// Attach double-click-to-drill only where a subtree exists. A count-2 tap gesture forces SwiftUI
    /// to defer every single click on that view (waiting for a possible second), so we pay that cost
    /// only on drillable roots and leave leaf cards' single-click selection instant.
    @ViewBuilder func drillOnDoubleClick(enabled: Bool, _ action: @escaping () -> Void) -> some View {
        if enabled { self.onTapGesture(count: 2, perform: action) } else { self }
    }
}

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
