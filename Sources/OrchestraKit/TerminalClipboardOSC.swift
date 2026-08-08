import Foundation

/// Decodes an OSC 52 "set clipboard" payload — the sequence a terminal application uses to put text on
/// the *host* clipboard — and, deliberately, decodes NOTHING for the read form.
///
/// SwiftTerm's built-in OSC 52 handler answers a clipboard QUERY (`ESC ] 52 ; c ; ?`) by calling
/// `clipboardRead`, which `LocalProcessTerminalView` implements as "return `NSPasteboard.general`". So
/// any program running in a terminal — an agent, or anything the agent shells out to — can read the
/// user's clipboard by printing one escape sequence, and tmux forwards the sequence through. Orchestra
/// registers this decoder over the built-in (`Terminal.registerOscHandler(code: 52)`, which takes
/// precedence), so a copy still works and a query is simply never answered.
///
/// It also pins the spelling tmux actually writes. tmux leaves the selection field EMPTY
/// (`ESC ] 52 ; ; <base64>`), which xterm defines as "the default selection". SwiftTerm accepts that
/// today, but the app tracks SwiftTerm `from: 1.2.0` — an older revision accepted only `c;<base64>` and
/// dropped every tmux copy on the floor. Owning the parse keeps host copy independent of which
/// SwiftTerm the app resolves.
///
/// The parser lives in OrchestraKit, apart from AppKit, so the byte handling — the part that must reject
/// a malformed payload rather than paste garbage — is covered by the fast unit tier.
public enum TerminalClipboardOSC {
    /// The selection targets xterm defines. Orchestra treats the clipboard and the primary selection
    /// alike (macOS has one pasteboard), and ignores cut buffers `0`-`7`.
    private static let selectionTargets = Set("cpqs01234567".unicodeScalars.map { UInt8($0.value) })

    /// Decodes the text a terminal asks the host to copy, or `nil` when the payload is not a copy
    /// request this host should honor.
    ///
    /// `payload` is everything after `ESC ] 52 ;` — i.e. `<selection>;<base64>`. Returns `nil` for a
    /// clipboard *query* (`?`), a clear request (empty base64), invalid base64, or non-UTF-8 bytes, so a
    /// malformed sequence can never overwrite the pasteboard with garbage.
    public static func decodeCopy(payload: ArraySlice<UInt8>) -> String? {
        // Split on the FIRST semicolon: the selection field may be empty, and base64 never contains one.
        guard let separator = payload.firstIndex(of: UInt8(ascii: ";")) else { return nil }
        let selection = payload[payload.startIndex..<separator]
        let encoded = payload[payload.index(after: separator)...]

        // An empty selection field means "the default", which is the clipboard. A named field must
        // consist only of targets we recognize, so a future OSC 52 extension is ignored, not guessed at.
        guard selection.allSatisfy({ selectionTargets.contains($0) }) else { return nil }
        // `?` asks the host to REPORT the clipboard. Returning nil here is what closes the read path:
        // the registered handler consumes the sequence, so SwiftTerm's built-in never replies.
        guard !encoded.isEmpty, encoded.first != UInt8(ascii: "?") else { return nil }

        guard let decoded = Data(base64Encoded: Data(encoded)),
              let text = String(data: decoded, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        return text
    }
}
