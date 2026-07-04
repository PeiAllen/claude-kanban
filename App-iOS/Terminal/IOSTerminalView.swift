import SwiftUI
import UIKit
import SwiftTerm

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

    func makeCoordinator() -> Coordinator { Coordinator(makeChannel: makeChannel) }

    func makeUIView(context: Context) -> TerminalView {
        let term = TerminalView(frame: .zero)
        term.terminalDelegate = context.coordinator
        term.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        term.nativeBackgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        term.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        // Fixed xterm 256-colour palette (same reasoning as the desktop) so indexed colours mean what
        // TUIs expect rather than being re-derived from the theme.
        term.getTerminal().ansi256PaletteStrategy = .xterm
        context.coordinator.terminal = term
        return term
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

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

        init(makeChannel: @escaping () -> TerminalByteChannel) {
            self.makeChannel = makeChannel
        }

        func teardown() {
            intentionalClose = true
            channel?.close()
            channel = nil
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
            channel?.send(Array(data))
        }

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
