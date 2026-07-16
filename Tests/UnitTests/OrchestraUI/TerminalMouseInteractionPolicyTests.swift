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
}
