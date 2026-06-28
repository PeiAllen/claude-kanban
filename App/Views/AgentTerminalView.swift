import SwiftUI
import OrchestraCore
#if canImport(SwiftTerm)
import SwiftTerm
#endif

/// The live agent terminal — a SwiftTerm `LocalProcessTerminalView` attaching to the card's tmux
/// session directly (no byte-proxying through the daemon). When SwiftTerm isn't linked (e.g. building
/// the core without the app dependency), a minimal placeholder is shown instead.
struct AgentTerminalView: NSViewRepresentable {
    let socket: String
    let session: String          // "orchestra-<id>"
    let window: String           // "agent"
    var background: SwiftUI.Color  // app theme — terminal opens in (and switches to) the app's mode
    var foreground: SwiftUI.Color

    init(socket: String = Config.tmuxSocket, session: String, window: String = "agent",
         background: SwiftUI.Color, foreground: SwiftUI.Color) {
        self.socket = socket; self.session = session; self.window = window
        self.background = background; self.foreground = foreground
    }

    #if canImport(SwiftTerm)
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        term.processDelegate = context.coordinator
        term.font = Self.terminalFont
        applyColors(term)
        context.coordinator.attached = "\(session):\(window)"
        attach(term)
        return term
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        applyColors(nsView)   // re-tint when the app toggles light/dark
        // Safety net: if SwiftUI reused this NSView for a different card (despite the `.id` upstream),
        // re-point it at the right tmux target instead of leaving it on the previous card's session.
        let target = "\(session):\(window)"
        if context.coordinator.attached != target {
            context.coordinator.attached = target
            attach(nsView)
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
    }

    private func attach(_ term: LocalProcessTerminalView) {
        // Resolve tmux on PATH via /usr/bin/env — a Finder/launchd-launched app has a minimal PATH
        // that omits Homebrew (where tmux lives), so a hard-coded /usr/bin/tmux doesn't exist and the
        // terminal stayed black. Hand env an augmented PATH so `tmux` is found.
        let args = ["tmux", "-L", socket, "attach", "-t", "\(session):\(window)"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Proc.augmentedPATH(env["PATH"])
        // A GUI-launched app inherits no locale, so the attaching tmux client falls back to non-UTF-8
        // and renders multibyte glyphs (the logo's block chars, em-dashes, rules) as `_`. Force UTF-8.
        Proc.ensureUTF8Locale(&env)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envArray = env.map { "\($0.key)=\($0.value)" }
        term.startProcess(executable: "/usr/bin/env", args: args, environment: envArray)
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
