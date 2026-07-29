/// When Orchestra's embedded terminals should stop *rendering* — while keeping their PTY/stream
/// ingestion live so the buffer is current the instant the user returns.
///
/// The expensive part of a streaming terminal is the per-frame paint (`drawTerminalContents`) plus the
/// caret's perpetual blink animation, both of which SwiftTerm runs at stream rate regardless of whether
/// anyone is looking. This policy is the single rule both platforms (and the phone's non-attaching
/// capture preview) consult to decide whether that render work should park. It deliberately does NOT
/// gate ingestion — only the display side parks, and a single coalesced redraw restores the live buffer
/// on unpark.
///
/// The two inputs mirror the animation gate from the idle-animation fix (see `EnvironmentValues
/// .animationsActive`): `animationsActive` is false when the window is occluded/miniaturized or the app
/// is inactive (macOS) / the scene isn't active (iOS); `onScreen` is false when this particular terminal
/// is scrolled out of view, collapsed, or otherwise not the visible one.
public enum TerminalRenderParkingPolicy {
    /// Park rendering unless the window/scene is being looked at AND this terminal is on-screen.
    public static func shouldPark(animationsActive: Bool, onScreen: Bool) -> Bool {
        !(animationsActive && onScreen)
    }
}
