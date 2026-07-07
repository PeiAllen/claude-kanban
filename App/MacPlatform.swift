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

/// The desktop's platform bundle — the three UI ops `BoardModel` calls directly.
enum MacPlatform {
    static let ui = PlatformUI(clipboard: AppKitClipboard(),
                               opener: AppKitSystemOpener(),
                               window: AppKitWindowConfig())
}

extension View {
    /// Inject the desktop platform implementations into the SwiftUI Environment so any view can read
    /// them. Applied at both Scene roots. (The macOS agent terminal mounts via `AgentTerminalView`
    /// directly, not the `\.terminalHost` seam — that Environment key is the phone's, defaulting to a
    /// no-op host here.)
    func platformUI() -> some View {
        environment(\.clipboard, MacPlatform.ui.clipboard)
            .environment(\.systemOpener, MacPlatform.ui.opener)
            .environment(\.windowConfig, MacPlatform.ui.window)
    }
}
