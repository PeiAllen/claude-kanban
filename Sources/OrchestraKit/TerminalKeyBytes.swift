import Foundation

// The special-key → PTY byte encodings that used to live here as a parallel `TerminalKey` enum are now
// a `bytes` projection on `KeyName` (one keyboard vocabulary — see `Keyboard/KeyName.swift`). This file
// keeps the byte-level `applyControlModifier` transform the takeover accessory bar layers on top.

/// Apply a "sticky Ctrl" modifier to a run of typed bytes: a printable ASCII byte becomes its control
/// code (`byte & 0x1f`), so Ctrl + `c` → 0x03 (SIGINT), Ctrl + `d` → 0x04 (EOF), Ctrl + `[` → 0x1b (Esc).
///
/// - Only the standard control range is transformed: letters `@`(0x40)…`_`(0x5f) and lowercase `a`…`z`
///   (folded up first, matching a real terminal, so Ctrl+`c` and Ctrl+`C` both give 0x03). Anything
///   outside that range (digits, arrows-as-escape-sequences, multi-byte input) passes through untouched,
///   which is what a hardware Ctrl does too.
/// - Applied to the first byte of the run only — the modifier is one keystroke, matching one-shot Ctrl.
public func applyControlModifier(to bytes: [UInt8]) -> [UInt8] {
    guard let first = bytes.first else { return bytes }
    let upper = (first >= 0x61 && first <= 0x7a) ? first - 0x20 : first   // fold a…z → A…Z
    guard upper >= 0x40 && upper <= 0x5f else { return bytes }            // only @…_ have a control code
    return [upper & 0x1f] + bytes.dropFirst()
}
