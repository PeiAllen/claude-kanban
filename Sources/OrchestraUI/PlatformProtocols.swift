import SwiftUI
import OrchestraKit

// The platform seam. `BoardModel` is shared (macOS + iOS) but a handful of its operations reach into
// host UI that differs per platform — the pasteboard, opening the settings window, moving keyboard
// focus, mounting a terminal. Each is expressed here as a tiny protocol so the desktop injects an
// AppKit implementation and the future iOS client injects a UIKit one, while `BoardModel` stays
// AppKit-free.
//
// All four are `@MainActor` (they touch main-thread UI) and refine `Sendable` so the Environment-key
// defaults and `PlatformUI.noop` are concurrency-safe globals under the Swift 6 language mode.

/// Pasteboard write. macOS = `NSPasteboard`, iOS = `UIPasteboard`.
@MainActor public protocol Clipboard: Sendable {
    func copy(_ text: String)
}

/// Open a host affordance. macOS = `NSApp`/`NSWorkspace`, iOS = no-op / in-app navigation.
@MainActor public protocol SystemOpener: Sendable {
    /// `BoardModel.goTo(.settings)` — surfaces the app's Settings window. [F2-required]
    func openSettings()
}

/// Window / input-focus chrome. macOS = key-window first responder; iOS = no-op.
@MainActor public protocol WindowConfig: Sendable {
    /// `BoardModel.closeFrontmost()` step-out-of-terminal — drop first responder off any terminal. [F2-required]
    func resignInputFocus()
    /// `BoardModel.enterTerminalZone()` / `selectAndEnterTerminal()` — move keyboard focus INTO the
    /// mounted agent terminal. Returns whether a terminal was there to focus (so the caller can
    /// reconcile `focusZone`). macOS = `FocusBridge.enterTerminal()`; iOS = no-op. [F2-required]
    func enterTerminalFocus() -> Bool
}

/// Terminal attach seam. macOS = local/remote tmux via SwiftTerm (AppKit); iOS = SSH-PTY (T1).
/// Returns a type-erased view so the existential is storable in the Environment.
@MainActor public protocol TerminalHost: Sendable {
    func attach(target: TmuxTarget) -> AnyView
    /// T2's phone live-shell variant: `selectMode == true` disables terminal mouse reporting so touch
    /// drags do native text selection instead of becoming TUI mouse input (the design's explicit
    /// "Select mode"). Defaults to the plain `attach` — desktop/Noop hosts ignore the flag.
    func attach(target: TmuxTarget, selectMode: Bool) -> AnyView
}

public extension TerminalHost {
    func attach(target: TmuxTarget, selectMode: Bool) -> AnyView { attach(target: target) }
}

// MARK: - No-op defaults (previews, tests, and iOS-before-F3)

// The inits are `nonisolated` so the Environment-key defaults and `PlatformUI.noop` can construct
// them in a nonisolated global context (the protocol-driven `@MainActor` inference would otherwise
// isolate the whole struct, init included); the UI methods stay `@MainActor`.

public struct NoopClipboard: Clipboard {
    public nonisolated init() {}
    public func copy(_ text: String) {}
}

public struct NoopSystemOpener: SystemOpener {
    public nonisolated init() {}
    public func openSettings() {}
}

public struct NoopWindowConfig: WindowConfig {
    public nonisolated init() {}
    public func resignInputFocus() {}
    /// Pretend the focus move succeeded so a shared caller keeps its intended `focusZone`; the real
    /// iOS focus behaviour is F3/T1's to define.
    public func enterTerminalFocus() -> Bool { true }
}

public struct NoopTerminalHost: TerminalHost {
    public nonisolated init() {}
    public func attach(target: TmuxTarget) -> AnyView { AnyView(EmptyView()) }
}

// MARK: - The bundle BoardModel is constructed with

/// The three UI operations the shared `BoardModel` invokes directly. `TerminalHost` is *not* here — a
/// terminal is produced by a `View`, so it rides the Environment only. `BoardModel` is an
/// `ObservableObject` (not a `View`), so it cannot read `@Environment`; these are injected via its
/// initializer instead.
public struct PlatformUI: Sendable {
    public let clipboard: any Clipboard
    public let opener: any SystemOpener
    public let window: any WindowConfig

    public init(clipboard: any Clipboard, opener: any SystemOpener, window: any WindowConfig) {
        self.clipboard = clipboard
        self.opener = opener
        self.window = window
    }

    /// Inert bundle for previews, tests, and the iOS client before it wires real impls.
    public static let noop = PlatformUI(clipboard: NoopClipboard(),
                                        opener: NoopSystemOpener(),
                                        window: NoopWindowConfig())
}

// MARK: - Environment keys (for views; TerminalHost is produced by a view)

private struct ClipboardKey: EnvironmentKey { static let defaultValue: any Clipboard = NoopClipboard() }
private struct SystemOpenerKey: EnvironmentKey { static let defaultValue: any SystemOpener = NoopSystemOpener() }
private struct WindowConfigKey: EnvironmentKey { static let defaultValue: any WindowConfig = NoopWindowConfig() }
private struct TerminalHostKey: EnvironmentKey { static let defaultValue: any TerminalHost = NoopTerminalHost() }

extension EnvironmentValues {
    public var clipboard: any Clipboard {
        get { self[ClipboardKey.self] }
        set { self[ClipboardKey.self] = newValue }
    }
    public var systemOpener: any SystemOpener {
        get { self[SystemOpenerKey.self] }
        set { self[SystemOpenerKey.self] = newValue }
    }
    public var windowConfig: any WindowConfig {
        get { self[WindowConfigKey.self] }
        set { self[WindowConfigKey.self] = newValue }
    }
    public var terminalHost: any TerminalHost {
        get { self[TerminalHostKey.self] }
        set { self[TerminalHostKey.self] = newValue }
    }
}
