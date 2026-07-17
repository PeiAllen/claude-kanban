import SwiftUI
import UIKit
import SwiftTerm
import OrchestraKit   // KeyName.bytes + applyControlModifier (sticky-Ctrl transform)

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

    /// Swipe-to-scroll the tmux history without the takeover's arming chrome — the Terminal-tab live shell
    /// (T2). Like the takeover, the live shell is a `tmux attach`, so SwiftTerm sits on the *alternate*
    /// buffer with no local scrollback (the history lives in tmux, `mouse on`, 50k lines). A plain
    /// one-finger swipe is therefore forwarded to tmux as mouse-wheel events (`Coordinator.handleWheelPan`)
    /// so tmux copy-mode scrolls — the same mechanism the desktop live shell uses. Unlike the takeover
    /// there's no `armed` state: scroll is one-finger always and SwiftTerm's own touch→mouse forwarding is
    /// kept off so a swipe can't double-fire as a tmux mouse-drag. Defaults to `false` (the takeover drives
    /// its wheel-pan through `control` instead; the read-only attach wants neither).
    var forwardScroll: Bool = false

    /// Gate consulted before each automatic reconnect. Takeover wires this to `TakeoverController.isHolding`
    /// so a reconnect NEVER re-runs the exclusive `detach-client` recipe after the phone has already lost the
    /// lease to a desktop retake (#7) — that would kick the rightful owner. Defaults to always-reconnect for
    /// the non-exclusive attaches (read-only / T2 shell), which have no lease to respect.
    var shouldReconnect: () -> Bool = { true }

    /// Receives only an exact opaque Orchestra media reference after SwiftTerm activates an OSC 8 link.
    /// Kept optional so the existing debug/read-only terminal uses remain ordinary terminal links.
    var onOpenImage: ((UUID) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(makeChannel: makeChannel, shouldReconnect: shouldReconnect,
                            onOpenImage: onOpenImage)
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
        // Tap-to-arm: with the arming scrim gone, a tap on the terminal is how the user starts typing.
        // SwiftTerm's own single-tap already calls `becomeFirstResponder` (raising the keyboard); this
        // observer just keeps `control.armed` in sync with that. The TAKEOVER uses it to flip mouse reporting
        // on when armed; the LIVE SHELL uses it only to know the keyboard is up so the tab can show its
        // **Hide keyboard** button (mouse reporting there stays off — `forwardScroll`). It recognises
        // simultaneously and doesn't cancel touches, so it never steals a scroll pan, a selection long-press,
        // or SwiftTerm's own tap handling. The read-only attach (no `control`) skips it.
        if control != nil {
            let armTap = UITapGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.handleArmTap))
            armTap.delegate = context.coordinator
            armTap.cancelsTouchesInView = false
            term.addGestureRecognizer(armTap)
        }

        // "Scroll the program" pan — for BOTH tmux-attached surfaces: the takeover (`control`) and the live
        // shell (`forwardScroll`). Both run `tmux attach`, which switches SwiftTerm to the full-screen
        // (alternate-screen) buffer, so there's no local SwiftTerm scrollback — a swipe must be forwarded to
        // tmux as mouse-wheel events (the iOS port of the desktop's `ScrollableTerminalView.handleScroll`),
        // and tmux (`mouse on`) scrolls its own 50k-line history. `handleWheelPan` self-gates on
        // `isCurrentBufferAlternate && mouseMode != .off`, so on a normal buffer it no-ops. Finger policy is
        // set in `updateUIView`: the takeover toggles 1↔2 fingers with `armed`; the live shell is always one
        // finger (it has no arming). It stands down during Select mode so a one-finger drag selects text.
        if control != nil || forwardScroll {
            let wheelPan = UIPanGestureRecognizer(target: context.coordinator,
                                                  action: #selector(Coordinator.handleWheelPan))
            wheelPan.delegate = context.coordinator
            wheelPan.cancelsTouchesInView = false
            term.addGestureRecognizer(wheelPan)
            context.coordinator.wheelPan = wheelPan

            // The alternate screen fills the viewport exactly (rows == visible), so the built-in pan would
            // rubber-band the whole terminal while the wheel-pan forwards. Kill the bounce.
            term.bounces = false
        }
        return term
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // The same terminal coordinator survives SwiftUI re-renders, while the selected card can change.
        // Refresh this closure rather than capturing the first route and fetching an image for a stale card.
        context.coordinator.onOpenImage = onOpenImage
        // Takeover chrome (T4) drives font + Select through the `control` handle; the Terminal-tab live
        // shell (T2) has no control and passes `selectMode` directly. Reflect whichever is active.
        if let control {
            let size = control.fontSize
            if abs(uiView.font.pointSize - size) > 0.5 {
                uiView.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
        }
        // Mouse reporting = "forward touches to the TUI". Gate it on typing being armed: while DISARMED the
        // takeover terminal is a look/scroll surface — reporting off means SwiftTerm's UIScrollView pan
        // scrolls the scrollback (a plain swipe, like a mobile page) and a tap arms instead of firing a
        // stray mouse click into the agent. While ARMED, reporting is on so the agent's TUI mouse works.
        // Select mode always forces it off so a drag selects text.
        //
        // The live shell (`forwardScroll`) keeps reporting OFF unconditionally: a plain one-finger swipe
        // scrolls tmux's history via the wheel-pan, so SwiftTerm's own touch→mouse forwarding must stand
        // down or a swipe would double-fire as a tmux mouse-drag / selection. This holds even now that the
        // live shell carries a `control` (for the Hide-keyboard button): the `forwardScroll` branch below
        // wins, so tap-to-arm never turns reporting on. Tapping still raises the keyboard (SwiftTerm's
        // single-tap falls through to `becomeFirstResponder` when reporting is off), and Select mode drives
        // text selection through SwiftTerm's selection path. The read-only attach passes no `control` and no
        // `forwardScroll`, so its `armed`-defaults-on behaviour is unchanged.
        let armed = control?.armed ?? true
        uiView.allowMouseReporting = forwardScroll
            ? false
            : armed && !((control?.selectMode ?? false) || selectMode)

        // Scroll finger policy, applied to BOTH the built-in UIScrollView pan and the wheel-forward pan
        // (`handleWheelPan`). Cap SwiftTerm's own mouse/selection pans (added lazily on mouse mode) at one
        // finger so a two-finger scroll can't double-fire as a mouse drag — but never the wheel-pan itself.
        // Re-applied every update since those pans can appear mid-session.
        // NOTE: `forwardScroll` is checked BEFORE `control != nil`. The live shell now carries a `control`
        // (for the Hide-keyboard button) yet must keep its one-finger scroll regardless of arm state — so it
        // takes this branch, not the takeover's `armed ? 2 : 1` policy below.
        if forwardScroll {
            // Live shell: a plain ONE-finger swipe always scrolls the history, armed or not (mouse reporting
            // stays off, so a one-finger drag can't reach a TUI mouse). Select mode lets the wheel-pan stand
            // down so a one-finger drag selects text instead.
            uiView.panGestureRecognizer.minimumNumberOfTouches = 1
            context.coordinator.wheelPan?.minimumNumberOfTouches = 1
            context.coordinator.selectModeActive = selectMode
            for g in uiView.gestureRecognizers ?? []
            where g !== uiView.panGestureRecognizer && g !== context.coordinator.wheelPan {
                (g as? UIPanGestureRecognizer)?.maximumNumberOfTouches = 1
            }
        } else if control != nil {
            // Takeover. DISARMED: one finger, so a plain swipe scrolls like a mobile page. ARMED: two
            // fingers, so a one-finger drag still reaches the agent's TUI mouse while two fingers scroll
            // without dropping the keyboard.
            uiView.panGestureRecognizer.minimumNumberOfTouches = armed ? 2 : 1
            context.coordinator.wheelPan?.minimumNumberOfTouches = armed ? 2 : 1
            context.coordinator.selectModeActive = (control?.selectMode ?? false) || selectMode
            for g in uiView.gestureRecognizers ?? []
            where g !== uiView.panGestureRecognizer && g !== context.coordinator.wheelPan {
                (g as? UIPanGestureRecognizer)?.maximumNumberOfTouches = 1
            }
        }
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    // `@preconcurrency`: SwiftTerm's `TerminalViewDelegate` predates Swift concurrency (its methods
    // aren't actor-isolated), but it only ever calls back on the main thread — so a `@MainActor`
    // coordinator satisfying it is correct, with a runtime check rather than a compile error.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate,
                             @preconcurrency UIGestureRecognizerDelegate {
        private let makeChannel: () -> TerminalByteChannel
        private let shouldReconnect: () -> Bool
        var onOpenImage: ((UUID) -> Void)?
        weak var terminal: TerminalView?
        private var channel: TerminalByteChannel?
        private var started = false
        private var intentionalClose = false
        private var reconnects = 0
        private let reconnectPolicy = TerminalReconnectPolicy()   // maxReconnects = 5 (was a local constant)
        /// A reconnect timer is already scheduled — so the `.failed`+`.closed` pair a single drop produces
        /// (or a stray later event) can't stack a second timer (#6).
        private var reconnectPending = false
        // Sticky-Ctrl state for soft-keyboard input (set from the accessory bar's Ctrl key via the control
        // handle). One-shot unless locked; consumed on the next typed keystroke.
        private var pendingCtrl = false
        private var ctrlLocked = false

        init(makeChannel: @escaping () -> TerminalByteChannel,
             shouldReconnect: @escaping () -> Bool = { true },
             onOpenImage: ((UUID) -> Void)? = nil) {
            self.makeChannel = makeChannel
            self.shouldReconnect = shouldReconnect
            self.onOpenImage = onOpenImage
        }

        func teardown() {
            intentionalClose = true
            channel?.close()
            channel = nil
        }

        // MARK: imperative control (PR T4 — accessory bar / arming / sticky Ctrl)

        /// Send raw bytes straight to the PTY — the accessory bar's explicit key taps, which always send
        /// regardless of arm state (arming only gates the soft keyboard + touch→mouse forwarding).
        func sendBytes(_ bytes: [UInt8]) { channel?.send(bytes) }

        /// Arm typing: show the soft keyboard by making the terminal first responder.
        func focus() { _ = terminal?.becomeFirstResponder() }
        /// Dismiss the soft keyboard.
        func blur() { _ = terminal?.resignFirstResponder() }

        /// Tap-to-arm: the user tapped the (disarmed) terminal to start typing. `TerminalControl.attach`
        /// wires this to `arm()` so the chrome's `armed` state tracks the keyboard SwiftTerm raises on tap.
        var onUserArmed: (() -> Void)?
        @objc func handleArmTap() { onUserArmed?() }

        // MARK: two-finger wheel forwarding (alternate screen)

        /// The scroll-forward pan installed in `makeUIView`. Held so `updateUIView` can set its finger count
        /// and so the mouse-pan cap can skip it.
        var wheelPan: UIPanGestureRecognizer?
        /// While Select mode is on, a one-finger drag should select text (SwiftTerm handles it), so the
        /// wheel-pan stands down. Set from `updateUIView`.
        var selectModeActive = false
        /// Sub-cell finger travel carried between pan updates so a slow drag scrolls line-by-line rather
        /// than stalling on integer truncation (xterm.js's `_wheelPartialScroll` accumulator).
        private var wheelAccum: CGFloat = 0
        /// Wheel events emitted per cell-height of travel. 1 = the high-precision-touch standard (kitty's
        /// `touch_scroll_multiplier` = 1): the finger already *is* the position, so no extra acceleration.
        /// The one knob if scrolling feels too slow/fast on device.
        private static let wheelEventsPerCell = 1

        /// Forward a two-finger swipe to the running program as mouse-wheel events (button 4 up / 5 down)
        /// so a full-screen agent TUI or tmux copy-mode scrolls its own history — the iOS port of the
        /// desktop's `ScrollableTerminalView.handleScroll`. Fires only on the ALTERNATE buffer with mouse
        /// reporting on (what tmux `mouse on` / agent TUIs use); on the normal buffer it no-ops so the
        /// UIScrollView pan scrolls the local scrollback. Independent of `armed` — scrolling is navigation,
        /// not stray input — and independent of `allowMouseReporting`, which only gates SwiftTerm's own
        /// tap/drag→mouse handlers.
        @objc func handleWheelPan(_ g: UIPanGestureRecognizer) {
            guard let term = terminal else { return }
            let t = term.getTerminal()
            // Forward only on the alternate buffer with mouse reporting on (tmux `mouse on` / agent TUI),
            // and never while Select mode wants the drag for text selection.
            guard t.isCurrentBufferAlternate, t.mouseMode != .off, !selectModeActive else { wheelAccum = 0; return }
            switch g.state {
            case .began:
                wheelAccum = 0
            case .changed:
                wheelAccum += g.translation(in: term).y
                g.setTranslation(.zero, in: term)
                let cell = max(1, term.bounds.height / CGFloat(max(1, t.rows)))   // points per row
                // Drag DOWN (Δ>0) reveals earlier lines → wheel up (button 4); drag up → wheel down (5).
                while abs(wheelAccum) >= cell {
                    let up = wheelAccum > 0
                    wheelAccum -= up ? cell : -cell
                    sendWheel(up: up, at: g.location(in: term), terminal: t)
                }
            case .ended, .cancelled, .failed:
                wheelAccum = 0
            default:
                break
            }
        }

        private func sendWheel(up: Bool, at point: CGPoint, terminal t: Terminal) {
            guard let term = terminal else { return }
            let flags = t.encodeButton(button: up ? 4 : 5, release: false, shift: false, meta: false, control: false)
            let cols = max(1, t.cols), rows = max(1, t.rows)
            let col = min(cols - 1, max(0, Int(point.x / max(1, term.bounds.width) * CGFloat(cols))))
            let row = min(rows - 1, max(0, Int(point.y / max(1, term.bounds.height) * CGFloat(rows))))
            for _ in 0..<Self.wheelEventsPerCell {
                t.sendEvent(buttonFlags: flags, x: col, y: row)
            }
        }

        /// Let the tap-to-arm recogniser fire alongside SwiftTerm's own tap/pan/long-press gestures so it
        /// only *observes* the tap — it never blocks a scroll pan, a selection, or SwiftTerm's tap handling.
        nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

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
                reconnectPending = false
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
            // #7: a takeover attach must NOT re-run its exclusive `detach-client` recipe once the phone has
            // lost the lease — reconnecting then would kick the desktop that just retook control. Drop the
            // channel instead and let the surface show its "desktop retook control" state.
            guard shouldReconnect() else {
                intentionalClose = true
                channel?.close()
                feedStatus("[control returned to desktop — disconnected]")
                return
            }
            // #6: one drop emits at most one reconnect. Never stack a second timer.
            guard !reconnectPending else { return }
            guard let delaySecs = reconnectPolicy.delay(forAttempt: reconnects + 1) else {
                // Give up — but tear the channel down so an owned SSH session isn't left leaking (#5); the
                // scenePhase-active reset (`retryConnection`) is the way back.
                intentionalClose = true
                channel?.close()
                feedStatus("[giving up after \(reconnectPolicy.maxReconnects) attempts — reopen or foreground to retry]")
                return
            }
            reconnectPending = true
            reconnects += 1
            let delay = Double(delaySecs)   // 1,2,4,8,8…
            let cols = term.getTerminal().cols, rows = term.getTerminal().rows
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.intentionalClose else { return }
                self.reconnectPending = false
                self.feedStatus("[reconnecting…]")
                // close() first: a remote-initiated drop leaves the channel non-idle, so start() would
                // no-op on its idempotency guard. close() resets it to a restartable state; the new SSH
                // link re-attaches the SAME server-side view session (recipe is idempotent). The channel
                // generation-stamps this fresh attempt, so the close()'s own `.closed` can't drive a reflap.
                self.channel?.close()
                self.channel?.start(cols: cols, rows: rows)
            }
        }

        /// Reset the reconnect budget and re-establish after a give-up / lease-loss disconnect. Wired to the
        /// owning view's `scenePhase == .active` so foregrounding the app retries a dead terminal (the "pull
        /// to retry" affordance the copy used to promise but never had a gesture for — LOW).
        func retryConnection() {
            guard let term = terminal, started else { return }
            guard intentionalClose || reconnects >= reconnectPolicy.maxReconnects else { return }   // only revive a dead one
            // Never revive a takeover terminal we no longer hold the lease for — that would re-run the
            // exclusive recipe and kick the current owner (#7 again, via the manual retry path).
            guard shouldReconnect() else { return }
            intentionalClose = false
            reconnectPending = false
            reconnects = 0
            let cols = term.getTerminal().cols, rows = term.getTerminal().rows
            feedStatus("[reconnecting…]")
            channel?.close()
            channel?.start(cols: cols, rows: rows)
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
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let id = TranscriptImageLink.referenceID(from: link) else { return }
            onOpenImage?(id)
        }
        func bell(source: TerminalView) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
