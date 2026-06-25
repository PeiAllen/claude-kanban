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
        applyColors(term)
        attach(term)
        return term
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        applyColors(nsView)   // re-tint when the app toggles light/dark
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envArray = env.map { "\($0.key)=\($0.value)" }
        term.startProcess(executable: "/usr/bin/env", args: args, environment: envArray)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
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
