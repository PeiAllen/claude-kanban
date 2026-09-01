import Testing
import Foundation
@testable import OrchestraCore

@Suite struct HookChannelTests {
    @Test("HookEvent raw values map the --event strings")
    func events() {
        #expect(HookEvent(rawValue: "session") == .sessionStart)
        #expect(HookEvent(rawValue: "messagedisplay") == .messageDisplay)
        #expect(HookEvent(rawValue: "pretool") == .preToolUse)
        #expect(HookEvent(rawValue: "posttool") == .postToolUse)
        #expect(HookEvent(rawValue: "posttoolfailure") == .postToolUseFailure)
        #expect(HookEvent(rawValue: "notification") == .notification)
        #expect(HookEvent(rawValue: "taskcompleted") == .taskCompleted)
        #expect(HookEvent(rawValue: "stop") == .stop)
        #expect(HookEvent(rawValue: "orient") == nil)          // collapsed into sessionStart
        #expect(HookEvent.sessionStart.rawValue == "session")
    }

    @Test("SessionSource parses known values")
    func source() {
        #expect(SessionSource(rawValue: "compact") == .compact)
        #expect(SessionSource(rawValue: "startup") == .startup)
        #expect(SessionSource(rawValue: "bogus") == nil)
    }

    @Test("HookResponse round-trips through JSON")
    func response() throws {
        let r = HookResponse(additionalContext: "hi")
        let back = try JSONValue(encodable: r).decode(HookResponse.self)
        #expect(back == r)
    }

    @Test("HookEnvelope encodes session-start stdout")
    func envelope() {
        let ac = HookEnvelope.additionalContext("X")
        #expect(ac.contains("\"additionalContext\":\"X\""))
        #expect(ac.contains("\"hookEventName\":\"SessionStart\""))
    }

    @Test("HookEnvelope.additionalContext escapes newlines/quotes")
    func envelopeEscaping() throws {
        let s = HookEnvelope.additionalContext("line1\nline2 \"q\"")
        // round-trips back to the original context string
        let parsed = try JSONValue.parse(Data(s.utf8))
        #expect(parsed["hookSpecificOutput"]?["additionalContext"]?.stringValue == "line1\nline2 \"q\"")
    }
}
