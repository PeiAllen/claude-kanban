/// Input ownership for Orchestra's embedded terminals.
///
/// tmux owns the pointer while it owns the screen, and that ownership is indivisible: it holds the
/// scrollback (50k lines), so only tmux can anchor a selection or a scroll position to the TEXT. The
/// outer SwiftTerm sees just the one alternate screen tmux repaints, so a selection anchored there would
/// stay on a screen row while the text moved under it. Presses, drags, and the wheel therefore all go to
/// the same owner — never split between them.
public enum TerminalMouseInteractionPolicy {
    /// tmux needs wheel button events only while it owns the visible alternate screen and has requested
    /// mouse tracking. Normal-buffer scrolling stays with SwiftTerm's native scrollback.
    public static func shouldForwardWheelToTerminal(isAlternateBuffer: Bool,
                                                    mouseReportingActive: Bool) -> Bool {
        isAlternateBuffer && mouseReportingActive
    }
}
