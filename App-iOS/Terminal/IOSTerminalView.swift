import SwiftUI
import UIKit
import SwiftTerm
import OrchestraKit   // TerminalKey + applyControlModifier (sticky-Ctrl transform)

/// A live SwiftTerm iOS terminal bound to a `TerminalByteChannel`. This is the one place the phone
/// runs a real terminal emulator; T2 (phone-owned shell) and T4 (agent takeover) reuse it verbatim,
/// swapping only the channel the `makeChannel` closure builds.
///
/// The `Coordinator` owns the channel and survives SwiftUI re-renders, so a view update does NOT tear
/// down and re-attach the SSH session — that, plus the server-side idempotent attach recipe, is what
/// makes reconnect reuse the same tmux view session instead of stacking clients. Give the view a stable
/// `.id` upstream so SwiftUI keeps one Coordinator per attach target.
struct IOSTerminalView: UIViewRepresentable {
    /// Builds the channel for this terminal. Called once, lazily, when the view first learns its real
    /// column/row size (so the PTY opens at the right size). Reused across reconnects.
    let makeChannel: () -> TerminalByteChannel
    /// Optional imperative handle (PR T4 takeover / T2 shell): accessory keys, arming, font, Select. `nil`
    /// for the plain read-only attach (DebugTerminalTab / IOSTerminalHost.attach), which needs none of it.
    var control: TerminalControl? = nil

    /// T2 "Select mode": when `true`, mouse reporting is disabled so a one-finger drag selects text
    /// natively instead of being forwarded to a mouse-aware TUI. Applied on every update so the tab can
    /// toggle it live. Defaults to `false`. (Takeover drives Select via `control` instead; either wins.)
    var selectMode: Bool = false

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(makeChannel: makeChannel)
        control?.attach(coordinator: c)
        return c
    }

    func makeUIView(context: Context) -> TerminalView {
        let term = TerminalView(frame: .zero)
        term.terminalDelegate = context.coordinator
        term.font = UIFont.monospacedSystemFont(ofSize: control?.fontSize ?? 13, weight: .regular)
        term.nativeBackgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        term.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        // Fixed xterm 256-colour palette (same reasoning as the desktop) so indexed colours mean what
        // TUIs expect rather than being re-derived from the theme.
        term.getTerminal().ansi256PaletteStrategy = .xterm
        context.coordinator.terminal = term
        return term
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // Takeover chrome (T4) drives font + Select through the `control` handle; the Terminal-tab live
        // shell (T2) has no control and passes `selectMode` directly. Reflect whichever is active.
        if let control {
            let size = control.fontSize
            if abs(uiView.font.pointSize - size) > 0.5 {
                uiView.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
        }
        // Select mode ⇒ no mouse reporting ⇒ a drag selects text instead of moving the TUI cursor.
        uiView.allowMouseReporting = !((control?.selectMode ?? false) || selectMode)
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    // `@preconcurrency`: SwiftTerm's `TerminalViewDelegate` predates Swift concurrency (its methods
    // aren't actor-isolated), but it only ever calls back on the main thread — so a `@MainActor`
    // coordinator satisfying it is correct, with a runtime check rather than a compile error.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        private let makeChannel: () -> TerminalByteChannel
        weak var terminal: TerminalView?
        private var channel: TerminalByteChannel?
        private var started = false
        private var intentionalClose = false
        private var reconnects = 0
        private let maxReconnects = 5
        // Sticky-Ctrl state for soft-keyboard input (set from the accessory bar's Ctrl key via the control
        // handle). One-shot unless locked; consumed on the next typed keystroke.
        private var pendingCtrl = false
        private var ctrlLocked = false

        init(makeChannel: @escaping () -> TerminalByteChannel) {
            self.makeChannel = makeChannel
        }

        func teardown() {
            intentionalClose = true
            channel?.close()
            channel = nil
        }

        // MARK: imperative control (PR T4 — accessory bar / arming / sticky Ctrl)

        /// Send raw bytes straight to the PTY — the accessory bar's explicit key taps, which always send
        /// regardless of the arming scrim (arming only gates the soft keyboard).
        func sendBytes(_ bytes: [UInt8]) { channel?.send(bytes) }

        /// Arm typing: show the soft keyboard by making the terminal first responder.
        func focus() { _ = terminal?.becomeFirstResponder() }
        /// Dismiss the soft keyboard.
        func blur() { _ = terminal?.resignFirstResponder() }

        func setPendingCtrl(_ on: Bool, locked: Bool) {
            pendingCtrl = on
            ctrlLocked = locked
        }

        // MARK: channel wiring

        private func openChannel(cols: Int, rows: Int) {
            let ch = makeChannel()
            ch.onOutput = { [weak self] bytes in
                self?.terminal?.feed(byteArray: bytes[...])
            }
            ch.onEvent = { [weak self] event in self?.handle(event) }
            channel = ch
            ch.start(cols: cols, rows: rows)
        }

        private func handle(_ event: TerminalChannelEvent) {
            switch event {
            case .connecting:
                feedStatus("[connecting…]")
            case .connected:
                reconnects = 0
            case .failed(let message):
                feedStatus("[connection failed: \(message)]")
                scheduleReconnect()
            case .hostKeyChanged(let host):
                // Possible MITM: show a persistent security warning and do NOT reconnect — hammering the
                // host would only bury the warning. The user re-keys via Settings ▸ reset trusted key.
                feedStatus("[⚠︎ host key CHANGED for \(host) — possible MITM. Connection refused. "
                           + "If you deliberately re-keyed this server, reset its trusted key in Settings.]")
            case .closed:
                guard !intentionalClose else { return }
                feedStatus("[disconnected]")
                scheduleReconnect()
            }
        }

        /// Reconnect reuses the SAME server-side tmux view session (the attach recipe is idempotent), so
        /// this re-establishes the SSH link without spawning a second client. Bounded backoff so an
        /// unreachable host doesn't spin forever.
        private func scheduleReconnect() {
            guard !intentionalClose, started, let term = terminal else { return }
            guard reconnects < maxReconnects else {
                feedStatus("[giving up after \(maxReconnects) attempts — pull to retry]")
                return
            }
            reconnects += 1
            let delay = Double(min(8, 1 << (reconnects - 1)))   // 1,2,4,8,8…
            let cols = term.getTerminal().cols, rows = term.getTerminal().rows
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.intentionalClose else { return }
                self.feedStatus("[reconnecting…]")
                // close() first: a remote-initiated drop leaves the channel non-idle, so start() would
                // no-op on its idempotency guard. close() resets it to a restartable state; the new SSH
                // link re-attaches the SAME server-side view session (recipe is idempotent).
                self.channel?.close()
                self.channel?.start(cols: cols, rows: rows)
            }
        }

        private func feedStatus(_ text: String) {
            terminal?.feed(text: "\r\n\u{001b}[2m\(text)\u{001b}[0m\r\n")
        }

        // MARK: TerminalViewDelegate

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            if !started {
                started = true
                openChannel(cols: newCols, rows: newRows)   // first real size → open the PTY at that size
            } else {
                channel?.resize(cols: newCols, rows: newRows)
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            var bytes = Array(data)
            // Sticky Ctrl: a primed Ctrl folds the next soft-keyboard keystroke to its control code
            // (Ctrl-C etc.), then clears unless locked. Keeps the bar's Ctrl chip in sync via onConsume.
            if pendingCtrl {
                bytes = applyControlModifier(to: bytes)
                if !ctrlLocked { pendingCtrl = false; onCtrlConsumed?() }
            }
            channel?.send(bytes)
        }

        /// Called after a one-shot Ctrl is consumed by a typed keystroke, so the `TerminalControl` can
        /// clear its published `ctrl` chip (the bar de-highlights). Set by `TerminalControl.attach`.
        var onCtrlConsumed: (() -> Void)?

        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
        }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
