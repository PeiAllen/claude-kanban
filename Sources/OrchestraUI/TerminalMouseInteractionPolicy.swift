/// Input ownership for Orchestra's embedded terminals.
///
/// tmux owns the pointer while it owns the screen, and that ownership is indivisible: it holds the
/// scrollback (50k lines), so only tmux can anchor a selection or a scroll position to the TEXT. The
/// outer SwiftTerm sees just the one alternate screen tmux repaints, so a selection anchored there would
/// stay on a screen row while the text moved under it. Presses, drags, and the wheel therefore all go to
/// the same owner — never split between them.
public enum TerminalMouseInteractionPolicy {
    /// Whether the HOST must send drag motion itself, because the terminal view will not.
    ///
    /// A drag is a press, then motion while the button is down, then a release. tmux only treats a
    /// gesture as a drag — and so only starts a selection — once it sees that motion. SwiftTerm sends
    /// press and release for every tracking mode, but gates motion on "report motion at ALL times"
    /// (DECSET 1003), and then returns without starting a native selection either. tmux asks for
    /// `1000;1002;1006`, where `1002` is "report motion WHILE a button is down" — so nothing sends the
    /// motion, tmux sees only a press and a release, and a drag selects nothing. A double-click needs no
    /// motion, which is why it still flashes a selection.
    ///
    /// - Parameter appRequestedMotionWhileButtonDown: the program asked for `1002`-style tracking.
    /// - Parameter terminalForwardsMotionItself: the view already sends motion for this mode.
    public static func hostMustForwardDragMotion(appRequestedMotionWhileButtonDown: Bool,
                                                 terminalForwardsMotionItself: Bool) -> Bool {
        appRequestedMotionWhileButtonDown && !terminalForwardsMotionItself
    }

    /// tmux needs wheel button events only while it owns the visible alternate screen and has requested
    /// mouse tracking. Normal-buffer scrolling stays with SwiftTerm's native scrollback.
    public static func shouldForwardWheelToTerminal(isAlternateBuffer: Bool,
                                                    mouseReportingActive: Bool) -> Bool {
        isAlternateBuffer && mouseReportingActive
    }
}
