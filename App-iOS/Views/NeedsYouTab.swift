import SwiftUI
import OrchestraKit
import OrchestraUI

/// The **Needs You** attention queue (design §6): the cards blocked on the human, most-urgent-first,
/// off the shared `BoardModel`. Each row carries a reason chip aligned to a real daemon signal
/// (🔐 Permission · 🙋 Needs you · 💀 Died · ◔ Context near-full) and the inline action matched to it —
/// Approve/Deny (via the shipped `send-keys` RPC), a quick reply (`send`), or a deep-link to Recovery.
/// Background-waiting cards never appear (they stay `.running`; see `NeedsYouQueue`). Replaces F3's stub.
struct NeedsYouTab: View {
    @EnvironmentObject private var model: BoardModel
    @EnvironmentObject private var snooze: NeedsYouSnooze
    @Environment(\.colorScheme) private var scheme
    @State private var route: NeedsYouRoute?

    private var theme: Theme { Theme(scheme: scheme, accent: model.accent) }

    /// The live queue with snoozed rows removed. `updatedAt` ticks in `Task`, so this recomputes as the
    /// board changes.
    private var items: [AttentionItem] { snooze.visible(model.needsYouItems) }

    /// Group into reason sections once the flat list gets long (design §6: "Grouped by reason when the
    /// list is long"); a short queue reads better flat.
    private var grouped: [(reason: AttentionReason, items: [AttentionItem])] {
        AttentionReason.allCases.compactMap { r in
            let xs = items.filter { $0.reason == r }
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
                case .peek(let id):    CardPeekView(task: card(id))
                case .recover(let id): RecoveryPlaceholder(task: card(id))
                }
            }
        }
        .environment(\.theme, theme)
        // Prune stale snoozes whenever the attention set changes so a resolved-then-re-alerting card
        // isn't left suppressed.
        .onChange(of: model.needsYouItems.map(\.id)) { _, ids in
            snooze.reconcile(activeIds: Set(ids))
        }
    }

    private func row(_ item: AttentionItem) -> some View {
        AttentionRow(item: item, onOpen: { route = .peek(item.id) },
                     onRecover: { route = .recover(item.id) })
    }

    /// Look up the (possibly since-changed) card for a pushed destination.
    private func card(_ id: UUID) -> Task? { (model.tasks + model.archived).first { $0.id == id } }
}

/// Programmatic pushes out of the queue. Keyed by card id (Hashable) so a single
/// `navigationDestination(item:)` covers both routes without a type collision.
enum NeedsYouRoute: Hashable, Identifiable {
    case peek(UUID)      // "Open card" → a read-only summary (full detail is M2's card-detail)
    case recover(UUID)   // "Recover" (died) → the Recovery view (M7 nav hook)
    var id: Self { self }
}

// MARK: - Empty state

private struct EmptyQueue: View {
    var body: some View {
        ContentUnavailableView {
            Label("All caught up", systemImage: "checkmark.circle")
        } description: {
            // The queue notes its own scope so an empty list reads as "genuinely nothing," not
            // "the signal is broken" (design §6).
            Text("No agents need you. Cards on background tasks keep running and never wait here.")
        }
    }
}

// MARK: - Section header (grouped mode)

private struct ReasonHeader: View {
    let reason: AttentionReason
    let count: Int
    @Environment(\.theme) private var theme: Theme
    var body: some View {
        HStack(spacing: 6) {
            Text(reason.emoji)
            Text(reason.label).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
            Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(theme.text2)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(theme.chip))
            Spacer()
        }
    }
}

// MARK: - One attention row

/// A single queue row: reason chip + status, title, `repo/branch`, last activity, waiting age, and the
/// inline action(s) matched to its reason. Its own `View` so the reply field / in-flight state stay
/// local to the row instead of leaking into the tab.
private struct AttentionRow: View {
    let item: AttentionItem
    let onOpen: () -> Void
    let onRecover: () -> Void

    @EnvironmentObject private var model: BoardModel
    @EnvironmentObject private var snooze: NeedsYouSnooze
    @Environment(\.theme) private var theme: Theme

    @State private var replying = false
    @State private var draft = ""
    @State private var busy = false          // guards the async gate/reply so a double-tap can't double-fire
    @FocusState private var replyFocused: Bool

    private var task: Task { item.task }
    private var sem: SemColor {
        switch item.reason {
        case .permission:  return theme.amber
        case .humanTurn:   return theme.blue
        case .died:        return theme.red
        case .contextFull: return theme.indigo
        }
    }

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
                        .foregroundStyle(task.ctxPct >= NeedsYouQueue.contextNearFullThreshold ? sem.text : theme.text3)
                }
            }
            if !task.desc.isEmpty {
                Text(task.desc)
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
        .opacity(task.status == .dead ? 0.85 : 1)
    }

    // MARK: header — reason chip + waiting age + status

    private var header: some View {
        HStack(spacing: 8) {
            ReasonChip(reason: item.reason, sem: sem)
            Spacer(minLength: 4)
            // How long it has been waiting — ticks live so "3s" stays honest.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(waitingLabel + relativeAge(task.updatedAt, now: ctx.date))
                    .font(.caption2.weight(.medium)).foregroundStyle(theme.text3).monospacedDigit()
            }
        }
    }
    /// Honest age prefix per status — a context-full card is still *running*, not waiting.
    private var waitingLabel: String {
        switch task.status {
        case .dead:    return "Died "
        case .running: return "Running "
        default:       return "Waiting "
        }
    }

    // MARK: actions — matched to the reason

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch item.reason {
            case .permission:
                ActionButton("Approve", systemImage: "checkmark", tint: theme.green, filled: true, busy: busy) {
                    run { await model.approvePermission(task.id) }
                }
                ActionButton("Deny", systemImage: "xmark", tint: theme.red) {
                    run { await model.denyPermission(task.id) }
                }
            case .humanTurn:
                ActionButton("Reply", systemImage: "text.bubble", tint: theme.blue) {
                    withAnimation { replying.toggle() }
                    if replying { replyFocused = true }
                }
            case .died:
                ActionButton("Recover", systemImage: "cross.case", tint: theme.red, filled: true) { onRecover() }
            case .contextFull:
                ActionButton("Open", systemImage: "arrow.up.forward.square", tint: theme.indigo) { onOpen() }
            }
            Spacer(minLength: 0)
            overflow
        }
        .disabled(busy)
    }

    /// The always-present secondary menu: open the card, snooze, dismiss (design §6: "plus open-card and
    /// snooze/dismiss throughout").
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

    // MARK: inline reply (Needs-you rows) — drives the `send` RPC

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

/// The reason chip (emoji + label) in the reason's semantic color.
private struct ReasonChip: View {
    let reason: AttentionReason
    let sem: SemColor
    var body: some View {
        HStack(spacing: 4) {
            Text(reason.emoji)
            Text(reason.label)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(sem.text)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(sem.tint))
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
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                Capsule().fill(filled ? tint.dot : tint.tint)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pushed destinations (nav hooks)

/// "Open card" summary — reuses the board card cell as a read-only preview. Deliberately light: the full
/// 5-tab card detail is M2's job; this just lets the queue open a card in place.
private struct CardPeekView: View {
    let task: Task?
    @Environment(\.theme) private var theme: Theme
    var body: some View {
        ScrollView {
            if let task {
                VStack(alignment: .leading, spacing: 14) {
                    BoardCardCell(task: task)
                    Text("Full card detail lives on the Board tab.")
                        .font(.footnote).foregroundStyle(theme.text3)
                }
                .padding(16)
            } else {
                Text("This card no longer needs you.").foregroundStyle(theme.text2).padding()
            }
        }
        .background(theme.winBg.ignoresSafeArea())
        .navigationTitle("Card")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// **Recovery deep-link (M7 nav hook).** A died card routes here; M7 replaces this placeholder with the
/// real Recovery panel (why · preserved work · Copy prompt · Start new / Resume / Archive — design §4).
private struct RecoveryPlaceholder: View {
    let task: Task?
    @Environment(\.theme) private var theme: Theme
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cross.case").font(.largeTitle).foregroundStyle(theme.red.dot)
            Text(task?.title ?? "Card").font(.headline).foregroundStyle(theme.text)
            if let r = task?.deadReason {
                Text("Died: \(r.rawValue)").font(.subheadline).foregroundStyle(theme.text2)
            }
            Text("Recovery (Start new · Resume · Archive) arrives with M7.")
                .font(.footnote).foregroundStyle(theme.text3).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.winBg.ignoresSafeArea())
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Helpers

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Relative age like the board's `3s`/`4m`/`2h`/`1d`.
private func relativeAge(_ date: Date, now: Date = Date()) -> String {
    let s = Int(max(0, now.timeIntervalSince(date)))
    if s < 60 { return "\(s)s" }
    let m = s / 60; if m < 60 { return "\(m)m" }
    let h = m / 60; if h < 24 { return "\(h)h" }
    return "\(h / 24)d"
}
