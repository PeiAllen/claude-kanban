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
        #expect(KeyName.esc.bytes == [0x1b])
        #expect(KeyName.tab.bytes == [0x09])
        #expect(KeyName.enter.bytes == [0x0d])
        #expect(KeyName.ctrlC.bytes == [0x03])
        #expect(KeyName.up.bytes == [0x1b, 0x5b, 0x41])
        #expect(KeyName.down.bytes == [0x1b, 0x5b, 0x42])
        #expect(KeyName.right.bytes == [0x1b, 0x5b, 0x43])
        #expect(KeyName.left.bytes == [0x1b, 0x5b, 0x44])
        #expect(KeyName.pageUp.bytes == [0x1b, 0x5b, 0x35, 0x7e])
        #expect(KeyName.pageDown.bytes == [0x1b, 0x5b, 0x36, 0x7e])
        #expect(KeyName.home.bytes == [0x1b, 0x5b, 0x48])
        #expect(KeyName.end.bytes == [0x1b, 0x5b, 0x46])
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
        #expect(applyControlModifier(to: KeyName.up.bytes) == KeyName.up.bytes)
        #expect(applyControlModifier(to: []) == [])
    }

    @Test("sticky Ctrl only transforms the first byte of a run")
    func ctrlFirstByteOnly() {
        #expect(applyControlModifier(to: Array("ca".utf8)) == [0x03, 0x61])
    }
}
