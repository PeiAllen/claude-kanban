import SwiftUI
import OrchestraCore
#if canImport(SwiftTerm)
import SwiftTerm
#endif

/// The live agent terminal — a SwiftTerm `LocalProcessTerminalView` attaching to the card's tmux
/// session directly (no byte-proxying through the daemon). When SwiftTerm isn't linked (e.g. building
/// the core without the app dependency), a minimal placeholder is shown instead.
struct AgentTerminalView: NSViewRepresentable {
    /// Where the tmux server lives: the local machine, or a remote box reached over the app's shared SSH
    /// control socket (multiplexed on the master — no extra auth/forward).
    enum TerminalHost: Equatable {
        case local
        case remote(controlPath: String, sshTarget: String)
    }

    let socket: String
    let session: String          // "orchestra-<id>"
    let window: String           // "agent"
    var host: TerminalHost       // local tmux vs remote tmux over the SSH control socket
    var background: SwiftUI.Color  // app theme — terminal opens in (and switches to) the app's mode
    var foreground: SwiftUI.Color
    var autofocus: Bool          // grab keyboard focus when the view mounts (e.g. opening a card)
    /// Called whenever this terminal *becomes* the window's first responder — by keyboard descent OR a
    /// mouse click into it. Lets the owner keep `focusZone` (and thus the inspector focus ring + chip)
    /// honest without polling the responder chain.
    var onFocused: (() -> Void)?

    init(socket: String = Config.tmuxSocket, session: String, window: String = "agent",
         host: TerminalHost = .local,
         background: SwiftUI.Color, foreground: SwiftUI.Color, autofocus: Bool = false,
         onFocused: (() -> Void)? = nil) {
        self.socket = socket; self.session = session; self.window = window; self.host = host
        self.background = background; self.foreground = foreground
        self.autofocus = autofocus
        self.onFocused = onFocused
    }

    #if canImport(SwiftTerm)
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        ScrollableTerminalView.installScrollMonitorIfNeeded()
        let term = ScrollableTerminalView(frame: .zero)
        term.processDelegate = context.coordinator
        term.font = Self.terminalFont
        // SwiftTerm v1.13.0 defaults its 256-colour palette to a "base16 LAB" strategy that re-derives
        // the whole 16–255 cube from the active theme's colours. That remaps fixed xterm indices: e.g.
        // 231 (normally pure white) becomes the theme *foreground*, so a TUI that uses 48;5;231 for a
        // white-box background — Claude Code's hover/expand previews — paints a solid black rectangle in
        // a light theme. Force the standard fixed xterm palette so indexed colours mean what apps expect.
        term.getTerminal().ansi256PaletteStrategy = .xterm
        term.termWindow = window        // tag so FocusBridge can target agent vs shell terminals
        term.onBecameFirstResponder = onFocused
        applyColors(term)
        context.coordinator.attached = "\(session):\(window)"
        attach(term)
        // The view has no window yet at make time, so we can't grab focus now. Flag it and let the view
        // claim first responder the instant it's actually mounted (see ScrollableTerminalView).
        if autofocus { term.claimFocusOnMount = true }
        return term
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        applyColors(nsView)   // re-tint when the app toggles light/dark
        // Safety net: if SwiftUI reused this NSView for a different card (despite the `.id` upstream),
        // re-point it at the right tmux target instead of leaving it on the previous card's session.
        let target = "\(session):\(window)"
        (nsView as? ScrollableTerminalView)?.termWindow = window
        (nsView as? ScrollableTerminalView)?.onBecameFirstResponder = onFocused
        if context.coordinator.attached != target {
            context.coordinator.attached = target
            attach(nsView)
            // By updateNSView the view is already in a window, so focus it directly.
            if autofocus { (nsView as? ScrollableTerminalView)?.claimFocusNow() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A real monospace font (SwiftTerm's default lacks many glyphs). Prefers an installed Nerd Font so
    /// powerline / git prompt icons render; falls back to SF Mono, then Menlo. CoreText still cascades
    /// to a Nerd Font for individual missing glyphs if one is installed under any family name.
    static let terminalFont: NSFont = {
        let size: CGFloat = 12.5
        // Homebrew's nerd-font casks register families as "<Name> Nerd Font Mono"; the manual
        // nerd-fonts release also ships "<Name> NF". List both so either install is picked up. The
        // "Mono" variant is single-width (ideal for a terminal). Falls back to SF Mono, then Menlo.
        let preferred = ["MesloLGS Nerd Font Mono", "MesloLGS NF", "MesloLGM Nerd Font Mono",
                         "JetBrainsMono Nerd Font Mono", "FiraCode Nerd Font Mono",
                         "Hack Nerd Font Mono", "SauceCodePro Nerd Font Mono", "SF Mono", "Menlo"]
        for name in preferred {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }()

    private func applyColors(_ term: LocalProcessTerminalView) {
        let bg = NSColor(background), fg = NSColor(foreground)
        term.nativeBackgroundColor = bg
        term.nativeForegroundColor = fg
        term.layer?.backgroundColor = bg.cgColor
        // Also tell the *emulator* its colours so OSC 10/11 background/foreground queries report the live
        // theme. SwiftTerm otherwise answers those queries with its hard-coded defaults (black bg)
        // regardless of what we actually render, so a TUI like Claude Code — which queries OSC 11 to pick
        // a light/dark theme — can't detect our theme. (Needs tmux `allow-passthrough on`, set in
        // embedded.conf, so the OSC 11 reply can traverse tmux back to the program.)
        let t = term.getTerminal()
        if let f = Self.stColor(fg) { t.foregroundColor = f }
        if let b = Self.stColor(bg) { t.backgroundColor = b }
    }

    /// Convert an `NSColor` to SwiftTerm's 16-bit `Color`, via sRGB. Returns nil if the colour can't be
    /// resolved into RGB components (so we leave the emulator's existing colour untouched rather than
    /// crash on `redComponent` of a non-RGB colour).
    private static func stColor(_ ns: NSColor) -> SwiftTerm.Color? {
        guard let c = ns.usingColorSpace(.sRGB) else { return nil }
        func chan(_ v: CGFloat) -> UInt16 { UInt16((max(0, min(1, v)) * 65535).rounded()) }
        return SwiftTerm.Color(red: chan(c.redComponent), green: chan(c.greenComponent), blue: chan(c.blueComponent))
    }

    private func attach(_ term: LocalProcessTerminalView) {
        // A Finder/launchd-launched app has a minimal PATH that omits Homebrew (where tmux lives), so
        // hand the shell an augmented PATH so bare `tmux` in the attach script resolves (otherwise the
        // terminal stays black).
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Proc.augmentedPATH(env["PATH"])
        // A GUI-launched app inherits no locale, so the attaching tmux client falls back to non-UTF-8
        // and renders multibyte glyphs (the logo's block chars, em-dashes, rules) as `_`. Force UTF-8.
        Proc.ensureUTF8Locale(&env)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envArray = env.map { "\($0.key)=\($0.value)" }
        // SwiftTerm prepends argv[0] (the executable) itself, so args must start at argv[1] — i.e.
        // just ["-c", script], NOT ["sh", "-c", script] (which would make sh treat the extra "sh" as a
        // script file and fail with "cannot execute binary file").
        switch host {
        case .local:
            term.startProcess(executable: "/bin/sh", args: ["-c", attachScript()], environment: envArray)
        case let .remote(controlPath, sshTarget):
            // Ride the shared SSH master (-S). The grouped-view-session attach script runs REMOTELY
            // against the box's tmux server; `socket` is the remote tmux -L name.
            let (exe, args) = RemoteCommands.remoteTmuxAttach(
                target: sshTarget, controlPath: controlPath, script: attachScript())
            term.startProcess(executable: exe, args: args, environment: envArray)
        }
    }

    /// Attach through a per-window *grouped* "view" session instead of the base session directly.
    /// Several SwiftTerm clients (agent + each shell) are visible at once; tmux keeps every client of
    /// a single session on the same active window, so attaching them all to `session` would make
    /// opening a shell yank the agent terminal onto the shell window. A grouped view session shares
    /// the window list but holds its own active window, keeping the panes disjoint. The view session
    /// is reused if it already exists (e.g. after deselect/reselect).
    private func attachScript() -> String {
        let view = SessionManager.viewSession(session, window)
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let sock = q(socket), v = q(view), base = q(session), win = q("\(view):\(window)")
        return """
        tmux -L \(sock) new-session -d -s \(v) -t \(base) 2>/dev/null
        tmux -L \(sock) select-window -t \(win) 2>/dev/null
        exec tmux -L \(sock) attach -t \(v)
        """
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        /// The "session:window" this NSView is currently attached to, so updateNSView can detect reuse.
        var attached: String?

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
    #else
    func makeNSView(context: Context) -> NSView {
        let v = NSTextField(labelWithString: "Terminal requires SwiftTerm.\nAttach: tmux -L \(socket) attach -t \(session):\(window)")
        v.maximumNumberOfLines = 0
        v.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let container = NSView()
        container.addSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    #endif
}

#if canImport(SwiftTerm)
/// A `LocalProcessTerminalView` that makes the mouse wheel scroll tmux's scrollback.
///
/// tmux attaches as a full-screen application, which switches SwiftTerm to the *alternate* screen
/// buffer. The alternate buffer has no SwiftTerm-side scrollback, so the stock `scrollWheel` — which
/// only scrolls SwiftTerm's own buffer — does nothing, and it never forwards the wheel to the running
/// program either. The net effect was that nothing scrolled in any pane.
///
/// When mouse reporting is active (our embedded tmux config sets `mouse on`), we instead forward the
/// wheel as mouse-wheel button events, so tmux enters copy-mode and scrolls its own history — exactly
/// how Terminal.app and iTerm2 drive a tmux client. On the normal buffer we fall back to SwiftTerm's
/// native scrollback.
///
/// SwiftTerm declares `scrollWheel(with:)` and `mouseMoved(with:)` as `public` (not `open`), so we
/// can't override them from this module. Instead a single app-wide local event monitor catches scroll
/// and motion events and, when the pointer is over one of our terminals, handles them before SwiftTerm's
/// own handlers run:
///   • scroll → forwarded to tmux via `handleScroll` (SwiftTerm's own wheel handling is a no-op here).
///   • no-button hover motion → swallowed (see below).
///
/// Why drop hover motion: SwiftTerm encodes a buttonless move as `CSI<32;…m`, which in the SGR mouse
/// protocol is a *left-button release* (`m` = release, low bits = button 0) — not the no-button motion
/// `CSI<35;…M` that xterm/Terminal.app send. A TUI like Claude Code therefore reads every hover as a
/// click and opens the item under the cursor (flashing its preview box). Dropping hover motion makes
/// expansion happen on a real click only; button drags (text selection) and clicks still reach SwiftTerm
/// normally, so nothing else regresses.
final class ScrollableTerminalView: LocalProcessTerminalView {
    private static var monitorInstalled = false

    /// Which tmux window this terminal is attached to ("agent" / "shell-N"). Read by FocusBridge (via
    /// KVC) to move keyboard focus between the agent terminal and shell tabs. `@objc` for KVC.
    @objc var termWindow: String = "agent"

    /// When set, the view grabs keyboard focus the moment it's mounted in a window. At `makeNSView`
    /// time the view has no window yet, and polling on a timer races the mount (the old approach drained
    /// its retries before the view was ever in a window, so focus never landed). `viewDidMoveToWindow`
    /// is the exact lifecycle hook — no guessing.
    var claimFocusOnMount = false

    /// Fired when this terminal takes keyboard focus by a mouse click (see the shared monitor below).
    /// The owner uses it to sync `focusZone` so the inspector focus ring / context chip stay truthful
    /// even when focus is taken by the mouse rather than a keyboard verb. (`becomeFirstResponder` is
    /// `public`-not-`open` in SwiftTerm, so we can't override it — hence the click monitor instead.)
    var onBecameFirstResponder: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard claimFocusOnMount, window != nil else { return }
        claimFocusOnMount = false
        claimFocusNow()
    }

    /// Make this terminal the window's first responder so typed keys reach the agent without an extra
    /// click. Deferred one runloop tick so SwiftUI's own focus/layout pass on the same update can't
    /// immediately clobber it.
    func claimFocusNow() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    /// Install the shared scroll/motion monitor once. Safe to call repeatedly.
    static func installScrollMonitorIfNeeded() {
        guard !monitorInstalled else { return }
        monitorInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .mouseMoved, .leftMouseDown]) { event in
            guard let hit = event.window?.contentView?.hitTest(event.locationInWindow) else { return event }
            var view: NSView? = hit
            while let cur = view {
                if let term = cur as? ScrollableTerminalView {
                    switch event.type {
                    case .scrollWheel:
                        return term.handleScroll(event) ? nil : event   // nil = consumed (forwarded to tmux)
                    case .mouseMoved:
                        return nil                                       // swallow hover motion (see above)
                    case .leftMouseDown:
                        // Clicking into a terminal makes it first responder — notify the owner so
                        // `focusZone` (and the inspector focus ring / chip) tracks the mouse, then let
                        // the click reach SwiftTerm normally (never consumed).
                        term.onBecameFirstResponder?()
                        return event
                    default:
                        return event
                    }
                }
                view = cur.superview
            }
            return event   // not over a terminal — leave board/list scrolling alone
        }
    }

    /// Forward the wheel to the running program as mouse-wheel events. Returns `true` if it consumed
    /// the event (alternate buffer with mouse reporting on), `false` to let SwiftTerm scroll natively.
    func handleScroll(_ event: NSEvent) -> Bool {
        guard event.deltaY != 0 else { return false }
        guard terminal != nil, terminal.isCurrentBufferAlternate,
              allowMouseReporting, terminal.mouseMode != .off else { return false }
        // Wheel up = button 4, wheel down = button 5 (xterm convention).
        let flags = terminal.encodeButton(button: event.deltaY > 0 ? 4 : 5,
                                          release: false, shift: false, meta: false, control: false)
        let (col, row) = gridLocation(of: event)
        // A discrete mouse wheel delivers a few large-delta events; a trackpad streams many small ones
        // (with momentum). Emit a few ticks for the former and one per event for the latter so both
        // feel natural rather than glacial.
        let ticks = event.hasPreciseScrollingDeltas ? 1 : max(1, min(5, Int(abs(event.deltaY).rounded(.up))))
        for _ in 0..<ticks {
            terminal.sendEvent(buttonFlags: flags, x: col, y: row)
        }
        return true
    }

    /// The grid cell under the pointer, clamped in-bounds. tmux only needs this to pick the pane the
    /// wheel is over; with our single full-window pane any valid cell works. AppKit's view origin is
    /// bottom-left while terminal rows count from the top, so y is inverted.
    private func gridLocation(of event: NSEvent) -> (col: Int, row: Int) {
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let p = convert(event.locationInWindow, from: nil)
        let cols = max(1, terminal.cols), rows = max(1, terminal.rows)
        let col = min(cols - 1, max(0, Int(p.x / bounds.width * CGFloat(cols))))
        let row = min(rows - 1, max(0, Int((bounds.height - p.y) / bounds.height * CGFloat(rows))))
        return (col, row)
    }
}
#endif
