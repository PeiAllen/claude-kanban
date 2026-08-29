import Testing
import Foundation
@testable import OrchestraCore

/// B2 — the `stopHookActive` sibling field wiring. The extractor reads the raw Stop stdin for BOTH agents,
/// and the builder is what `ReportHelper` sends: testing it here (not only a hand-built round-trip RPC)
/// means a key typo in the ReportHelper→RPC construction fails a unit test instead of silently breaking
/// every real continuation's confirm.
@Suite("B2 · HookRPC — stopHookActive sibling field")
struct HookRPCTests {
    @Test("stopHookActive reads the top-level raw-Stop bool for both agents; absent → nil")
    func extractsStopHookActive() {
        // Claude-shaped Stop stdin.
        let claude = try! JSONValue.parse(Data(#"{"hook_event_name":"Stop","stop_hook_active":true}"#.utf8))
        #expect(HookRPC.stopHookActive(claude) == true)
        // Codex-shaped Stop stdin (a different envelope, same top-level flag) — agent-agnostic single read.
        let codex = try! JSONValue.parse(Data(#"{"type":"stop","stop_hook_active":false,"session_id":"x"}"#.utf8))
        #expect(HookRPC.stopHookActive(codex) == false)
        // A plain Stop / a non-Stop event has no such key.
        let plain = try! JSONValue.parse(Data(#"{"hook_event_name":"Stop"}"#.utf8))
        #expect(HookRPC.stopHookActive(plain) == nil)
    }

    @Test("hookFields carries stopHookActive under the shared key, and only when present")
    func builderCarriesStopHookActive() {
        let payload: JSONValue = .object(["session_id": .string("claude-session")])
        let on = HookRPC.hookFields(ref: "c", event: "stop", report: nil, source: nil,
                                    epoch: 7, stopHookActive: true, observationPayload: payload)
        #expect(on[HookRPC.stopHookActiveKey] == .bool(true))   // rides under the ONE shared key
        #expect(on["epoch"] == .int(7))
        #expect(on["ref"] == .string("c"))
        #expect(on[HookRPC.observationPayloadKey] == payload)

        // Rides ONLY when present (like epoch): a nil flag omits the key, so the daemon default applies.
        let off = HookRPC.hookFields(ref: "c", event: "session", report: nil, source: "startup",
                                     epoch: nil, stopHookActive: nil, observationPayload: nil)
        #expect(off[HookRPC.stopHookActiveKey] == nil)
        #expect(off[HookRPC.observationPayloadKey] == nil)
        #expect(off["epoch"] == nil)
        #expect(off["source"] == .string("startup"))
    }

    @Test("provider message endpoints round-trip only through the ephemeral hook field")
    func claudeMessageEndpointRoundTrip() {
        let captured = AgentMessageEndpointReport(
            providerId: "claude-code",
            harnessSessionId: "session-1",
            endpoint: .claudeHookRPC(
                socketPath: "/tmp/claude-message.sock",
                token: "runtime-secret"
            )
        )

        let fields = HookRPC.hookFields(
            ref: "c", event: "statusline", report: nil, source: nil,
            epoch: 9, stopHookActive: nil, messageEndpoint: captured
        )
        #expect(HookRPC.messageEndpoint(fields[HookRPC.messageEndpointKey]) == captured)
    }
}
