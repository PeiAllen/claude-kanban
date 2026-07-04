import Foundation
import Testing
@testable import OrchestraCore

@Suite("D3 — server tracks connection→clientId", .serialized)
struct ClientIdentityServerTests {
    static func sock() -> String { "/tmp/orch-\(UUID().uuidString.prefix(8)).sock" }

    @Test("server records the caller's clientId and exposes it via connectedClientIds()")
    func serverTracksClientId() async throws {
        let env = TestEnv.make()
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }

        let client = ControlClient(socketPath: path, source: .app, clientId: "phone-77")
        try client.connect(); defer { client.close() }
        _ = client.subscribe()
        _ = try await client.call("ping")
        try await _Concurrency.Task.sleep(for: .milliseconds(80))

        #expect(server.connectedClientIds().contains("phone-77"))
    }

    @Test("an anonymous CLI client contributes no clientId and still works")
    func serverToleratesMissingClientId() async throws {
        let env = TestEnv.make()
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }

        let cli = ControlClient(socketPath: path, source: .cli)   // no clientId
        try cli.connect(); defer { cli.close() }
        _ = cli.subscribe()
        #expect(try await cli.call("ping")["ok"]?.boolValue == true)
        try await _Concurrency.Task.sleep(for: .milliseconds(80))

        #expect(server.connectedClientIds().isEmpty)
    }

    @Test("closing a client fires onClientDisconnect with its clientId")
    func disconnectFiresCallback() async throws {
        let env = TestEnv.make()
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        let fired = ClientIdBox()
        server.onClientDisconnect = { id in _Concurrency.Task { await fired.add(id) } }
        try server.start(); defer { server.stop() }

        let client = ControlClient(socketPath: path, source: .app, clientId: "phone-gone")
        try client.connect()
        _ = client.subscribe()
        _ = try await client.call("ping")
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        client.close()                                              // EOF → server-side teardown
        try await _Concurrency.Task.sleep(for: .milliseconds(200))

        #expect(await fired.ids == ["phone-gone"])                 // fired exactly once, with the id
    }

    @Test("an anonymous client's disconnect fires nothing")
    func anonymousDisconnectSilent() async throws {
        let env = TestEnv.make()
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        let fired = ClientIdBox()
        server.onClientDisconnect = { id in _Concurrency.Task { await fired.add(id) } }
        try server.start(); defer { server.stop() }

        let cli = ControlClient(socketPath: path, source: .cli)    // no clientId
        try cli.connect()
        _ = cli.subscribe()
        _ = try await cli.call("ping")
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        cli.close()
        try await _Concurrency.Task.sleep(for: .milliseconds(200))

        #expect(await fired.ids.isEmpty)
    }
}

actor ClientIdBox {
    private(set) var ids: [String] = []
    func add(_ s: String) { ids.append(s) }
}
