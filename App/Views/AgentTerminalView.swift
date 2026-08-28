import SwiftUI
import OrchestraUI
import OrchestraCore
import OrchestraKit
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
    var terminalImagePaste: AgentCapabilities.TerminalImagePaste
    /// Fetches a daemon-owned image payload for a deliberate opaque transcript-link activation. The
    /// terminal never receives a source path or a general URL handler.
    var loadTranscriptImage: ((UUID) async throws -> TranscriptImagePayload)? = nil
    /// Surfaces a reference that no longer resolves. The terminal can't render this itself — QuickLook
    /// owns the window — so the owner reports it in the app's own vocabulary.
    var onTranscriptImageUnavailable: ((String) -> Void)? = nil
    /// Called whenever this terminal *becomes* the window's first responder — by keyboard descent OR a
    /// mouse click into it. Lets the owner keep `focusZone` (and thus the inspector focus ring + chip)
    /// honest without polling the responder chain.
    var onFocused: (() -> Void)?
    /// When set, a dead pane auto-re-attaches while this returns true (a `.live` card on a live link).
    /// nil (default) → no auto-reattach, so ShellTabsView's shells opt out unchanged.
    var attachWhileLiveGate: (() -> Bool)? = nil   // named distinctly from the Coordinator's own `attachWhileLive`
    /// Whether this terminal is on-screen (visible, not scrolled out / collapsed / a non-selected tab).
    /// Combined with `\.animationsActive` (window/app looked-at) it drives render-parking — see
    /// `TerminalRenderParkingPolicy`. Defaults true; a container that can hide the terminal passes false.
    var visible: Bool = true

    /// The idle gate from the animation fix: false when the window is occluded/miniaturized or the app is
    /// inactive. Reading it here makes SwiftUI re-run `updateNSView` when it flips, so the terminal parks
    /// and unparks with the rest of the board.
    @Environment(\.animationsActive) private var animationsActive
    /// Shared by every desktop agent and shell terminal, and persisted across launches. Updating this
    /// property re-runs `updateNSView`, where the mounted SwiftTerm view recalculates its normal grid.
    @AppStorage(TerminalFontSize.preferenceKey) private var terminalFontSize = TerminalFontSize.defaultPointSize
    /// The surrounding interface canvas scales ordinary SwiftUI content. SwiftTerm is an AppKit view,
    /// so it cancels this multiplier and keeps the terminal's persisted font physically independent.
    @Environment(\.interfaceScale) private var interfaceScale

    init(socket: String = Config.tmuxSocket, session: String, window: String = "agent",
         host: TerminalHost = .local,
         background: SwiftUI.Color, foreground: SwiftUI.Color, autofocus: Bool = false,
         terminalImagePaste: AgentCapabilities.TerminalImagePaste = .direct,
         loadTranscriptImage: ((UUID) async throws -> TranscriptImagePayload)? = nil,
         onTranscriptImageUnavailable: ((String) -> Void)? = nil,
         onFocused: (() -> Void)? = nil,
         attachWhileLiveGate: (() -> Bool)? = nil,
         visible: Bool = true) {
        self.socket = socket; self.session = session; self.window = window; self.host = host
        self.background = background; self.foreground = foreground
        self.autofocus = autofocus
        self.terminalImagePaste = terminalImagePaste
        self.loadTranscriptImage = loadTranscriptImage
        self.onTranscriptImageUnavailable = onTranscriptImageUnavailable
        self.onFocused = onFocused
        self.attachWhileLiveGate = attachWhileLiveGate
        self.visible = visible
    }

    #if canImport(SwiftTerm)
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        ScrollableTerminalView.installScrollMonitorIfNeeded()
        let term = ScrollableTerminalView(frame: .zero)
        term.installClipboardOSCHandler()
        term.processDelegate = context.coordinator
        term.font = Self.terminalFont(size: CGFloat(TerminalFontSize.renderedPointSize(
            for: terminalFontSize, interfaceScale: interfaceScale)))
        // SwiftTerm v1.13.0 defaults its 256-colour palette to a "base16 LAB" strategy that re-derives
        // the whole 16–255 cube from the active theme's colours. That remaps fixed xterm indices: e.g.
        // 231 (normally pure white) becomes the theme *foreground*, so a TUI that uses 48;5;231 for a
        // white-box background — Claude Code's hover/expand previews — paints a solid black rectangle in
        // a light theme. Force the standard fixed xterm palette so indexed colours mean what apps expect.
        term.getTerminal().ansi256PaletteStrategy = .xterm
        // Hover movement is intentionally swallowed below because SwiftTerm encodes it as a mouse
        // release that Claude treats as a click. Its default `.hoverWithModifier` link mode therefore
        // cannot activate reliably here; this keeps explicit OSC 8 links Command-click-only without
        // needing a hover event to reach tmux.
        term.linkHighlightMode = .alwaysWithModifier
        term.termWindow = window        // tag so FocusBridge can target agent vs shell terminals
        term.onBecameFirstResponder = onFocused
        term.terminalImagePaste = terminalImagePaste
        term.configureImageLinkHandler { [weak coordinator = context.coordinator] referenceID in
            coordinator?.openTranscriptImage(referenceID)
        }
        applyColors(term, coordinator: context.coordinator)
        context.coordinator.attached = "\(session):\(window)"
        context.coordinator.loadTranscriptImage = loadTranscriptImage
        context.coordinator.transcriptImagePreview.onUnavailable = onTranscriptImageUnavailable
        context.coordinator.attachWhileLive = { [attachWhileLiveGate] in attachWhileLiveGate?() ?? false }
        context.coordinator.reattach = { [weak term] in if let term { self.attach(term) } }
        attach(term)
        context.coordinator.paneAlive = true                               // a process is now (attempting to be) up
        context.coordinator.wasLive = attachWhileLiveGate?() ?? false      // seed the edge detector (usually false at birth)
        // The view has no window yet at make time, so we can't grab focus now. Flag it and let the view
        // claim first responder the instant it's actually mounted (see ScrollableTerminalView).
        if autofocus { term.claimFocusOnMount = true }
        term.renderingParked = TerminalRenderParkingPolicy.shouldPark(
            animationsActive: animationsActive, onScreen: visible)
        return term
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // A font assignment makes SwiftTerm recompute its cell grid and resize the existing pty. Guard it
        // so unrelated SwiftUI updates (theme, telemetry, focus) do not repeatedly reflow the TUI.
        let requestedFontSize = CGFloat(TerminalFontSize.renderedPointSize(
            for: terminalFontSize, interfaceScale: interfaceScale))
        if abs(nsView.font.pointSize - requestedFontSize) > .ulpOfOne {
            nsView.font = Self.terminalFont(size: requestedFontSize)
        }
        applyColors(nsView, coordinator: context.coordinator)   // re-tint when the app toggles light/dark
        context.coordinator.loadTranscriptImage = loadTranscriptImage
        context.coordinator.transcriptImagePreview.onUnavailable = onTranscriptImageUnavailable
        // Re-install every update so the gate closure snapshots the CURRENT phase/connection (a stale
        // closure captured at makeNSView time would gate reattach on the card's state when it first
        // mounted, not its state at the moment the pane actually dies).
        context.coordinator.attachWhileLive = { [attachWhileLiveGate] in attachWhileLiveGate?() ?? false }
        context.coordinator.reattach = { [weak nsView] in if let nsView { self.attach(nsView) } }
        // Safety net: if SwiftUI reused this NSView for a different card (despite the `.id` upstream),
        // re-point it at the right tmux target instead of leaving it on the previous card's session.
        let target = "\(session):\(window)"
        if let terminal = nsView as? ScrollableTerminalView {
            terminal.termWindow = window
            terminal.onBecameFirstResponder = onFocused
            terminal.terminalImagePaste = terminalImagePaste
            terminal.configureImageLinkHandler { [weak coordinator = context.coordinator] referenceID in
                coordinator?.openTranscriptImage(referenceID)
            }
            // Park/unpark rendering with the window/app gate + this terminal's on-screen state. SwiftUI
            // re-runs `updateNSView` when `animationsActive` flips (it's read above), so this tracks the
            // window being occluded/backgrounded and the row being scrolled out / collapsed.
            terminal.renderingParked = TerminalRenderParkingPolicy.shouldPark(
                animationsActive: animationsActive, onScreen: visible)
        }
        let isLive = context.coordinator.attachWhileLive()
        if context.coordinator.attached != target {
            context.coordinator.dismissTranscriptImage()
            context.coordinator.attached = target
            context.coordinator.resetForNewTarget()   // a genuinely new terminal ⇒ fresh reconnect budget
            context.coordinator.paneAlive = true
            attach(nsView)
            // By updateNSView the view is already in a window, so focus it directly.
            if autofocus { (nsView as? ScrollableTerminalView)?.claimFocusNow() }
        } else if TerminalReattachDecision.shouldReattachOnLiveEdge(
                    paneAlive: context.coordinator.paneAlive,
                    wasLive: context.coordinator.wasLive, isLive: isLive) {
            // F1: non-blocking spawn (PR4b) returns a `.creatingWorktree` card before the tmux `agent`
            // session exists, so the birth-time attach died (session absent) and `processTerminated` never
            // scheduled a reconnect (the live gate was false at death). The card has now reached a
            // renderable-live state → re-attach the blank pane ONCE and re-arm the reconnect budget (reused
            // from `resetForNewTarget`) so a later independent drop still gets the full backoff. Idempotent:
            // a live pane (`paneAlive == true`) never takes this branch, so a healthy pane is left untouched.
            context.coordinator.resetForNewTarget()
            context.coordinator.paneAlive = true
            attach(nsView)
        }
        // Record the gate value so the NEXT update can detect the false→true edge (and not re-fire on it).
        context.coordinator.wasLive = isLive
    }

    /// Kill the pane's child when SwiftUI discards the view — otherwise every teardown orphans the
    /// process `startProcess` forked and leaks its pty.
    ///
    /// This is not optional bookkeeping: `ShellTabsView`/`InspectorView` put an `.id(…)` on this view,
    /// so SwiftUI destroys and recreates the NSView on every shell-tab / card / connection switch, and
    /// each recreation is a fresh forkpty. `deinit` cannot save us — SwiftTerm's `LocalProcess.deinit`
    /// neither kills the child nor closes the pty master, and its `DispatchIO` read handler retains the
    /// process anyway while the child is alive, so it never even runs. Teardown has to be explicit.
    /// `terminate()` closes the `DispatchIO` (whose cleanup handler closes the master fd — the kernel
    /// only frees a pty slot once BOTH ends are closed) and SIGTERMs the child. That child is the tmux
    /// *client* (the attach script `exec`s it) or the `ssh` for a remote host, so this detaches the pane
    /// without touching the tmux server, session, or the agent running inside it.
    ///
    /// Guarded on `running`: once a child exits, SwiftTerm has `waitpid`-reaped it, so its `shellPid`
    /// may since have been recycled by the OS and `terminate()` would SIGTERM an unrelated process.
    /// A pane that's already dead needs no help — with the read handler released, the `LocalProcess`
    /// deallocs and `DispatchIO` closes the master fd on its way out (measured: dead panes hold flat).
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        MainActor.assumeIsolated {   // SwiftUI tears views down on the main thread
            // Retire the coordinator FIRST: a backoff reconnect queued by `processTerminated` must not
            // fire against a view SwiftUI has already discarded — that would fork a fresh pty into a
            // dead view with nothing left to ever terminate it (the leak, re-armed).
            coordinator.tearDown()
            if nsView.process?.running == true { nsView.terminate() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A real monospace font (SwiftTerm's default lacks many glyphs). Prefers an installed Nerd Font so
    /// powerline / git prompt icons render; falls back to SF Mono, then Menlo. CoreText still cascades
    /// to a Nerd Font for individual missing glyphs if one is installed under any family name.
    static func terminalFont(size: CGFloat) -> NSFont {
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
    }

    private func applyColors(_ term: LocalProcessTerminalView, coordinator: Coordinator) {
        let bg = NSColor(background), fg = NSColor(foreground)
        let terminal = term.getTerminal()
        let terminalBackground = Self.stColor(bg)
        let terminalForeground = Self.stColor(fg)
        if let terminalBackground, let terminalForeground {
            let signature = TerminalThemeSignature(
                background: .init(red: terminalBackground.red, green: terminalBackground.green, blue: terminalBackground.blue),
                foreground: .init(red: terminalForeground.red, green: terminalForeground.green, blue: terminalForeground.blue))
            let paletteChanged = coordinator.terminalThemeChangeGate.shouldApply(signature)
            let nativeMatches = term.nativeBackgroundColor.isEqual(bg) && term.nativeForegroundColor.isEqual(fg)
            let emulatorMatches = terminal.backgroundColor == terminalBackground && terminal.foregroundColor == terminalForeground
            if !paletteChanged && nativeMatches && emulatorMatches { return }
        }

        // `native*Color` updates the emulator too, which makes OSC 10/11 foreground/background queries
        // report the live theme. Avoid calling the emulator setters a second time: each assignment reaches
        // SwiftTerm's delegate and invalidates its whole display cache.
        if !term.nativeBackgroundColor.isEqual(bg) { term.nativeBackgroundColor = bg }
        if !term.nativeForegroundColor.isEqual(fg) { term.nativeForegroundColor = fg }
        if term.layer?.backgroundColor != bg.cgColor { term.layer?.backgroundColor = bg.cgColor }
    }

    /// Convert an `NSColor` to SwiftTerm's 16-bit `Color` using its native setter's exact device-RGB
    /// conversion. Returns nil if the colour can't be resolved, so we leave the emulator untouched rather
    /// than crash on `redComponent` of a non-RGB colour.
    private static func stColor(_ ns: NSColor) -> SwiftTerm.Color? {
        guard let c = ns.usingColorSpace(.deviceRGB) else { return nil }
        func chan(_ v: CGFloat) -> UInt16 { UInt16(max(0, min(1, v)) * 65535) }
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
        // The grouped "view session" attach recipe (non-exclusive) — one source of truth in
        // `TmuxAttach`, shared verbatim with the iOS terminal host so phone and desktop attach
        // identically. See TmuxAttach.attachScript for the step-by-step rationale.
        TmuxAttach.attachScript(socket: socket, session: session, window: window)
    }

    // `@MainActor` + `@preconcurrency`: SwiftTerm's `LocalProcessTerminalViewDelegate` predates Swift
    // concurrency (its callbacks aren't actor-isolated), but it only ever calls back on the main thread —
    // so a main-actor coordinator is correct, and it lets the `DispatchQueue.main` reconnect closure (which
    // is main-actor-isolated) capture `self` without a data-race diagnostic. Mirrors the iOS Coordinator.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
        /// The "session:window" this NSView is currently attached to, so updateNSView can detect reuse.
        var attached: String?
        /// The caller refreshes this on every SwiftUI update, so a reused terminal always resolves an
        /// opaque reference against its current card rather than the card that first mounted the view.
        var loadTranscriptImage: ((UUID) async throws -> TranscriptImagePayload)?
        let transcriptImagePreview = TranscriptImagePreviewPresenter()
        private let reconnectPolicy = TerminalReconnectPolicy()
        private var reconnects = 0
        private var reconnectPending = false
        /// A reattach only counts as SUCCESS if the process stays alive past this window — see below. Cancelled
        /// (never fires) if the pane re-exits first, so a rapid tmux-gone flap can never reset the budget.
        private var stabilizeWork: DispatchWorkItem?
        private let stabilizeWindow: TimeInterval = 5   // a failed `tmux attach` exits ~instantly; 5s ⇒ genuinely up
        /// Bumped when the attach target changes; a backoff block captures it and bails if it no longer matches,
        /// so a stale reattach queued against the OLD target can't fire against the new one.
        private var attachGeneration = 0
        /// Set by the representable's update from the owning view: is this card renderable-live right now?
        /// (Derived from `displayState(phase:connection:).statusKey == .running/.idle/.needsPermission` — i.e.
        /// a `.live` phase on a live link. A dead/creating card must NOT auto-re-attach.)
        var attachWhileLive: () -> Bool = { false }
        /// Re-attach closure the representable installs (calls `attach(term)` on the tracked view).
        var reattach: () -> Void = {}
        /// Is the attached terminal process currently up? Set true at each attach, false in
        /// `processTerminated`. Read by the F1 reattach-on-live gate so a HEALTHY pane is never re-attached.
        var paneAlive = false
        /// The live gate's value on the PREVIOUS `updateNSView`, so the next update can detect the false→true
        /// `→ live` edge (F1) — and act on the edge only, never re-firing every subsequent update.
        var wasLive = false
        /// Set once SwiftUI has torn the view down (see `dismantleNSView`). A dismantled coordinator is
        /// inert: it never reconnects again, so a late `processTerminated` — or a backoff block that was
        /// already in flight — can't resurrect a pane whose view is gone (and leak its pty).
        private var dismantled = false
        /// The terminal's app-controlled palette last applied to this view. Task telemetry can re-render
        /// this representable without changing the theme; preserve SwiftTerm's display cache in that case.
        var terminalThemeChangeGate = TerminalThemeChangeGate()

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func openTranscriptImage(_ referenceID: UUID) {
            guard let loadTranscriptImage else { return }
            transcriptImagePreview.show(referenceID: referenceID, load: loadTranscriptImage)
        }

        func dismissTranscriptImage() {
            transcriptImagePreview.dismiss()
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            // The pane died: if a stabilize window was pending, this reattach did NOT survive it → keep the
            // (already-incremented) budget so the flap stays bounded. Never reset here.
            stabilizeWork?.cancel(); stabilizeWork = nil
            paneAlive = false   // F1: a dead pane is a candidate for the reattach-on-live edge
            guard !dismantled else { return }   // the view is gone — never re-fork into it
            guard !reconnectPending, attachWhileLive() else { return }
            guard let delaySecs = reconnectPolicy.delay(forAttempt: reconnects + 1) else { return }  // budget spent → stop
            reconnectPending = true
            reconnects += 1
            let gen = attachGeneration   // capture: a target change (resetForNewTarget) invalidates this block
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delaySecs)) { [weak self] in
                guard let self, self.attachGeneration == gen, self.attachWhileLive() else {
                    self?.reconnectPending = false; return
                }
                self.reconnectPending = false
                self.reattach()
                self.paneAlive = true       // a fresh process is up again (the stabilize window judges if it sticks)
                self.scheduleStabilize()   // if THIS reattach survives the window, restore the full budget
            }
        }

        /// A reattach that survives `stabilizeWindow` is a genuine success (the iOS `.connected` analog — the
        /// local process has no explicit "connected" callback, so staying alive IS the signal). Restoring the
        /// budget means a LATER, independent drop gets a fresh [1,2,4,8,8]; a pane that re-exits inside the
        /// window cancels this in `processTerminated`, so a tmux-gone flap stays bounded by `maxReconnects`.
        private func scheduleStabilize() {
            stabilizeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reconnects = 0 }
            stabilizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + stabilizeWindow, execute: work)
        }

        /// The attach TARGET changed (a genuinely new session/window) → a fresh terminal, fresh budget. Bumping
        /// `attachGeneration` also invalidates any in-flight backoff block queued against the old target.
        func resetForNewTarget() {
            attachGeneration &+= 1
            stabilizeWork?.cancel(); stabilizeWork = nil
            reconnects = 0; reconnectPending = false
        }

        /// SwiftUI discarded the view: retire the coordinator for good. Bumping `attachGeneration`
        /// invalidates any backoff block already queued against the old view, and the closures are
        /// dropped so even a block that somehow slips through the generation check is a no-op rather
        /// than a fresh forkpty nobody owns.
        func tearDown() {
            dismantled = true
            transcriptImagePreview.dismiss()
            attachGeneration &+= 1
            stabilizeWork?.cancel(); stabilizeWork = nil
            reconnectPending = false
            paneAlive = false
            reattach = {}
            attachWhileLive = { false }
            loadTranscriptImage = nil
        }
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
/// expansion happen on a real click only. Pointer press-and-drag routing is adapter-specific; clicks
/// still reach SwiftTerm normally to establish focus.
final class ScrollableTerminalView: LocalProcessTerminalView {
    private static var monitorInstalled = false

    /// The terminal-local point of the most recent deliberate mouse activation. SwiftTerm reports an
    /// OSC 8 link on mouse-up, so retaining mouse-down's converted point gives the preview a stable
    /// anchor without sending an extra event through to tmux.
    private var linkDelegateProxy: TerminalImageLinkDelegateProxy?

    /// Which tmux window this terminal is attached to ("agent" / "shell-N"). Read by FocusBridge (via
    /// KVC) to move keyboard focus between the agent terminal and shell tabs. `@objc` for KVC.
    @objc var termWindow: String = "agent"

    /// When set, the view grabs keyboard focus the moment it's mounted in a window. At `makeNSView`
    /// time the view has no window yet, and polling on a timer races the mount (the old approach drained
    /// its retries before the view was ever in a window, so focus never landed). `viewDidMoveToWindow`
    /// is the exact lifecycle hook — no guessing.
    var claimFocusOnMount = false

    /// Render-parking (see `TerminalRenderParkingPolicy`). When true — the window is occluded/
    /// miniaturized / the app is inactive, or this terminal is scrolled out / collapsed — the view stops
    /// doing per-frame paint and freezes the caret, while its `tmux attach` keeps feeding the emulator
    /// buffer. SwiftTerm streams `feed → queuePendingDisplay → updateDisplay → setNeedsDisplay → draw`
    /// at stream rate regardless of visibility; `draw(drawTerminalContents)` is the expensive part and
    /// the sole WindowServer/CPU cost while nobody's looking. We can't touch the read-only SwiftTerm
    /// source, so we intercept at the two public seams a subclass owns:
    ///   • the `setNeedsDisplay(_:)` funnel every redraw routes through — swallowed while parked (marking
    ///     a single deferred redraw), so no `draw` fires and the whole `drawTerminalContents` cost is gone;
    ///   • the caret's perpetual `CABasicAnimation` — its API is `internal` to SwiftTerm and continuous
    ///     output re-arms it even after SwiftTerm's own resign-main disable, so we freeze the layer's
    ///     timeline with `layer.speed = 0` (which halts every animation in this view's layer subtree,
    ///     the caret sublayer included) and restore it on unpark.
    /// The view stays mounted, visible, and first-responder throughout, so nothing regresses while
    /// actually watching — unpark just thaws the layer and coalesces one full repaint of the now-current
    /// buffer.
    var renderingParked = false {
        didSet {
            guard renderingParked != oldValue else { return }
            if renderingParked {
                // Metal is off in Orchestra, so `setNeedsDisplay` is the only paint funnel — nothing to
                // intercept on a Metal path. Freeze the caret animation compositing on the render server.
                wantsLayer = true
                layer?.speed = 0
            } else {
                // Thaw the caret timeline, then coalesce every invalidation swallowed while parked into a
                // single full repaint — the emulator buffer stayed current under the live `tmux attach`,
                // so this one draw brings the view fully up to date with no catch-up burst.
                layer?.speed = 1
                layer?.beginTime = 0
                if deferredRedraw {
                    deferredRedraw = false
                    super.setNeedsDisplay(bounds)
                }
            }
        }
    }
    /// Set while parked whenever SwiftTerm asked to redraw; consumed by a single repaint on unpark.
    private var deferredRedraw = false

    /// Swallow SwiftTerm's stream-rate redraw requests while parked (recording that a redraw is owed),
    /// so `draw(_:)` — and thus the expensive `drawTerminalContents` — never runs off-screen. When not
    /// parked this is the stock behaviour. This is the one funnel `updateDisplay` invalidates through
    /// (`setNeedsDisplay(region)`); intercepting it here needs no access to SwiftTerm internals.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        if renderingParked { deferredRedraw = true; return }
        super.setNeedsDisplay(invalidRect)
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if renderingParked && newValue { deferredRedraw = true; return }
            super.needsDisplay = newValue
        }
    }

    /// Fired when this terminal takes keyboard focus by a mouse click (see the shared monitor below).
    /// The owner uses it to sync `focusZone` so the inspector focus ring / context chip stay truthful
    /// even when focus is taken by the mouse rather than a keyboard verb. (`becomeFirstResponder` is
    /// `public`-not-`open` in SwiftTerm, so we can't override it — hence the click monitor instead.)
    var onBecameFirstResponder: (() -> Void)?
    var terminalImagePaste: AgentCapabilities.TerminalImagePaste = .direct

    /// The last cell a drag motion was reported for, so one event goes down the pty per cell crossed
    /// rather than per pixel moved. Cleared on mouse-up so the next drag always reports its first cell.
    private var lastDragCell: Position?

    /// The terminal a left-button drag started in. Weak: a card closing mid-drag must not be pinned.
    fileprivate static weak var dragOwner: ScrollableTerminalView?

    /// Own OSC 52 — the clipboard escape — instead of leaving it to SwiftTerm's built-in handler.
    ///
    /// Selection inside these terminals belongs to tmux, which copies by writing OSC 52 to this view.
    /// SwiftTerm's built-in handler performs the copy, but it also answers the *read* form
    /// (`ESC ] 52 ; c ; ?`) from `clipboardRead`, which `LocalProcessTerminalView` implements as the real
    /// `NSPasteboard` — so an agent, or anything it runs, could read the user's clipboard by printing one
    /// escape sequence. A registered handler takes precedence over the built-in, so this keeps the copy
    /// and drops the read. `TerminalClipboardOSC` holds the (unit-tested) parsing.
    func installClipboardOSCHandler() {
        getTerminal().registerOscHandler(code: 52) { payload in
            guard let text = TerminalClipboardOSC.decodeCopy(payload: payload) else { return }
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([text as NSString])
            }
        }
    }

    /// `LocalProcessTerminalView` must retain itself as the terminal's actual downstream delegate so it
    /// can resize and write to its pty. A proxy adds the narrow opaque-image hook while forwarding every
    /// other callback, including ordinary browser links, unchanged.
    func configureImageLinkHandler(_ handler: @escaping (UUID) -> Void) {
        if let linkDelegateProxy {
            linkDelegateProxy.onOpenImage = handler
            return
        }
        let proxy = TerminalImageLinkDelegateProxy(downstream: terminalDelegate, onOpenImage: handler)
        linkDelegateProxy = proxy
        terminalDelegate = proxy
    }

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

    @objc
    override func paste(_ sender: Any) {
        guard Self.pasteboardContainsImage(NSPasteboard.general) else {
            super.paste(sender)
            return
        }

        switch terminalImagePaste {
        case .controlV:
            send(data: [0x16][0...])   // Ctrl-V: native paste-image shortcut for TUIs that advertise it.
        case .direct:
            super.paste(sender)
        }
    }

    private static func pasteboardContainsImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSImage.self])
            || pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")) != nil
            || pasteboard.data(forType: .tiff) != nil
    }

    /// Install the shared scroll/motion monitor once. Safe to call repeatedly.
    static func installScrollMonitorIfNeeded() {
        guard !monitorInstalled else { return }
        monitorInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .mouseMoved, .leftMouseDown,
                                                    .leftMouseUp, .leftMouseDragged]) { event in
            // A drag that wanders outside the terminal's bounds must keep extending the selection, so
            // the gesture belongs to the view the PRESS landed in — not to whatever the pointer is over
            // now (the board, another card). Hit-testing every motion would drop those events silently.
            if event.type == .leftMouseDragged, let owner = dragOwner {
                return owner.handleDragMotion(event) ? nil : event
            }
            if event.type == .leftMouseUp, let owner = dragOwner {
                owner.endDragMotion()
                dragOwner = nil
            }
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
                        // the click reach SwiftTerm normally. A Command-click on a link is the sole
                        // exception: keep both its down/up out of tmux so a preview never becomes a
                        // provider-TUI click.
                        term.onBecameFirstResponder?()
                        dragOwner = term
                        return term.hasCommandLink(at: event) ? nil : event
                    case .leftMouseUp:
                        // SwiftTerm handles explicit OSC 8 links itself under `.alwaysWithModifier`.
                        // The visible fallback is an implicit URL, so activate that one deliberately
                        // here without re-enabling passive hover tracking.
                        return term.activateImplicitCommandLink(at: event) ? nil : event
                    default:
                        return event
                    }
                }
                view = cur.superview
            }
            return event   // not over a terminal — leave board/list scrolling alone
        }
    }

    /// Send the drag motion SwiftTerm withholds, so a press-and-drag actually selects.
    ///
    /// SwiftTerm's `mouseDragged` forwards motion only when the program asked to be told about motion
    /// at ALL times (DECSET 1003 / `.anyEvent`), and otherwise returns without starting a native
    /// selection either. tmux asks for `1000;1002;1006`: `1002` is `.buttonEventTracking`, "report motion
    /// WHILE a button is down". So nothing sent the motion, tmux saw a press and a release but never a
    /// drag, `MouseDrag1Pane` never fired, and dragging selected nothing at all. (A double-click needs no
    /// motion, which is why it still flashed a word.) SwiftTerm's own `sendButtonTracking()` is the right
    /// predicate but is internal, so match on the public mode instead.
    ///
    /// This rides the shared event monitor rather than a `mouseDragged` override: SwiftTerm declares its
    /// mouse handlers `public`, not `open`, so a subclass outside that module cannot override them — the
    /// same constraint that put the click handling in the monitor.
    ///
    /// Motion is emitted once per CELL crossed, not per pixel: a drag across the pane is otherwise
    /// hundreds of identical events down the pty, and tmux only acts on cell changes.
    /// Returns `true` when it consumed the event.
    func handleDragMotion(_ event: NSEvent) -> Bool {
        guard terminal != nil, allowMouseReporting,
              TerminalMouseInteractionPolicy.hostMustForwardDragMotion(
                  appRequestedMotionWhileButtonDown: terminal.mouseMode == .buttonEventTracking,
                  terminalForwardsMotionItself: terminal.mouseMode.sendMotionEvent())
        else { return false }
        let (col, row) = gridLocation(of: event)
        guard lastDragCell != Position(col: col, row: row) else { return true }
        lastDragCell = Position(col: col, row: row)
        // Button 0 held; `sendMotion` adds the motion bit itself.
        let flags = terminal.encodeButton(button: 0, release: false,
                                          shift: event.modifierFlags.contains(.shift),
                                          meta: event.modifierFlags.contains(.option),
                                          control: event.modifierFlags.contains(.control))
        let point = convert(event.locationInWindow, from: nil)
        terminal.sendMotion(buttonFlags: flags, x: col, y: row,
                            pixelX: Int(point.x), pixelY: Int(bounds.height - point.y))
        return true
    }

    /// The drag finished — the next one must report its first cell even if it starts where this ended.
    func endDragMotion() { lastDragCell = nil }

    /// Forward the wheel to the running program as mouse-wheel events. Returns `true` if it consumed
    /// the event (alternate buffer with mouse reporting on), `false` to let SwiftTerm scroll natively.
    func handleScroll(_ event: NSEvent) -> Bool {
        guard event.deltaY != 0 else { return false }
        guard terminal != nil,
              TerminalMouseInteractionPolicy.shouldForwardWheelToTerminal(
                  isAlternateBuffer: terminal.isCurrentBufferAlternate,
                  mouseReportingActive: terminal.mouseMode != .off) else { return false }
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

    /// True only for a deliberate Command-click over a SwiftTerm-recognized link. This lets the local
    /// monitor swallow the press before tmux sees it; normal terminal clicks remain untouched.
    private func hasCommandLink(at event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), terminal != nil else { return false }
        let (col, row) = gridLocation(of: event)
        return terminal.link(at: .screen(Position(col: col, row: row)), mode: .explicitAndImplicit) != nil
    }

    /// SwiftTerm's public link API exposes implicit URLs but not the target of an explicit OSC 8 link.
    /// Explicit links continue through SwiftTerm's own mouse-up delegate callback; this method handles
    /// only the plain visible fallback and forwards non-Orchestra URLs to the existing downstream proxy.
    private func activateImplicitCommandLink(at event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), terminal != nil else { return false }
        let (col, row) = gridLocation(of: event)
        let location = Terminal.LinkLookupLocation.screen(Position(col: col, row: row))
        guard terminal.link(at: location, mode: .explicitOnly) == nil,
              let link = terminal.link(at: location, mode: .explicitAndImplicit)
        else { return false }
        terminalDelegate?.requestOpenLink(source: self, link: link, params: [:])
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

/// `LocalProcessTerminalView` deliberately owns its SwiftTerm delegate. Replacing that delegate would
/// stop the local process from receiving terminal input, resize, and clipboard callbacks, so this proxy
/// forwards its complete protocol surface and intercepts only Orchestra's exact opaque media URL.
private final class TerminalImageLinkDelegateProxy: NSObject, TerminalViewDelegate {
    weak var downstream: (any TerminalViewDelegate)?
    var onOpenImage: ((UUID) -> Void)?

    init(downstream: (any TerminalViewDelegate)?, onOpenImage: @escaping (UUID) -> Void) {
        self.downstream = downstream
        self.onOpenImage = onOpenImage
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        downstream?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        downstream?.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        downstream?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        downstream?.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        downstream?.scrolled(source: source, position: position)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let referenceID = TranscriptImageLink.referenceID(from: link) else {
            downstream?.requestOpenLink(source: source, link: link, params: params)
            return
        }
        onOpenImage?(referenceID)
    }

    func bell(source: TerminalView) {
        downstream?.bell(source: source)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        downstream?.clipboardCopy(source: source, content: content)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        downstream?.iTermContent(source: source, content: content)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        downstream?.rangeChanged(source: source, startY: startY, endY: endY)
    }
}
#endif
