import Testing
import Foundation
@testable import OrchestraCore

@Suite struct AdapterEncodeTests {
    @Test("Claude encode wraps additionalContext + continuation; empty → nil")
    func claudeEncode() {
        let a = ClaudeCodeAdapter()
        #expect(a.encode(HookResponse(additionalContext: "hi"), for: .sessionStart)?
                    .contains("\"additionalContext\":\"hi\"") == true)
        #expect(a.encode(HookResponse(continuation: "go"), for: .stop)?
                    .contains("\"decision\":\"block\"") == true)
        #expect(a.encode(HookResponse(), for: .stop) == nil)
    }

    @Test("Codex encode matches the shared envelope")
    func codexEncode() {
        #expect(CodexAdapter().encode(HookResponse(additionalContext: "hi"), for: .sessionStart)?
                    .contains("\"additionalContext\":\"hi\"") == true)
    }

    @Test("sessionSource reads payload[source], defaults .other")
    func source() {
        let a = ClaudeCodeAdapter()
        #expect(a.sessionSource(.object(["source": .string("compact")])) == .compact)
        #expect(a.sessionSource(.object([:])) == .other)
    }

    @Test("StubAdapter inherits fail-safe defaults: nil encode, .other source")
    func stubDefaults() {
        let s = StubAdapter(transcriptDir: NSTemporaryDirectory())
        #expect(s.encode(HookResponse(additionalContext: "x"), for: .sessionStart) == nil)  // no silent Claude shape
        #expect(s.sessionSource(.object([:])) == .other)
    }
}
