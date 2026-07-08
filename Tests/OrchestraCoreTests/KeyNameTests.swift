import Foundation
import Testing
@testable import OrchestraCore   // @_exported brings in OrchestraKit's KeyName/KeyToken

@Suite("KeyName + KeyToken value model")
struct KeyNameTests {

    @Test("wire rawValues match the agreed vocabulary")
    func rawValues() {
        #expect(KeyName.esc.rawValue == "Esc")
        #expect(KeyName.ctrlC.rawValue == "C-c")
        #expect(KeyName.pageUp.rawValue == "PgUp")
        #expect(KeyName.pageDown.rawValue == "PgDn")
        #expect(KeyName(rawValue: "Up") == .up)
        #expect(KeyName(rawValue: "nope") == nil)
        // Every case is round-trippable through its rawValue.
        for k in KeyName.allCases { #expect(KeyName(rawValue: k.rawValue) == k) }
    }

    @Test("tmux tokens map wire names to tmux key names")
    func tmuxTokens() {
        #expect(KeyName.esc.tmuxToken == "Escape")
        #expect(KeyName.up.tmuxToken == "Up")
        #expect(KeyName.ctrlC.tmuxToken == "C-c")
        #expect(KeyName.pageUp.tmuxToken == "PPage")
        #expect(KeyName.pageDown.tmuxToken == "NPage")
        #expect(KeyName.home.tmuxToken == "Home")
        #expect(KeyName.end.tmuxToken == "End")
    }

    @Test("KeyToken decodes the wire form for named keys and literal text")
    func decodeTokens() throws {
        let named = try JSONValue.object(["key": .string("Enter")]).decode(KeyToken.self)
        #expect(named == .named(.enter))
        let text = try JSONValue.object(["text": .string("hi")]).decode(KeyToken.self)
        #expect(text == .text("hi"))
    }

    @Test("KeyToken round-trips through JSON")
    func roundTrip() throws {
        let chord: [KeyToken] = [.text("y"), .named(.enter)]
        let json = try JSONValue(encodable: chord)
        let back = try json.decode([KeyToken].self)
        #expect(back == chord)
    }

    @Test("an unknown key name fails to decode")
    func rejectUnknownKey() {
        #expect(throws: (any Error).self) {
            try JSONValue.object(["key": .string("F13")]).decode(KeyToken.self)
        }
    }

    @Test("an element with neither key nor text fails to decode")
    func rejectEmptyToken() {
        #expect(throws: (any Error).self) {
            try JSONValue.object([:]).decode(KeyToken.self)
        }
    }
}
