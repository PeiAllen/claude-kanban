import Testing
@testable import OrchestraUI

@Suite("Embedded terminal mouse interaction policy")
struct TerminalMouseInteractionPolicyTests {

    @Test("forwards only alternate-screen wheel events")
    func forwardsAlternateScreenWheelEvents() {
        #expect(TerminalMouseInteractionPolicy.shouldForwardWheelToTerminal(
            isAlternateBuffer: true, mouseReportingActive: true))
        #expect(!TerminalMouseInteractionPolicy.shouldForwardWheelToTerminal(
            isAlternateBuffer: false, mouseReportingActive: true))
        #expect(!TerminalMouseInteractionPolicy.shouldForwardWheelToTerminal(
            isAlternateBuffer: true, mouseReportingActive: false))
    }

    // The drag bug: tmux asks for 1002 ("motion while a button is down"), SwiftTerm forwards motion
    // only for 1003 ("motion at all times") and otherwise starts no native selection either — so a
    // drag sent a press and a release with nothing in between, and tmux never saw a drag at all.
    @Test("the host sends drag motion exactly when the view will not")
    func hostFillsTheDragMotionGap() {
        // tmux: 1002 requested, SwiftTerm silent → the host must send it.
        #expect(TerminalMouseInteractionPolicy.hostMustForwardDragMotion(
            appRequestedMotionWhileButtonDown: true, terminalForwardsMotionItself: false))
        // 1003: the view already sends motion — sending it again would double every drag event.
        #expect(!TerminalMouseInteractionPolicy.hostMustForwardDragMotion(
            appRequestedMotionWhileButtonDown: true, terminalForwardsMotionItself: true))
        // Press/release-only tracking (1000) and no tracking: nothing to forward.
        #expect(!TerminalMouseInteractionPolicy.hostMustForwardDragMotion(
            appRequestedMotionWhileButtonDown: false, terminalForwardsMotionItself: false))
    }
}
