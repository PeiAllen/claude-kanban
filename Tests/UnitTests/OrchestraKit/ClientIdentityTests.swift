import Foundation
import Testing
@testable import OrchestraCore

@Suite("D3 — clientId wire shape + persistence helper")
struct ClientIdentityTests {

    @Test("RPCRequest carries clientId when set, omits it when nil, and tolerates a missing key")
    func clientIdWireShape() throws {
        // Set → present on the wire.
        let withId = RPCRequest(id: 1, method: "ping", clientId: "abc-123")
        let line = String(decoding: try RPCCodec.line(withId), as: UTF8.self)
        #expect(line.contains("\"clientId\":\"abc-123\""))

        // Nil (CLI/MCP style) → key omitted entirely (additive on the wire).
        let withoutId = RPCRequest(id: 2, method: "ping")
        let line2 = String(decoding: try RPCCodec.line(withoutId), as: UTF8.self)
        #expect(!line2.contains("clientId"))

        // An older client's frame (no clientId key) decodes with clientId == nil.
        let legacy = Data(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#.utf8)
        let decoded = try RPCCodec.decoder.decode(RPCRequest.self, from: legacy)
        #expect(decoded.clientId == nil)
    }

    @Test("persistentId generates once and is stable across calls")
    func persistentIdStable() {
        let dir = "/tmp/orch-cid-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/client-id"
        let a = ClientIdentity.persistentId(at: path)   // generates + writes (dir auto-created)
        let b = ClientIdentity.persistentId(at: path)   // reads back
        #expect(!a.isEmpty)
        #expect(a == b)
    }

    @Test("persistentId returns a pre-seeded id verbatim")
    func persistentIdSeeded() throws {
        let dir = "/tmp/orch-cid-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/client-id"
        try "seeded-id-42".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(ClientIdentity.persistentId(at: path) == "seeded-id-42")
    }
}
