import Foundation
import Testing
@testable import OrchestraCore

@Suite("ControlServer ⇄ ControlClient — UDS JSON-RPC round-trip", .serialized)
struct ControlRoundTripTests {

    /// Short socket path (sun_path limit ~104). Tests run unsandboxed so /tmp is writable.
    static func sock() -> String { "/tmp/orch-\(UUID().uuidString.prefix(8)).sock" }

    @Test("call spawn/status/move/archive over the socket; subscribe receives a pushed event")
    func roundTrip() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start()
        defer { server.stop() }

        let client = ControlClient(socketPath: path, source: .cli)
        try client.connect()
        defer { client.close() }

        // subscribe + collect events
        let collected = EventBox()
        let stream = client.subscribe()
        _Concurrency.Task { for await e in stream { await collected.add(e) } }
        try await _Concurrency.Task.sleep(for: .milliseconds(50))

        // spawn
        let spawnRes = try await client.call("spawn", .object([
            "prompt": .string("Build the thing"), "repo": .string(repo), "branch": .string("feat"),
        ]))
        let task = try spawnRes.decode(Task.self)
        #expect(task.title == "Build the thing")

        // status
        let stRes = try await client.call("status", .object(["ref": .string(task.shortId)]))
        #expect(try stRes.decode(TaskStatus.self).task.id == task.id)

        // move
        _ = try await client.call("move", .object(["ref": .string(task.shortId), "col": .string("review")]))
        let listRes = try await client.call("list", .object([:]))
        #expect(try listRes.decode([Task].self).first { $0.id == task.id }?.column == .review)

        // archive
        _ = try await client.call("archive", .object(["ref": .string(task.shortId)]))
        let listRes2 = try await client.call("list", .object([:]))
        #expect(try listRes2.decode([Task].self).isEmpty)

        // we should have received pushed events
        try await _Concurrency.Task.sleep(for: .milliseconds(100))
        let events = await collected.events
        #expect(events.contains { if case .taskUpserted = $0 { return true } else { return false } })
        #expect(events.contains { if case .activity(let a) = $0 { return a.kind == .spawned } else { return false } })
    }

    @Test("a fresh subscribe backfills the recent activity ring buffer")
    func ringReplay() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start()
        defer { server.stop() }

        // First client spawns (producing a .spawned activity into the ring).
        let c1 = ControlClient(socketPath: path, source: .cli)
        try c1.connect()
        _ = try await c1.call("spawn", .object([
            "prompt": .string("Earlier card"), "repo": .string(repo), "branch": .string("b")]))
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        c1.close()

        // A brand-new client subscribes and should get the prior .spawned via ring replay.
        let c2 = ControlClient(socketPath: path, source: .app)
        try c2.connect()
        defer { c2.close() }
        let box = EventBox()
        let stream = c2.subscribe()
        _Concurrency.Task { for await e in stream { await box.add(e) } }
        try await _Concurrency.Task.sleep(for: .milliseconds(150))
        let acts = await box.events.compactMap { if case .activity(let a) = $0 { return a } else { return nil } }
        #expect(acts.contains { $0.kind == .spawned && $0.text.contains("Earlier card") })
    }

    @Test("drain RPC returns the composed inbox payload for a card")
    func drainRPC() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }
        let client = ControlClient(socketPath: path, source: .agent)
        try client.connect(); defer { client.close() }

        let spawnRes = try await client.call("spawn", .object([
            "prompt": .string("c"), "repo": .string(repo), "branch": .string("feat")]))
        let task = try spawnRes.decode(Task.self)

        // empty inbox → reason is null
        let empty = try await client.call("drain", .object(["ref": .string(task.shortId)]))
        #expect(empty["reason"]?.stringValue == nil)

        // enqueue via send, then drain returns the payload
        try await env.svc.send(task.id, "queued work")
        let got = try await client.call("drain", .object(["ref": .string(task.shortId)]))
        #expect(got["reason"]?.stringValue?.contains("queued work") == true)
    }

    @Test("ping / version / getConfig over the socket")
    func meta() async throws {
        let env = TestEnv.make()
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start()
        defer { server.stop() }
        let client = ControlClient(socketPath: path, source: .cli)
        try client.connect()
        defer { client.close() }

        #expect(try await client.call("ping")["ok"]?.boolValue == true)
        #expect(try await client.call("version")["version"]?.stringValue == OrchestraVersion.current)
        let cfg = try await client.call("getConfig").decode(Config.self)
        #expect(cfg.maxConcurrentRevivals == 4)
    }
}

actor EventBox {
    private(set) var events: [Event] = []
    func add(_ e: Event) { events.append(e) }
}
