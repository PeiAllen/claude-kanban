import SwiftUI
import AppKit
import OrchestraKit
import OrchestraUI

// AppKit-backed implementations of the OrchestraUI platform seam. These carry the desktop's exact,
// pre-F2 behaviour — the same NSPasteboard write, the same `showSettingsWindow:` action, the same
// first-responder moves — so the board is byte-for-byte identical after `BoardModel` starts routing
// through the protocols. Injected into `BoardModel` (the 3 UI ops) and the SwiftUI Environment (all
// four) from `OrchestraApp`.
//
// The inits are `nonisolated` so `MacPlatform.ui` (a nonisolated `static let`) can construct them; the
// UI methods remain `@MainActor` (they touch `NSApp`/`NSPasteboard`) as their protocols require.

struct AppKitClipboard: Clipboard {
    nonisolated init() {}
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct AppKitSystemOpener: SystemOpener {
    nonisolated init() {}
    func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    func open(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

struct AppKitWindowConfig: WindowConfig {
    nonisolated init() {}
    func resignInputFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    func enterTerminalFocus() -> Bool {
        FocusBridge.enterTerminal()
    }
}

/// Mounts the live desktop agent terminal for a tmux target. Defined and injected so F3's iOS
/// placeholder and T1's SSH-PTY have a real seam; the existing desktop terminal call sites
/// (`InspectorView`, `ShellTabsView`) are left untouched in F2 and are rewired through this by T1.
struct MacTerminalHost: TerminalHost {
    nonisolated init() {}
    func attach(target: TmuxTarget) -> AnyView {
        let theme = Theme(scheme: .light, accent: .blue)
        return AnyView(AgentTerminalView(
            socket: target.socket,
            session: target.session,
            window: target.window,
            host: .local,
            background: theme.termBg,
            foreground: theme.term))
    }
}

/// The desktop's platform bundle — the three UI ops `BoardModel` calls directly.
enum MacPlatform {
    static let ui = PlatformUI(clipboard: AppKitClipboard(),
                               opener: AppKitSystemOpener(),
                               window: AppKitWindowConfig())
}

extension View {
    /// Inject the four desktop platform implementations into the SwiftUI Environment so any view
    /// (now, and F3's terminal placeholder later) can read them. Applied at both Scene roots.
    func platformUI() -> some View {
        environment(\.clipboard, MacPlatform.ui.clipboard)
            .environment(\.systemOpener, MacPlatform.ui.opener)
            .environment(\.windowConfig, MacPlatform.ui.window)
            .environment(\.terminalHost, MacTerminalHost())
    }
}
