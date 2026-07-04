import SwiftUI
import UIKit
import OrchestraKit
import OrchestraUI

// iOS implementations of OrchestraUI's four platform protocols (the per-OS seam the shared BoardModel
// and views reach through). Shapes match Sources/OrchestraUI/PlatformProtocols.swift exactly.

/// iOS clipboard via `UIPasteboard`.
struct IOSClipboard: Clipboard {
    func copy(_ text: String) { UIPasteboard.general.string = text }
    /// Not part of the `Clipboard` protocol (which is write-only) — a read accessor for round-trip tests.
    var string: String? { UIPasteboard.general.string }
}

/// iOS "open a host affordance." On the phone, Settings is a tab (not a window) and Finder-reveal has no
/// analogue, so both entry points are no-ops. The shared `BoardModel` only invokes these from
/// keyboard-nav paths, which iOS does not wire.
struct IOSSystemOpener: SystemOpener {
    func openSettings() {}
    func open(path: String) {}
}

/// iOS has no key-window first responder to juggle and (until T1) no mounted terminal, so both window
/// operations are inert. `enterTerminalFocus()` returns false — there is no terminal to focus yet.
struct IOSWindowConfig: WindowConfig {
    func resignInputFocus() {}
    func enterTerminalFocus() -> Bool { false }
}

/// Placeholder terminal host until T1 lands the SwiftTerm-iOS SSH-PTY implementation. Every attach
/// returns an explanatory stub instead of a live terminal.
struct IOSTerminalHost: TerminalHost {
    func attach(target: TmuxTarget) -> AnyView {
        AnyView(
            Text("Terminal coming soon")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }
}

/// The bundle injected into the shared `BoardModel(platform:)` on iOS.
extension PlatformUI {
    static let ios = PlatformUI(clipboard: IOSClipboard(),
                                opener: IOSSystemOpener(),
                                window: IOSWindowConfig())
}
