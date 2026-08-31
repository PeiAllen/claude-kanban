import SwiftUI
import UIKit
import OrchestraKit
import OrchestraUI

/// The primary **Agent** tab (PR T3) — design §"The Agent tab — capture/structured by default, takeover
/// on demand" (~90% of phone use). Non-attaching by default, so a phone glance never resizes the desktop
/// TUI (design Problem 2):
///
///   • **Read** — a `capture`-backed scroll render of the agent pane (D1: a non-attaching, size-capped
///     `capture-pane` scrape; ugly but zero-attach and sizing-safe) plus the live status pill / context
///     gauge / agent state from the board event stream (the header already carries status+ctx; this tab
///     surfaces an ordinary wait or human-needed state as an actionable banner).
///   • **Steer** — a "Message the agent" bar → `send` (queued for native harness delivery) with a
///     constrained key row → `send-keys` (D2: Esc/↵/arrows/y/n/^C — no live attach, no resize pressure).
///   • **Gates** — surfaced as Needs-You (M3), not here: any human-needed card shows a banner pointing
///     at that queue. Provider prompts are resolved in the harness itself.
///   • **Take Over** — the explicit **Take Over Agent Terminal** button (the ONLY attach path) presents
///     T4's `AgentTakeoverView` full-screen under the exclusive owner lease.
///
/// A `dead` card renders `RecoveryView` (the recovery panel) instead of agent chrome.
/// Provider-neutral throughout: the capture render is a pane scrape (no `agent ==` branch).
struct AgentTab: View {
    let task: Task
    let onOpenImage: (UUID) -> Void
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    @State private var takeover = false
    /// Composer focus, hoisted here so the capture/preview area (a sibling of the SteerBar) can resign it
    /// on tap-off. `SteerBar` binds to it via `.focused(...)`; the keyboard has no natural dismiss otherwise.
    @FocusState private var composerFocused: Bool

    var body: some View {
        if task.phaseDisplay == .dead {
            RecoveryView(task: task)
        } else {
            VStack(spacing: 0) {
                if let bannerKind {
                    WaitBanner(kind: bannerKind, theme: theme)
                }
                CaptureRender(cardId: task.id, onOpenImage: onOpenImage)
                    // Tap-off + swipe-down dismissal for the composer keyboard. Additive container-level
                    // modifiers only — the capture ScrollView internals are left untouched.
                    .scrollDismissesKeyboard(.interactively)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                Divider().overlay(theme.hair)
                SteerBar(cardId: task.id, composerFocused: $composerFocused)
                takeOverButton
            }
            .background(theme.winBg)
            .fullScreenCover(isPresented: $takeover) {
                AgentTakeoverView(cardId: task.id, model: model, onOpenImage: onOpenImage) {
                    takeover = false
                }
            }
        }
    }

    private var bannerKind: AgentBannerKind? {
        agentBannerKind(for: task)
    }

    /// The one attach path (T4). Everything above is non-attaching; this is the deliberate, explicit door
    /// into the live TUI under the daemon's exclusive ownership lease.
    private var takeOverButton: some View {
        Button {
            takeover = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.app.fill")
                Text("Take Over Agent Terminal").font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .accessibilityHint("Attaches the live agent terminal full-screen under an exclusive lease.")
    }
}

// MARK: - Agent banner (status + human need)

/// A compact banner surfacing why the card needs attention or is waiting. Gates live in the Needs-You
/// queue (M3); this only points there and does not answer provider prompts directly.
/// This is an ephemeral display classification. `Task.requiresHuman` remains the sole membership fact;
/// a provider subtype only refines the copy after that membership decision.
enum AgentBannerKind: Equatable { case permission, input, humanRequired, waiting }

func agentBannerKind(for task: Task) -> AgentBannerKind? {
    if task.requiresHuman {
        switch task.agentState?.humanNeed {
        case .permission?: return .permission
        case .input?: return .input
        case .unspecified?, nil: return .humanRequired
        }
    }
    return task.workInFlight == false ? .waiting : nil
}

private struct WaitBanner: View {
    let kind: AgentBannerKind
    let theme: Theme

    private var sem: SemColor {
        switch kind {
        case .permission, .input, .humanRequired: return theme.amber
        case .waiting: return theme.blue
        }
    }
    private var icon: String {
        switch kind {
        case .permission: return "lock.shield.fill"
        case .input: return "text.bubble.fill"
        case .humanRequired: return "person.crop.circle.badge.exclamationmark"
        case .waiting: return "person.crop.circle.badge.questionmark"
        }
    }
    private var title: String {
        switch kind {
        case .permission: return "Needs your approval"
        case .input: return "Needs your input"
        case .humanRequired: return "Needs your attention"
        case .waiting: return "Waiting"
        }
    }
    private var detail: String {
        switch kind {
        case .permission:
            return "The agent is blocked on a permission. Open Harness to resolve it."
        case .input:
            return "The agent opened an interactive question. Open Harness to answer it."
        case .humanRequired:
            return "A response is waiting for you. Open Harness to review and respond."
        case .waiting:
            return "The agent finished its turn and is waiting. Steer it below, or take over."
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.callout).foregroundStyle(sem.text)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(sem.text)
                Text(detail).font(.caption2).foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sem.tint)
        .overlay(Rectangle().fill(theme.hair).frame(height: 0.5), alignment: .bottom)
    }
}

// MARK: - Capture render (D1: non-attaching pane scrape)

/// The v1 read surface: a self-polling `capture` render of the agent pane. Non-attaching — it never joins
/// the tmux window, so it can't resize the desktop TUI. Polls while visible; the last good frame stays on
/// screen through a transient RPC miss. Horizontal + vertical scroll so wide TUI lines aren't reflowed.
private struct CaptureRender: View {
    let cardId: UUID
    let onOpenImage: (UUID) -> Void
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    /// The scene gate (iOS: `scenePhase == .active`). The capture scrape is the phone's non-attaching
    /// terminal *preview*, so it parks on the same signal the live terminals do — no daemon polling while
    /// the scene is inactive/background. Keyed into `.task` below so a scene flip restarts the loop.
    @Environment(\.animationsActive) private var animationsActive

    @State private var frame: CaptureResult?
    @State private var lastUpdated: Date?
    @State private var loadedOnce = false

    /// Scroll id on the capture text so `ScrollViewReader` can pin the view to the tail (newest output).
    private let tailAnchor = "capture-tail"

    /// Poll cadence for the non-attaching scrape. Fast enough to feel live for "check and steer", cheap
    /// because `capture` is a single `capture-pane` with no attach.
    private let interval: UInt64 = 1_500_000_000

    var body: some View {
        ZStack {
            theme.termBg
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) { footer.padding(8) }
        // Keyed on the card AND the scene gate: a scene flip cancels+restarts the loop, so leaving the
        // scene stops polling (the last frame stays on screen) and returning polls immediately (fresh at
        // once). `.task` already self-cancels when the tab/detail goes away.
        .task(id: "\(cardId.uuidString):\(animationsActive)") { await pollLoop() }
    }

    @ViewBuilder private var content: some View {
        if let frame, !frame.text.isEmpty {
            // Follow the tail like a real terminal: the capture scrape is the *newest* pane frame, so we
            // pin the view to the bottom on first appearance and re-pin whenever the captured text changes
            // (each poll tick that actually produced new output). `scrollTo(anchor: .bottomLeading)` aligns
            // the text block's bottom-left corner to the viewport, so the latest lines are always in view
            // and start at column 0 (long lines aren't horizontally centered off-screen).
            // Trade-off (per the plain always-stick spec): a user who scrolls up to read history gets
            // yanked back down on the next changed frame. Detecting "am I at the bottom?" needs per-line
            // ids or geometry readers the single capture blob doesn't have, so we ship plain stick-to-tail
            // — matching the Block-REPL notebook's auto-follow in TerminalTab.
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    CapturePaneText(text: frame.text, onOpenImage: onOpenImage)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(tailAnchor)
                }
                .onAppear { proxy.scrollTo(tailAnchor, anchor: .bottomLeading) }
                .onChange(of: frame.text) { _, _ in proxy.scrollTo(tailAnchor, anchor: .bottomLeading) }
            }
        } else if loadedOnce {
            emptyState(icon: "text.viewfinder", label: "The agent pane is empty.")
        } else {
            ProgressView().tint(theme.text3)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if frame?.truncated == true {
                Text("truncated").font(.caption2).foregroundStyle(theme.text3)
                Text("·").foregroundStyle(theme.text3)
            }
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 9))
            Text(lastUpdated.map { "captured " + relativeAge($0) } ?? "reading…")
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(theme.text3)
        .chipText()
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(theme.winBg.opacity(0.7)))
    }

    private func emptyState(icon: String, label: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(theme.text3)
            Text(label).font(.footnote).foregroundStyle(theme.text3)
        }
    }

    /// Self-cancelling poll: SwiftUI cancels this `.task` when the tab/view goes away, so the loop stops
    /// when the Agent tab isn't visible. A `nil` capture (transient RPC miss) keeps the last good frame.
    /// Parked (scene inactive/background) → return without polling; the last frame stays and the `.task`
    /// key restarts this loop — polling again immediately — the moment the scene comes back.
    private func pollLoop() async {
        guard animationsActive else { return }
        while !_Concurrency.Task.isCancelled {
            if let c = await model.captureAgentPane(cardId) {
                frame = c
                lastUpdated = Date()
            }
            loadedOnce = true
            try? await _Concurrency.Task.sleep(nanoseconds: interval)
        }
    }
}

/// Renders one captured pane frame as selectable monospaced text. The tokenizer recognizes only the
/// opaque Orchestra fallback URL; ordinary URLs remain ordinary text-view links.
private struct CapturePaneText: UIViewRepresentable {
    let text: String
    let onOpenImage: (UUID) -> Void
    @Environment(\.theme) private var theme: Theme

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenImage: onOpenImage)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onOpenImage = onOpenImage
        uiView.attributedText = renderedText()
        uiView.linkTextAttributes = [
            .foregroundColor: UIColor(theme.accent),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func renderedText() -> NSAttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let plainAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(theme.term),
        ]
        let imageAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(theme.accent),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let rendered = NSMutableAttributedString()

        for segment in TranscriptImageTextTokenizer.tokenize(text) {
            switch segment {
            case .text(let text):
                rendered.append(NSAttributedString(string: text, attributes: plainAttributes))
            case .reference(let id):
                let marker = TranscriptImageLink.url(for: id)
                var attributes = imageAttributes
                attributes[.link] = marker
                rendered.append(NSAttributedString(string: marker, attributes: attributes))
            }
        }
        return rendered
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onOpenImage: (UUID) -> Void

        init(onOpenImage: @escaping (UUID) -> Void) {
            self.onOpenImage = onOpenImage
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL,
                      in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            guard let id = TranscriptImageLink.referenceID(from: URL.absoluteString) else { return true }
            onOpenImage(id)
            return false
        }
    }
}

// MARK: - Steer bar (send = native inbox · send-keys = constrained keys)

/// The "Message the agent" bar queues a message via `send` for native harness delivery — no attach. The
/// key row sends **constrained keys** via `send-keys` for TUI
/// prompts (y/n, a menu, Esc-to-cancel) without attaching or resizing. Both are D1/D2 primitives; neither
/// joins the tmux window.
private struct SteerBar: View {
    let cardId: UUID
    /// Bound from `AgentTab` so both the keyboard-toolbar "Done" button here and a tap-off on the sibling
    /// capture area resign the same field. Mirrors `TerminalTab`'s `@FocusState` composer idiom.
    @FocusState.Binding var composerFocused: Bool
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    @State private var draft = ""
    @State private var justQueued = false
    @State private var isQueueing = false

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 8) {
            keyRow
            HStack(spacing: 8) {
                TextField("Message the agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(theme.text)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.fieldBorder, lineWidth: 0.5))
                    .submitLabel(.send)
                    .focused($composerFocused)
                    .onSubmit(queue)
                    .disabled(isQueueing)
                    // Explicit dismissal from the keyboard accessory bar — the field is `.vertical`, so
                    // Return inserts a newline rather than closing; "Done" gives a guaranteed way out.
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { composerFocused = false }
                        }
                    }

                Button(action: queue) {
                    Image(systemName: justQueued ? "checkmark" : "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 38)
                        .foregroundStyle(.white)
                        .background(trimmed.isEmpty || isQueueing ? theme.text3 : theme.accent,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty || isQueueing)
            }
            Text(justQueued ? "Queued with Orchestra."
                            : "Queues a message for native harness delivery — no terminal attach.")
                .font(.caption2)
                .foregroundStyle(justQueued ? theme.green.text : theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
        .background(theme.card)
    }

    /// Constrained keys for TUI prompts the queued `send` can't answer (a y/n, a menu, Esc-to-cancel).
    /// No implicit Enter — each button sends exactly its chord (design D2 / `send-keys`).
    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                keyCap("esc") { send([.named(.esc)]) }
                keyCap("y")   { send([.text("y")]) }
                keyCap("n")   { send([.text("n")]) }
                keyCap(nil, systemImage: "arrow.up")   { send([.named(.up)]) }
                keyCap(nil, systemImage: "arrow.down") { send([.named(.down)]) }
                keyCap(nil, systemImage: "return")     { send([.named(.enter)]) }
                keyCap("^C")  { send([.named(.ctrlC)]) }
            }
            .padding(.horizontal, 2)
        }
    }

    private func keyCap(_ text: String?, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if let systemImage { Image(systemName: systemImage) }
                if let text { Text(text) }
            }
            .font(.system(.footnote, design: .monospaced).weight(.medium))
            .foregroundStyle(theme.text2)
            .frame(minWidth: 38, minHeight: 32)
            .padding(.horizontal, 6)
            .background(theme.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.hair, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func queue() {
        let msg = trimmed
        guard !msg.isEmpty, !isQueueing else { return }
        isQueueing = true
        _Concurrency.Task {
            let accepted = await model.send(cardId, msg)
            if accepted {
                draft = ""
                flashQueued()
            }
            isQueueing = false
        }
    }

    private func send(_ chord: [KeyToken]) {
        _Concurrency.Task { await model.sendKeysToAgent(cardId, chord) }
    }

    private func flashQueued() {
        withAnimation { justQueued = true }
        _Concurrency.Task {
            try? await _Concurrency.Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { withAnimation { justQueued = false } }
        }
    }
}
