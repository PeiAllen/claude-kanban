import Foundation
import Testing
@testable import OrchestraKit

@Suite("OSC 52 clipboard payload decoding")
struct TerminalClipboardOSCTests {

    private func payload(_ text: String) -> ArraySlice<UInt8> { Array(text.utf8)[...] }
    private func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    // tmux writes the selection field EMPTY, which xterm defines as "the default selection". The app
    // tracks SwiftTerm `from: 1.2.0`, and a revision in that range accepted only `c;` — dropping every
    // tmux copy — so the spelling is pinned here rather than left to whichever revision resolves.
    @Test("accepts tmux's empty selection field")
    func acceptsEmptySelectionField() {
        #expect(TerminalClipboardOSC.decodeCopy(payload: payload(";\(base64("LINE-1\nLINE-2"))"))
                == "LINE-1\nLINE-2")
    }

    @Test("accepts the named selection targets")
    func acceptsNamedSelections() {
        for selection in ["c", "p", "s", "q", "0", "7", "pc"] {
            #expect(TerminalClipboardOSC.decodeCopy(payload: payload("\(selection);\(base64("hi"))")) == "hi")
        }
    }

    // SwiftTerm's built-in handler answers this form from the real NSPasteboard, so an agent could read
    // the user's clipboard by printing one escape sequence. Decoding it to nothing is what closes that:
    // the registered handler consumes the sequence and the built-in never replies.
    @Test("ignores a clipboard query")
    func ignoresQuery() {
        #expect(TerminalClipboardOSC.decodeCopy(payload: payload("c;?")) == nil)
        #expect(TerminalClipboardOSC.decodeCopy(payload: payload(";?")) == nil)
    }

    // Anything that is not a copy request leaves the pasteboard alone — overwriting it with garbage is
    // worse than ignoring the sequence.
    @Test("ignores malformed and empty payloads")
    func ignoresMalformed() {
        #expect(TerminalClipboardOSC.decodeCopy(payload: payload("")) == nil)
        #expect(TerminalClipboardOSC.decodeCopy(payload: payload("c")) == nil)          // no separator
        #expect(TerminalClipboardOSC.decodeCopy(payload: payload("c;")) == nil)         // clear request
        #expect(TerminalClipboardOSC.decodeCopy(payload: payload("c;not base64!")) == nil)
        #expect(TerminalClipboardOSC.decodeCopy(payload: payload("zz;\(base64("hi"))")) == nil)
        // Valid base64 that is not UTF-8 text.
        #expect(TerminalClipboardOSC.decodeCopy(payload: payload("c;\(Data([0xFF, 0xFE]).base64EncodedString())")) == nil)
    }

    @Test("decodes multi-byte text")
    func decodesUnicode() {
        #expect(TerminalClipboardOSC.decodeCopy(payload: payload("c;\(base64("→ café ✓"))")) == "→ café ✓")
    }
}
