import Foundation
import Testing
import OrchestraKit

/// Coverage for the phone takeover accessory-bar key encodings (PR T4). These are the standard
/// xterm/VT sequences the agent TUI (Claude or Codex) expects; pinning the bytes guards against a typo
/// silently sending the wrong key into a live session.
@Suite("Terminal key bytes")
struct TerminalKeyBytesTests {

    @Test("special keys encode as xterm sequences")
    func specialKeys() {
        #expect(TerminalKey.esc.bytes == [0x1b])
        #expect(TerminalKey.tab.bytes == [0x09])
        #expect(TerminalKey.enter.bytes == [0x0d])
        #expect(TerminalKey.up.bytes == [0x1b, 0x5b, 0x41])
        #expect(TerminalKey.down.bytes == [0x1b, 0x5b, 0x42])
        #expect(TerminalKey.right.bytes == [0x1b, 0x5b, 0x43])
        #expect(TerminalKey.left.bytes == [0x1b, 0x5b, 0x44])
        #expect(TerminalKey.pageUp.bytes == [0x1b, 0x5b, 0x35, 0x7e])
        #expect(TerminalKey.pageDown.bytes == [0x1b, 0x5b, 0x36, 0x7e])
        #expect(TerminalKey.home.bytes == [0x1b, 0x5b, 0x48])
        #expect(TerminalKey.end.bytes == [0x1b, 0x5b, 0x46])
    }

    @Test("sticky Ctrl folds a letter to its control code")
    func ctrlOnLetter() {
        #expect(applyControlModifier(to: Array("c".utf8)) == [0x03])   // Ctrl-C → SIGINT
        #expect(applyControlModifier(to: Array("C".utf8)) == [0x03])   // case-folded
        #expect(applyControlModifier(to: Array("d".utf8)) == [0x04])   // Ctrl-D → EOF
        #expect(applyControlModifier(to: Array("a".utf8)) == [0x01])   // Ctrl-A
    }

    @Test("sticky Ctrl handles the @…_ control range and Esc")
    func ctrlOnPunctuation() {
        #expect(applyControlModifier(to: Array("[".utf8)) == [0x1b])   // Ctrl-[ → Esc
        #expect(applyControlModifier(to: Array("@".utf8)) == [0x00])   // Ctrl-@ → NUL
    }

    @Test("sticky Ctrl passes through bytes with no control code")
    func ctrlPassThrough() {
        // Digits and already-escape sequences aren't remapped (a real Ctrl doesn't either).
        #expect(applyControlModifier(to: Array("1".utf8)) == Array("1".utf8))
        #expect(applyControlModifier(to: TerminalKey.up.bytes) == TerminalKey.up.bytes)
        #expect(applyControlModifier(to: []) == [])
    }

    @Test("sticky Ctrl only transforms the first byte of a run")
    func ctrlFirstByteOnly() {
        #expect(applyControlModifier(to: Array("ca".utf8)) == [0x03, 0x61])
    }
}
