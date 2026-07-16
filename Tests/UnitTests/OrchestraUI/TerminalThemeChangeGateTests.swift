import Testing
@testable import OrchestraUI

@Suite("Terminal theme update gate")
struct TerminalThemeChangeGateTests {

    @Test("only applies a terminal palette when it changed")
    func suppressesRepeatedPaletteUpdates() {
        let dark = TerminalThemeSignature(
            background: .init(red: 0x1313, green: 0x1313, blue: 0x1515),
            foreground: .init(red: 0xD6D6, green: 0xD6D6, blue: 0xDADA))
        let light = TerminalThemeSignature(
            background: .init(red: 0xFBFB, green: 0xFAFA, blue: 0xF8F8),
            foreground: .init(red: 0x2A2A, green: 0x2A2A, blue: 0x2E2E))
        var gate = TerminalThemeChangeGate()

        // Store each mutating call before asserting: `#expect` captures its operands as immutable.
        let initialDark = gate.shouldApply(dark)
        let repeatedDark = gate.shouldApply(dark)
        let changedLight = gate.shouldApply(light)
        let repeatedLight = gate.shouldApply(light)
        #expect(initialDark)
        #expect(!repeatedDark)
        #expect(changedLight)
        #expect(!repeatedLight)
    }
}
