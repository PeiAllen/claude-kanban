import Foundation
import Testing
@testable import OrchestraCore

@Suite("Codex app-server WebSocket codec")
struct CodexWebSocketTests {
    @Test("RFC 6455 handshake accept matches the published example")
    func handshakeAccept() {
        #expect(WebSocketHandshake.accept(for: "dGhlIHNhbXBsZSBub25jZQ==")
            == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test("client text frames are masked exactly as RFC 6455 requires")
    func maskedClientFrame() throws {
        let frame = WebSocketFrame(fin: true, opcode: .text, payload: Data("Hello".utf8))
        let encoded = try WebSocketFrameCodec.encode(frame, maskKey: [0x37, 0xFA, 0x21, 0x3D])

        #expect(Array(encoded) == [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D,
                                   0x7F, 0x9F, 0x4D, 0x51, 0x58])
        var bytes = encoded
        #expect(try WebSocketFrameCodec.decode(from: &bytes, expectedMask: true) == frame)
        #expect(bytes.isEmpty)
    }

    @Test("extended frames remain buffered until their complete payload arrives")
    func partialExtendedFrame() throws {
        let payload = Data(repeating: 0x61, count: 130)
        let encoded = try WebSocketFrameCodec.encode(
            .init(fin: true, opcode: .text, payload: payload),
            maskKey: nil
        )
        var partial = Data(encoded.dropLast(1))
        let before = partial

        #expect(try WebSocketFrameCodec.decode(from: &partial, expectedMask: false) == nil)
        #expect(partial == before)

        partial.append(encoded.last!)
        #expect(try WebSocketFrameCodec.decode(from: &partial, expectedMask: false)?.payload == payload)
        #expect(partial.isEmpty)
    }

    @Test("server frames carrying a client mask are rejected")
    func rejectsMaskedServerFrame() throws {
        var bytes = try WebSocketFrameCodec.encode(
            .init(fin: true, opcode: .text, payload: Data("x".utf8)),
            maskKey: [1, 2, 3, 4]
        )

        #expect(throws: CodexAppServerError.protocolViolation("unexpected WebSocket mask")) {
            _ = try WebSocketFrameCodec.decode(from: &bytes, expectedMask: false)
        }
    }

    @Test("fragmented control frames are rejected")
    func rejectsFragmentedControlFrame() throws {
        // FIN=0, opcode=ping, unmasked empty payload. Build the malformed wire
        // fixture directly so the encoder cannot reject it before the decoder.
        var bytes = Data([0x09, 0x00])

        #expect(throws: CodexAppServerError.protocolViolation("fragmented WebSocket control frame")) {
            _ = try WebSocketFrameCodec.decode(from: &bytes, expectedMask: false)
        }
    }
}
