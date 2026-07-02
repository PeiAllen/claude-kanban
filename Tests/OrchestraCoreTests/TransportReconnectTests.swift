import Foundation
import Testing
@testable import OrchestraCore

@Suite("Transport + reconnect", .serialized)
struct TransportReconnectTests {
    static func sock() -> String { "/tmp/orch-\(UUID().uuidString.prefix(8)).sock" }

    @Test("UDSTransport open/write/readLine round-trips a ping against ControlServer")
    func udsRoundTrip() async throws {
        let env = TestEnv.make()
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }

        let t = UDSTransport(socketPath: path)
        try t.open()
        defer { t.close() }
        let line = try RPCCodec.line(RPCRequest(id: 1, method: "ping"))
        #expect(t.write(line))
        let reply = try #require(t.readLine())
        let msg = try RPCCodec.decoder.decode(WireMessage.self, from: reply)
        #expect(msg.result?["ok"]?.boolValue == true)
    }
}
