import SwiftUI
import UIKit
import OrchestraKit
import OrchestraUI

// iOS implementations of OrchestraUI's four platform protocols (the per-OS seam the shared BoardModel
// and views reach through). Shapes match Sources/OrchestraUI/PlatformProtocols.swift exactly.

/// iOS clipboard via `UIPasteboard`.
struct IOSClipboard: Clipboard {
    func copy(_ text: String) { UIPasteboard.general.string = text }
}

/// iOS "open a host affordance." On the phone, Settings is a tab (not a window) and Finder-reveal has no
/// analogue, so both entry points are no-ops. The shared `BoardModel` only invokes these from
/// keyboard-nav paths, which iOS does not wire.
struct IOSSystemOpener: SystemOpener {
    func openSettings() {}
}

/// iOS has no key-window first responder to juggle, and terminal keyboard focus is *view-local* on
/// iOS (tap the SwiftTerm view to focus it; there is no global first-responder to route through), so
/// both operations are inert. `enterTerminalFocus()` returns false: the shared `BoardModel`'s
/// keyboard-descent nav is a desktop path the phone doesn't drive. Global focus routing for the
/// takeover surface is T4's concern.
struct IOSWindowConfig: WindowConfig {
    func resignInputFocus() {}
    func enterTerminalFocus() -> Bool { false }
}

// The real terminal host lives in Terminal/IOSTerminalHost.swift (SwiftTerm iOS over an SSH PTY).

/// The bundle injected into the shared `BoardModel(platform:)` on iOS.
extension PlatformUI {
    static let ios = PlatformUI(clipboard: IOSClipboard(),
                                opener: IOSSystemOpener(),
                                window: IOSWindowConfig())
}
