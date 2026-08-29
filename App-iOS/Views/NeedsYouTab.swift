import SwiftUI
import Combine       // Timer.publish / .autoconnect for the render clock
import OrchestraKit
import OrchestraUI

/// The **Needs You** attention queue (design §6), re-homed (BT slice 5) onto the 3b `ownAttention` fold —
/// the SAME definition of "needs you" the card L1/L4 chips, peek rows, and eye tint use. Each row shows
/// the card's own reasons with their labels; the top (most hard-blocked) reason drives the row's section,
/// color, and primary action — Approve/Deny (🔐), a quick reply (🙋 `send`), Recover (💀), or Open (the
/// rest). Background-waiting cards never appear (they hold no reason). Membership is time-derived (a card
/// stalls with no daemon traffic), so the tab ticks a `now`.
struct NeedsYouTab: View {
    @EnvironmentObject private var model: BoardModel
    @EnvironmentObject private var snooze: NeedsYouSnooze
    @EnvironmentObject private var push: PushCoordinator
    @Environment(\.colorScheme) private var scheme
    @State private var route: NeedsYouRoute?
    /// The render clock. The stall reason crosses its threshold with no broadcast, so the queue must tick
    /// rather than wait for a daemon event. 15s is well under the ~12-min stall window.
    @State private var now = Date()
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var theme: Theme { Theme(scheme: scheme, accent: model.accent) }

    /// The FULL attention set, before the snooze filter. `reconcile` keys on THIS, not `items`: a snoozed
    /// card is dropped from `items`, so reconciling against `items` would read the snooze as "resolved" and
    /// prune the very entry the tap just set — self-cancelling Snooze/Dismiss on the next render. Keying on
    /// the unsnoozed set prunes a snooze only when the card genuinely leaves the fold (plan spec).
    private var allRows: [NeedsYouRow] { model.needsYouRows(now: now) }
    /// The live queue with snoozed rows removed. Recomputes as the board changes and as `now` ticks.
    private var items: [NeedsYouRow] { snooze.visible(allRows) }

    /// Group into reason sections once the flat list gets long (design §6: "Grouped by reason when the
    /// list is long"); a short queue reads better flat. Buckets by the row's TOP reason.
    private var grouped: [(reason: Attention.Reason, items: [NeedsYouRow])] {
        Attention.Reason.allCases.compactMap { r in
            let xs = items.filter { $0.topReason == r }
            return xs.isEmpty ? nil : (r, xs)
        }
    }
    private var shouldGroup: Bool { items.count > 5 && grouped.count > 1 }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    EmptyQueue()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if shouldGroup {
                                ForEach(grouped, id: \.reason) { section in
                                    ReasonHeader(reason: section.reason, count: section.items.count)
                                        .padding(.top, 4)
                                    ForEach(section.items) { row($0) }
                                }
                            } else {
                                ForEach(items) { row($0) }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.winBg.ignoresSafeArea())
            .navigationTitle("Needs You")
            .navigationDestination(item: $route) { route in
                switch route {
                case .peek(let id):
                    CardDetailView(taskId: id)
                case .recover(let id):
                    if let task = card(id) {
                        RecoveryView(task: task)
                            .navigationTitle("Recovery")
                            .navigationBarTitleDisplayMode(.inline)
                    } else {
                        CardGone()
                    }
                }
            }
        }
        .environment(\.theme, theme)
        .onReceive(tick) { now = $0 }
        // Prune stale snoozes whenever the attention set changes so a resolved-then-re-alerting card
        // isn't left suppressed.
        .onChange(of: allRows.map(\.id)) { _, ids in
            snooze.reconcile(activeIds: Set(ids))
        }
        // A tapped push deep-links here: open the pushed card (Recovery for a died card, else the peek).
        .onChange(of: push.pendingCardId) { _, id in openDeepLink(id) }
        .onAppear { openDeepLink(push.pendingCardId) }
    }

    /// Route a push deep-link to the right destination, then clear it so it doesn't re-fire.
    private func openDeepLink(_ id: UUID?) {
        guard let id else { return }
        route = NeedsYouRoute.deepLink(cardId: id, display: card(id)?.phaseDisplay)
        push.consumeDeepLink()
    }

    private func row(_ item: NeedsYouRow) -> some View {
        AttentionRow(item: item, onOpen: { route = .peek(item.id) },
                     onRecover: { route = .recover(item.id) })
    }

    /// Look up the (possibly since-changed) card for a pushed destination.
    private func card(_ id: UUID) -> Task? { (model.tasks + model.archived).first { $0.id == id } }
}

/// Programmatic pushes out of the queue. Keyed by card id (Hashable) so a single
/// `navigationDestination(item:)` covers both routes without a type collision.
enum NeedsYouRoute: Hashable, Identifiable {
    case peek(UUID)      // "Open card" → the tabbed card detail (`CardDetailView`)
    case recover(UUID)   // "Recover" (died) → the Recovery view (`RecoveryView`)
    var id: Self { self }

    /// The destination a push deep-link opens for a card: a died card goes to Recovery (matching the
    /// row's own action), everything else to the peek. Pure so the routing is unit-testable (N1 gate).
    static func deepLink(cardId: UUID, display: PhaseDisplayKey?) -> NeedsYouRoute {
        display == .dead ? .recover(cardId) : .peek(cardId)
    }
}

// MARK: - reason → UI (the ONE fold's reasons, given phone chrome)

extension Attention.Reason {
    /// The reason chip glyph.
    var emoji: String {
        switch self {
        case .dead:           return "💀"
        case .permission:     return "🔐"
        case .mergeRequested: return "🔀"
        case .question:       return "🙋"
        case .stalled:        return "⏱"
        case .ctxCritical:    return "◔"
        }
    }
    /// The section-bucket name (grouped mode). Row chips show the signal's own `label` instead.
    var bucketName: String {
        switch self {
        case .dead:           return "Died"
        case .permission:     return "Permission"
        case .mergeRequested: return "Merge"
        case .question:       return "Question"
        case .stalled:        return "Stalled"
        case .ctxCritical:    return "Context"
        }
    }
    func sem(_ theme: Theme) -> SemColor {
        switch self {
        case .dead:           return theme.red
        case .permission:     return theme.amber
        case .mergeRequested: return theme.amber
        case .question:       return theme.blue
        case .stalled:        return theme.amber
        case .ctxCritical:    return theme.indigo
        }
    }
}

// MARK: - Empty state

private struct EmptyQueue: View {
    var body: some View {
        ContentUnavailableView {
            Label("All caught up", systemImage: "checkmark.circle")
        } description: {
            Text("No agents need you. Cards on background tasks keep running and never wait here.")
        }
    }
}

// MARK: - Section header (grouped mode)

private struct ReasonHeader: View {
    let reason: Attention.Reason
    let count: Int
    @Environment(\.theme) private var theme: Theme
    var body: some View {
        HStack(spacing: 6) {
            Text(reason.emoji)
            Text(reason.bucketName).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
                .chipText()
            Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(theme.text2)
                .chipText()
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(theme.chip))
            Spacer()
        }
    }
}

// MARK: - One attention row

/// A single queue row: the top reason chip + all reason labels, title, `repo/branch`, last activity,
/// waiting age, and the inline action(s) matched to the top reason. Its own `View` so the reply field /
/// in-flight state stay local to the row.
private struct AttentionRow: View {
    let item: NeedsYouRow
    let onOpen: () -> Void
    let onRecover: () -> Void

    @EnvironmentObject private var model: BoardModel
    @EnvironmentObject private var snooze: NeedsYouSnooze
    @Environment(\.theme) private var theme: Theme

    @State private var replying = false
    @State private var draft = ""
    @State private var busy = false          // guards the async gate/reply so a double-tap can't double-fire
    @FocusState private var replyFocused: Bool
    @Environment(\.animationsActive) private var animationsActive

    private var task: Task { item.task }
    private var top: Attention.Reason { item.topReason }
    private var sem: SemColor { top.sem(theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(task.title)
                .font(.headline).foregroundStyle(theme.text)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("\((task.repo as NSString).lastPathComponent)/\(task.branch)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.text2).lineLimit(1).truncationMode(.middle)
                if task.ctxPct > 0 {
                    Spacer(minLength: 6)
                    Text("ctx \(Int(task.ctxPct))%")
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(task.ctxPct >= Attention.Thresholds().ctxCriticalPct ? sem.text : theme.text3)
                }
            }
            // Precedence FLIPS here, deliberately. Everywhere else the authored note wins because `desc`
            // is blank between turns — but a Needs-You row is by construction mid-turn and blocked, and
            // `desc` is the agent's own "may I run this?" text. Showing the note would hide the question.
            let line = task.desc.isEmpty ? (task.note ?? "") : task.desc
            if !line.isEmpty {
                Text(line)
                    .font(.subheadline).foregroundStyle(theme.text2)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            actions
            if replying { replyField }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(sem.tint, lineWidth: 1))
        .shadow(color: theme.shadowCard, radius: 3, x: 0, y: 1)
        .opacity(task.phaseDisplay == .dead ? 0.85 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }

    // MARK: header — every reason label as a chip + waiting age

    private var header: some View {
        HStack(spacing: 6) {
            // ALL the card's own reasons, most-urgent first (design: "own reasons listed with labels").
            // The first is the top; the rest render dimmer so the primary reason still reads.
            ForEach(Array(item.signals.enumerated()), id: \.offset) { idx, signal in
                ReasonChip(reason: signal.reason, label: signal.label,
                           sem: signal.reason.sem(theme), primary: idx == 0)
            }
            Spacer(minLength: 4)
            // How long it has been waiting — coarsens after the first minute, pauses when backgrounded.
            TimelineView(PausableTimelineSchedule(.periodic(from: .now, by: ageRefreshInterval(task.updatedAt)),
                                                  paused: !animationsActive)) { ctx in
                Text(waitingLabel + relativeAge(task.updatedAt, now: ctx.date))
                    .font(.caption2.weight(.medium)).foregroundStyle(theme.text3).monospacedDigit()
            }
        }
    }
    /// Honest age prefix per status — a context-full card is still *running*, not waiting.
    private var waitingLabel: String {
        switch task.phaseDisplay {
        case .dead:        return "Died "
        case .running:     return "Running "
        case .unavailable: return "Unavailable "
        default:           return "Waiting "
        }
    }

    // MARK: actions — matched to the TOP reason

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch top {
            case .permission:
                ActionButton("Approve", systemImage: "checkmark", tint: theme.green, filled: true, busy: busy) {
                    run { await model.approvePermission(task.id) }
                }
                ActionButton("Deny", systemImage: "xmark", tint: theme.red) {
                    run { await model.denyPermission(task.id) }
                }
            case .question:
                if task.agentState?.hasRequest(kind: .input) == true {
                    // A provider input box is already open inside the live terminal; an inbox reply would
                    // arrive at the next turn boundary, too late to answer it.
                    ActionButton("Open", systemImage: "arrow.up.forward.square", tint: theme.blue) { onOpen() }
                } else {
                    ActionButton("Reply", systemImage: "text.bubble", tint: theme.blue) {
                        withAnimation { replying.toggle() }
                        if replying { replyFocused = true }
                    }
                }
            case .dead:
                ActionButton("Recover", systemImage: "cross.case", tint: theme.red, filled: true) { onRecover() }
            case .mergeRequested, .stalled, .ctxCritical:
                // Look at the card — no gate/reply fits (approve a merge, nudge a stall, hand off context).
                ActionButton("Open", systemImage: "arrow.up.forward.square", tint: sem) { onOpen() }
            }
            Spacer(minLength: 0)
            overflow
        }
        .disabled(busy)
    }

    /// The always-present secondary menu: open the card, snooze, dismiss.
    private var overflow: some View {
        Menu {
            Button { onOpen() } label: { Label("Open card", systemImage: "rectangle.stack") }
            Menu {
                ForEach(NeedsYouSnooze.options, id: \.label) { opt in
                    Button(opt.label) { withAnimation { snooze.snooze(task.id, for: opt.interval) } }
                }
            } label: { Label("Snooze", systemImage: "clock") }
            Button(role: .destructive) { withAnimation { snooze.dismiss(task.id) } } label: {
                Label("Dismiss", systemImage: "bell.slash")
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.body).foregroundStyle(theme.text2)
                .frame(width: 32, height: 28)
        }
        .accessibilityLabel("More actions")
    }

    // MARK: inline reply (question rows) — drives the `send` RPC

    private var replyField: some View {
        HStack(spacing: 8) {
            TextField("Reply to the agent…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($replyFocused)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.chip))
                .onSubmit(sendReply)
            Button(action: sendReply) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
                    .foregroundStyle(draft.trimmed.isEmpty ? theme.text3 : theme.blue.dot)
            }
            .disabled(draft.trimmed.isEmpty || busy)
        }
        .padding(.top, 2)
    }

    private func sendReply() {
        let text = draft.trimmed
        guard !text.isEmpty else { return }
        run {
            await model.send(task.id, text)
        } then: {
            draft = ""
            withAnimation { replying = false }
        }
    }

    /// Run an async action guarded by `busy` (so the button can't double-fire), then an optional
    /// main-actor completion.
    private func run(_ action: @escaping () async -> Void, then done: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        _Concurrency.Task {
            await action()
            busy = false
            done?()
        }
    }
}

// MARK: - Small pieces

/// The reason chip (emoji + the signal's own label) in the reason's semantic color. The top reason is
/// filled/tinted; secondary reasons render outlined so the primary still leads.
private struct ReasonChip: View {
    let reason: Attention.Reason
    let label: String
    let sem: SemColor
    var primary: Bool = true
    var body: some View {
        HStack(spacing: 4) {
            Text(reason.emoji)
            Text(label)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(sem.text)
        // A row can carry several of these; without an intrinsic size they squeeze each other and wrap
        // their labels into tall towers, inflating the row.
        .chipText()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(primary ? sem.tint : Color.clear))
        .overlay(primary ? nil : Capsule().strokeBorder(sem.tint, lineWidth: 1))
    }
}

/// A compact inline action button — filled (primary) or tinted-outline (secondary).
private struct ActionButton: View {
    let title: String
    let systemImage: String
    let tint: SemColor
    var filled = false
    var busy = false
    let action: () -> Void
    init(_ title: String, systemImage: String, tint: SemColor,
         filled: Bool = false, busy: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.tint = tint
        self.filled = filled; self.busy = busy; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy { ProgressView().controlSize(.mini) }
                else { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(filled ? Color.white : tint.text)
            .chipText()                 // "Approve"/"Recover" must never wrap when two buttons share a row
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                Capsule().fill(filled ? tint.dot : tint.tint)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pushed destinations (nav hooks)

/// Shown when a `.recover` route resolves and the card has since left the board — the peek route relies on
/// `CardDetailView`'s own closed-state placeholder instead.
private struct CardGone: View {
    @Environment(\.theme) private var theme: Theme
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(theme.green.dot)
            Text("This card no longer needs you.").foregroundStyle(theme.text2)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.winBg.ignoresSafeArea())
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
    }
}
