/// Input ownership for Orchestra's embedded terminals.
///
/// tmux enables mouse tracking for its own copy-mode and terminal applications. Pointer press-and-drag
/// ownership is an adapter capability; wheel delivery stays separate so an agent that opts into native
/// selection still has tmux scrollback on the alternate screen.
public enum TerminalMouseInteractionPolicy {
    /// tmux needs wheel button events only while it owns the visible alternate screen and has requested
    /// mouse tracking. Normal-buffer scrolling stays with SwiftTerm's native scrollback.
    public static func shouldForwardWheelToTerminal(isAlternateBuffer: Bool,
                                                    mouseReportingActive: Bool) -> Bool {
        isAlternateBuffer && mouseReportingActive
    }
}
