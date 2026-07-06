import SwiftUI
import OrchestraKit
import OrchestraUI

/// The primary **Agent** tab (PR T3) — design §"The Agent tab — capture/structured by default, takeover
/// on demand" (~90% of phone use). Non-attaching by default, so a phone glance never resizes the desktop
/// TUI (design Problem 2):
///
///   • **Read** — a `capture`-backed scroll render of the agent pane (D1: a non-attaching, size-capped
///     `capture-pane` scrape; ugly but zero-attach and sizing-safe) plus the live status pill / context
///     gauge / `waitReason` from the board event stream (the header already carries status+ctx; this tab
///     surfaces the *waiting* reason as an actionable banner).
///   • **Steer** — a "Message the agent" bar → `send` (queued to the inbox, drained at turn-end) with a
///     constrained key row → `send-keys` (D2: Esc/↵/arrows/y/n/^C — no live attach, no resize pressure).
///   • **Gates** — surfaced as Needs-You (M3), not here: a waiting-on-permission card shows a banner
///     pointing at that queue. This tab deliberately does NOT reimplement approve/deny.
///   • **Take Over** — the explicit **Take Over Agent Terminal** button (the ONLY attach path) presents
///     T4's `AgentTakeoverView` full-screen under the exclusive owner lease.
///
/// A `dead` card renders M2's `RecoveryHook` (M7 builds the full recovery panel) instead of agent chrome.
/// Provider-neutral throughout: the capture render is a pane scrape (no `agent ==` branch). Codex Sixel
/// images render as native images in a later slice (C2) by extending `CapturePaneText` — see the seam note.
struct AgentTab: View {
    let task: Task
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    @State private var takeover = false

    var body: some View {
        if task.status == .dead {
            RecoveryHook(task: task)
        } else {
            VStack(spacing: 0) {
                if let reason = task.status == .waiting ? task.waitReason : nil {
                    WaitBanner(reason: reason, theme: theme)
                }
                CaptureRender(cardId: task.id)
                Divider().overlay(theme.hair)
                SteerBar(cardId: task.id)
                takeOverButton
            }
            .background(theme.winBg)
            .fullScreenCover(isPresented: $takeover) {
                AgentTakeoverView(cardId: task.id, model: model) { takeover = false }
            }
        }
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

// MARK: - Wait banner (status → Needs You)

/// A compact banner surfacing *why* the card is waiting. Gates live in the Needs-You queue (M3); this only
/// points there — it never renders approve/deny.
private struct WaitBanner: View {
    let reason: WaitReason
    let theme: Theme

    private var sem: SemColor { reason == .permission ? theme.amber : theme.blue }
    private var icon: String { reason == .permission ? "lock.shield.fill" : "person.crop.circle.badge.questionmark" }
    private var title: String { reason == .permission ? "Needs your approval" : "Waiting on you" }
    private var detail: String {
        reason == .permission
            ? "The agent is blocked on a permission — approve or deny it in Needs You."
            : "The agent finished its turn and is waiting. Steer it below, or take over."
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
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    @State private var frame: CaptureResult?
    @State private var lastUpdated: Date?
    @State private var loadedOnce = false
    /// The pane's own width, so inline images (C2) fit the phone instead of the unbounded horizontal
    /// scroll content. Measured off the resolved pane size, not the scroll content.
    @State private var paneWidth: CGFloat = 0

    /// Poll cadence for the non-attaching scrape. Fast enough to feel live for "check and steer", cheap
    /// because `capture` is a single `capture-pane` with no attach.
    private let interval: UInt64 = 1_500_000_000

    var body: some View {
        ZStack {
            theme.termBg
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(widthReader)
        .overlay(alignment: .bottomTrailing) { footer.padding(8) }
        .task(id: cardId) { await pollLoop() }
    }

    /// Publishes the pane width into `paneWidth` so `CapturePaneText` can fit inline images to it.
    private var widthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { paneWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in paneWidth = w }
        }
    }

    @ViewBuilder private var content: some View {
        if let frame, !frame.text.isEmpty {
            ScrollView([.vertical, .horizontal]) {
                CapturePaneText(text: frame.text, maxImageWidth: max(0, paneWidth - 24))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(lastUpdated.map { "captured " + relativeDetailAge($0) } ?? "reading…")
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(theme.text3)
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
    private func pollLoop() async {
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

/// Renders one captured pane frame. **C2:** the frame is split into ordered runs (`captureRuns`) — plain
/// monospaced text as before, plus any inline **Sixel** image decoded to a native `Image` fit to the
/// phone's width (design §"Codex Sixel width"). Detection is provider-neutral (any Sixel DCS; no `agent ==`
/// branch). The common all-text case renders identically to pre-C2 (a single `Text`, no layout change).
///
/// Note the capture-pipeline reality documented in `SixelDecode.swift`: `capture-pane -p` strips Sixel, so
/// a live Codex image does not reach here through today's non-attaching capture — this renders images the
/// moment raw Sixel bytes *do* land in the pane text (a synthetic capture, or a future image-preserving
/// capture/transcript path).
private struct CapturePaneText: View {
    let text: String
    /// Upper bound for inline image width (the pane width less padding); 0 = unmeasured → native size.
    var maxImageWidth: CGFloat = 0
    @Environment(\.theme) private var theme: Theme

    /// Decoded runs for the current frame, recomputed only when `text` actually changes (Sixel scan +
    /// decode is otherwise re-run on every body eval — footer/`lastUpdated` ticks re-render this view).
    @State private var runs: [CapturePaneRun] = []

    var body: some View {
        content
            .onAppear { runs = captureRuns(from: text) }
            .onChange(of: text) { _, t in runs = captureRuns(from: t) }
    }

    @ViewBuilder private var content: some View {
        // Fast/common path: an all-text frame renders exactly as pre-C2 (one Text, no VStack wrapping).
        if runs.count == 1, case .text(let s) = runs[0] {
            paneText(s)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(runs.indices, id: \.self) { idx in
                    runView(runs[idx])
                }
            }
        }
    }

    @ViewBuilder private func runView(_ run: CapturePaneRun) -> some View {
        switch run {
        case .text(let s):     paneText(s)
        case .image(let cg):   imageView(cg)
        case .imagePlaceholder: placeholder
        }
    }

    private func paneText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(theme.term)
            .textSelection(.enabled)
            .lineLimit(nil)
    }

    /// Draw the decoded image fit to the phone width. Codex sizes Sixel to the desktop window, so the
    /// common case is *downscaling* to phone width; never upscale a small image past its native pixels.
    private func imageView(_ cg: CGImage) -> some View {
        let native = CGFloat(cg.width)
        let cap = maxImageWidth > 0 ? min(maxImageWidth, native) : native
        return Image(decorative: cg, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: cap, alignment: .leading)
            .accessibilityLabel("Inline image from the agent")
    }

    private var placeholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo").font(.caption)
            Text("inline image").font(.caption2)
        }
        .foregroundStyle(theme.text3)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(theme.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Steer bar (send = queued · send-keys = constrained keys)

/// The "Message the agent" bar. The text field **queues** a message via `send` (inbox, drained at the
/// agent's next turn-end) — no attach. The key row sends **constrained keys** via `send-keys` for TUI
/// prompts (y/n, a menu, Esc-to-cancel) without attaching or resizing. Both are D1/D2 primitives; neither
/// joins the tmux window.
private struct SteerBar: View {
    let cardId: UUID
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    @State private var draft = ""
    @State private var justQueued = false

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
                    .onSubmit(queue)

                Button(action: queue) {
                    Image(systemName: justQueued ? "checkmark" : "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 38)
                        .foregroundStyle(.white)
                        .background(trimmed.isEmpty ? theme.text3 : theme.accent,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty)
            }
            Text(justQueued ? "Queued — the agent drains it at its next turn-end."
                            : "Queues a message to the agent’s inbox — no live attach.")
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
        guard !msg.isEmpty else { return }
        draft = ""
        flashQueued()
        _Concurrency.Task { await model.send(cardId, msg) }
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
