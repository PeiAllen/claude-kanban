import SwiftUI
import OrchestraKit
import OrchestraUI

/// The full-screen live **Take Over Agent Terminal** surface (PR T4) — the payoff of the takeover design:
/// the phone attaching the REAL agent TUI (Claude or Codex, provider-neutrally) under an exclusive lease.
///
/// Flow: on appear, acquire the `.phone` lease (`TakeoverController.begin`) → the daemon broadcasts, the
/// desktop unmounts (D5) → attach an `IOSTerminalView` to the returned `agent` `TmuxTarget` via the
/// takeover recipe (`detach-client` first) → heartbeat keeps it fresh. **Return to Desktop** (or a desktop
/// Retake flipping ownership away) releases / drops the attach.
///
/// Chrome, per the design: a compact **owner bar** (title/status · connection · *You have control* ·
/// Return to Desktop); **armed input** (disarmed by default — the terminal is a fully-visible, swipe-to-
/// scroll surface: a one-finger swipe scrolls the agent, and it sends nothing until you *Start Typing* or
/// tap it, after which a two-finger swipe still scrolls while typing); a minimal **accessory key bar**
/// (Esc · sticky Ctrl · Tab · ↵ · ↑ · ↓ · ⋯ drawer); explicit **Select** mode; **A− / A+** font.
/// Landscape is the real-terminal posture; portrait is allowed.
struct AgentTakeoverView: View {
    let cardId: UUID
    var onClose: () -> Void

    @EnvironmentObject private var model: BoardModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme: Theme
    @StateObject private var control = TerminalControl()
    @StateObject private var controller: TakeoverController

    private let host = IOSTerminalHost()

    init(cardId: UUID, model: BoardModel, onClose: @escaping () -> Void) {
        self.cardId = cardId
        self.onClose = onClose
        _controller = StateObject(wrappedValue: TakeoverController(cardId: cardId, model: model))
    }

    private var card: OrchestraKit.Task? {
        model.tasks.first { $0.id == cardId } ?? model.archived.first { $0.id == cardId }
    }

    var body: some View {
        VStack(spacing: 0) {
            ownerBar
            Divider().overlay(Color.white.opacity(0.08))
            terminalRegion
            if controller.isHolding {
                controlsRow
                accessoryBar
            }
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.07).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await controller.begin() }
        // Catch a desktop Retake that arrives as a live owner event *between* heartbeats.
        .onReceive(model.$agentOwners) { _ in controller.reconcile() }
        // Foregrounding revives a terminal that gave up reconnecting while backgrounded (LOW — the "reopen
        // or foreground to retry" affordance). No-op unless the channel is actually dead.
        .onChange(of: scenePhase) { _, phase in if phase == .active { control.retry() } }
        // Any dismissal releases the lease — the Return-to-Desktop button (idempotent with its own call),
        // a swipe-down, or a programmatic dismiss. Without this a non-button dismissal would strand a
        // heartbeat-less lease that goes stale in ~30s while the surface still shows control (#8).
        .onDisappear { _Concurrency.Task { await controller.returnToDesktop() } }
    }

    // MARK: owner bar

    private var ownerBar: some View {
        HStack(spacing: 10) {
            Button {
                _Concurrency.Task { await controller.returnToDesktop(); onClose() }
            } label: {
                Label("Return to Desktop", systemImage: "chevron.left")
                    .font(.subheadline.weight(.medium))
                    .labelStyle(.titleAndIcon)
            }
            .tint(.white)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(card?.title ?? "Agent terminal")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    if controller.isHolding {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("You have control").foregroundStyle(.green)
                    }
                    Text("·").foregroundStyle(.white.opacity(0.3))
                    Circle().fill(connectionColor).frame(width: 6, height: 6)
                    Text(connectionLabel).foregroundStyle(.white.opacity(0.6))
                    if let s = card?.status {
                        Text("·").foregroundStyle(.white.opacity(0.3))
                        Text(theme.statusLabel(s)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .font(.caption2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .live: return .green
        case .connecting: return .blue
        case .retrying: return .orange
        case .down: return .gray
        }
    }
    private var connectionLabel: String {
        switch model.connectionState {
        case .live: return "Connected"
        case .connecting: return "Connecting…"
        case .retrying: return "Reconnecting…"
        case .down: return "Offline"
        }
    }
    // MARK: terminal region + overlays

    private var terminalRegion: some View {
        ZStack {
            Color.black
            switch controller.phase {
            case .holding(let target):
                // Lease-blind reconnect guard (#7): only auto-reconnect while THIS phone still holds the
                // lease — a reconnect after a desktop retake would re-run `detach-client` and kick the desktop.
                //
                // No arming scrim over the terminal: when disarmed the terminal is the *top interactive
                // layer* — fully visible, and a swipe scrolls the agent (forwarded to tmux copy-mode, since
                // the attached view is always the alternate screen; see IOSTerminalView.handleWheelPan).
                // Typing is armed via the accessory bar's Start Typing toggle or by tapping the terminal.
                // One finger scrolls while disarmed; a two-finger swipe scrolls while armed (keyboard up).
                host.takeoverAttach(target: target, control: control,
                                    shouldReconnect: { [weak controller] in controller?.isHolding ?? false })
            case .acquiring:
                overlay(icon: "arrow.triangle.2.circlepath", title: "Taking over…",
                        detail: "Acquiring the agent-terminal lease.")
            case .lostToDesktop:
                overlay(icon: "desktopcomputer", title: "Desktop retook control",
                        detail: "The desktop reattached to this agent terminal. Your live view has been dropped.",
                        action: ("Close", { onClose() }))
            case .failed(let message):
                overlay(icon: "exclamationmark.triangle", title: "Couldn't take over",
                        detail: message, action: ("Close", { onClose() }))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func overlay(icon: String, title: String, detail: String,
                         action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.white.opacity(0.8))
            Text(title).font(.headline).foregroundStyle(.white)
            Text(detail).font(.callout).multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.65)).padding(.horizontal, 32)
            if let (label, run) = action {
                Button(label, action: run)
                    .buttonStyle(.borderedProminent).tint(.blue).padding(.top, 4)
            }
        }
        .padding(28)
    }

    // MARK: controls row (font / select / keyboard)

    private var controlsRow: some View {
        HStack(spacing: 8) {
            keyCap("A", sub: "−") { control.bumpFont(-1) }
            keyCap("A", sub: "+") { control.bumpFont(+1) }
            toggleCap("Select", systemImage: "selection.pin.in.out", on: control.selectMode) {
                control.selectMode.toggle()
            }
            Spacer()
            toggleCap(control.armed ? "Keyboard" : "Start Typing",
                      systemImage: control.armed ? "keyboard.chevron.compact.down" : "keyboard",
                      on: control.armed) {
                control.armed ? control.dismissKeyboard() : control.arm()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: minimal accessory key bar

    private var accessoryBar: some View {
        HStack(spacing: 6) {
            keyCap("esc") { control.send(.esc) }
            toggleCap("^", systemImage: nil, on: control.ctrl) { control.tapCtrl() }
                .overlay(alignment: .topTrailing) {
                    if control.ctrlLocked {
                        Image(systemName: "lock.fill").font(.system(size: 8))
                            .foregroundStyle(.yellow).padding(2)
                    }
                }
            keyCap("tab") { control.send(.tab) }
            keyCap(nil, systemImage: "return") { control.send(.enter) }
            keyCap(nil, systemImage: "arrow.up") { control.send(.up) }
            keyCap(nil, systemImage: "arrow.down") { control.send(.down) }
            drawer
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// Secondary keys the design tucks behind a ⋯ drawer (Left · Right · PgUp · PgDn · Home · End).
    private var drawer: some View {
        Menu {
            Button { control.send(.left) }  label: { Label("Left",  systemImage: "arrow.left") }
            Button { control.send(.right) } label: { Label("Right", systemImage: "arrow.right") }
            Button { control.send(.pageUp) }   label: { Label("Page Up",   systemImage: "arrow.up.to.line") }
            Button { control.send(.pageDown) } label: { Label("Page Down", systemImage: "arrow.down.to.line") }
            Button { control.send(.home) } label: { Label("Home", systemImage: "arrow.left.to.line") }
            Button { control.send(.end) }  label: { Label("End",  systemImage: "arrow.right.to.line") }
        } label: {
            keyCapLabel(nil, systemImage: "ellipsis")
        }
    }

    // MARK: keycap building blocks

    private func keyCap(_ text: String?, sub: String? = nil, systemImage: String? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) { keyCapLabel(text, sub: sub, systemImage: systemImage) }
    }

    private func toggleCap(_ text: String, systemImage: String?, on: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { keyCapLabel(text, systemImage: systemImage, highlighted: on) }
    }

    private func keyCapLabel(_ text: String?, sub: String? = nil, systemImage: String? = nil,
                             highlighted: Bool = false) -> some View {
        HStack(spacing: 2) {
            if let systemImage { Image(systemName: systemImage) }
            if let text { Text(text).font(.system(.subheadline, design: .monospaced)) }
            if let sub { Text(sub).font(.system(.caption2, design: .monospaced)).baselineOffset(-2) }
        }
        .foregroundStyle(highlighted ? Color.black : Color.white)
        .frame(minWidth: 34, minHeight: 34)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(highlighted ? Color.yellow.opacity(0.9) : Color.white.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12)))
    }
}
