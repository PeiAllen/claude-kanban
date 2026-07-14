import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

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

        let client = TestEnv.controlClient(path, source: .cli)
        try client.connect()
        defer { client.close() }

        // subscribe + collect events. `subscribeWithRev` does NOT auto-issue the RPC, so the awaited
        // `call("subscribe")` is a registration BARRIER — acked before we proceed (no fixed sleep).
        let collected = EventBox()
        let stream = client.subscribeWithRev()
        _Concurrency.Task { for await e in stream { await collected.add(e.event) } }
        _ = try await client.call("subscribe")

        // spawn
        let spawnRes = try await client.call("spawn", .object(["id": .string(UUID().uuidString), 
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

        // we should have received pushed events — the delivery is async, so poll for them
        try await pollUntil("pushed events delivered") {
            let events = await collected.events
            return events.contains { if case .taskUpserted = $0 { return true } else { return false } }
                && events.contains { if case .activity(let a) = $0 { return a.kind == .spawned } else { return false } }
        }
    }

    @Test("boardSnapshot returns tasks + config + models + agents + per-card sessions/owners in one call (#7)")
    func boardSnapshotRoundTrip() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }
        let client = TestEnv.controlClient(path, source: .app)
        try client.connect(); defer { client.close() }

        let task = try await client.call("spawn", .object(["id": .string(UUID().uuidString), 
            "prompt": .string("Snapshot me"), "repo": .string(repo), "branch": .string("feat")])).decode(Task.self)

        let snap = try await client.boardSnapshot()
        // The bulk snapshot carries the spawned card plus a session + owner entry for it — the N+1 the
        // client used to fan out per card, now one round trip.
        #expect(snap.tasks.contains { $0.id == task.id })
        #expect(snap.sessions.contains { $0.id == task.id })
        #expect(snap.owners.contains { $0.cardId == task.id })
        // An available (never-taken-over) card reports a nil owner in its snapshot entry.
        #expect(snap.owners.first { $0.cardId == task.id }?.owner == nil)
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
        let c1 = TestEnv.controlClient(path, source: .cli)
        try c1.connect()
        _ = try await c1.call("spawn", .object(["id": .string(UUID().uuidString), 
            "prompt": .string("Earlier card"), "repo": .string(repo), "branch": .string("b")]))
        // the .spawned activity is appended to the replay ring synchronously inside the handled
        // `spawn` call, so it is durably in the ring by the time the RPC returns — no settling wait
        c1.close()

        // A brand-new client subscribes and should get the prior .spawned via ring replay.
        let c2 = TestEnv.controlClient(path, source: .app)
        try c2.connect()
        defer { c2.close() }
        let box = EventBox()
        let stream = c2.subscribe()
        _Concurrency.Task { for await e in stream { await box.add(e) } }
        // Poll for the ring-replayed activity rather than a fixed sleep: the replay arrives asynchronously
        // over the socket, and a heavily-parallel run can push its delivery past a fixed 150ms → false-fail.
        try await pollUntil {
            await box.events.contains {
                if case .activity(let a) = $0 { return a.kind == .spawned && a.text.contains("Earlier card") }
                return false
            }
        }
    }

    @Test("hook RPC: stop drains the inbox into the continuation; empty inbox → null")
    func hookStopDrainRPC() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }
        let client = TestEnv.controlClient(path, source: .agent)
        try client.connect(); defer { client.close() }

        let task = try await client.call("spawn", .object(["id": .string(UUID().uuidString), 
            "prompt": .string("c"), "repo": .string(repo), "branch": .string("feat")])).decode(Task.self)

        // empty inbox → no continuation
        let empty = try await client.call("hook", .object(["ref": .string(task.shortId), "event": .string("stop")]))
        #expect(empty["response"]?["continuation"]?.stringValue == nil)

        // enqueue via send, then stop returns the drain as continuation
        try await env.svc.send(task.id, "queued work")
        let got = try await client.call("hook", .object(["ref": .string(task.shortId), "event": .string("stop")]))
        #expect(got["response"]?["continuation"]?.stringValue?.contains("queued work") == true)
    }

    @Test("hook RPC: sessionStart returns live orientation; the retired RPCs are gone")
    func hookSessionStartRPC() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }
        let client = TestEnv.controlClient(path, source: .agent)
        try client.connect(); defer { client.close() }

        let task = try await client.call("spawn", .object(["id": .string(UUID().uuidString), 
            "prompt": .string("c"), "repo": .string(repo), "branch": .string("feat")])).decode(Task.self)

        _ = try await env.svc.move(task.id, to: .review)
        let got = try await client.call("hook", .object([
            "ref": .string(task.shortId), "event": .string("session"), "source": .string("startup")]))
        let ctx = try #require(got["response"]?["additionalContext"]?.stringValue)
        #expect(ctx.contains("Review"))
        #expect(ctx.contains(task.shortId))

        // compact re-open does NOT re-orient
        let compact = try await client.call("hook", .object([
            "ref": .string(task.shortId), "event": .string("session"), "source": .string("compact")]))
        #expect(compact["response"]?["additionalContext"]?.stringValue == nil)

        // the three RPCs the hook channel replaced are now method-not-found
        for retired in ["report", "drain", "sessionBrief"] {
            await #expect(throws: (any Error).self) {
                _ = try await client.call(retired, .object(["ref": .string(task.shortId)]))
            }
        }
    }

    @Test("diffText / diffStat endpoints route over the socket for a worktree card")
    func diffEndpoints() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }
        let client = TestEnv.controlClient(path, source: .app)
        try client.connect(); defer { client.close() }

        let task = try await client.call("spawn", .object(["id": .string(UUID().uuidString), 
            "prompt": .string("c"), "repo": .string(repo), "branch": .string("feat")])).decode(Task.self)

        // Non-blocking spawn: drive the reconciler so the worktree cwd is materialized before we use it.
        try await pollUntil {
            await env.svc.reconcile()
            return FileManager.default.fileExists(atPath: task.cwd)
        }
        // Turn the card's cwd into a real git repo with an uncommitted change.
        let dir = task.cwd
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            #expect(try Proc.run(["git"] + args, cwd: dir).ok)
        }
        try "one\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        #expect(try Proc.run(["git", "add", "-A"], cwd: dir).ok)
        #expect(try Proc.run(["git", "commit", "-q", "-m", "base"], cwd: dir).ok)
        try "one\ntwo\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)

        // diffStat endpoint → the footer stat, via the socket.
        let statRes = try await client.call("diffStat", .object([
            "ref": .string(task.shortId), "base": .string("working")]))
        #expect(try statRes.decode(DiffStat.self).filesChanged == 1)

        // diffText endpoint → the rendered diff, via the socket.
        let textRes = try await client.call("diffText", .object([
            "ref": .string(task.shortId), "base": .string("working")]))
        #expect(try !textRes.decode(String.self).isEmpty)
    }

    @Test("changedNotes endpoint routes over the socket via the typed client method")
    func changedNotesRoundTrip() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }
        let client = TestEnv.controlClient(path, source: .app)
        try client.connect(); defer { client.close() }

        let task = try await client.call("spawn", .object(["id": .string(UUID().uuidString), 
            "prompt": .string("c"), "repo": .string(repo), "branch": .string("feat")])).decode(Task.self)

        // Non-blocking spawn: drive the reconciler so the worktree cwd is materialized before we use it.
        try await pollUntil {
            await env.svc.reconcile()
            return FileManager.default.fileExists(atPath: task.cwd)
        }
        // Card cwd → a git repo with a committed note, then an uncommitted modify + an untracked add.
        let dir = task.cwd
        #expect(try Proc.run(["mkdir", "-p", dir + "/notes"], cwd: dir).ok)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            #expect(try Proc.run(["git"] + args, cwd: dir).ok)
        }
        try "base\n".write(toFile: dir + "/notes/keep.md", atomically: true, encoding: .utf8)
        #expect(try Proc.run(["git", "add", "-A"], cwd: dir).ok)
        #expect(try Proc.run(["git", "commit", "-q", "-m", "base"], cwd: dir).ok)
        try "edited\n".write(toFile: dir + "/notes/keep.md", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: dir + "/notes/new.md", atomically: true, encoding: .utf8)

        // Typed client method → decoded [NoteFile] over the socket.
        let notes = try await client.changedNotes(task.shortId)
        let byPath = Dictionary(uniqueKeysWithValues: notes.map { ($0.path, $0) })
        #expect(Set(byPath.keys) == ["notes/keep.md", "notes/new.md"])
        #expect(byPath["notes/keep.md"]?.status == .modified)
        #expect(byPath["notes/keep.md"]?.content == "edited\n")
        #expect(byPath["notes/new.md"]?.status == .added)
        #expect(byPath["notes/new.md"]?.content == "new\n")
    }

    @Test("ping / version / getConfig over the socket")
    func meta() async throws {
        let env = TestEnv.make()
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start()
        defer { server.stop() }
        let client = TestEnv.controlClient(path, source: .cli)
        try client.connect()
        defer { client.close() }

        #expect(try await client.call("ping")["ok"]?.boolValue == true)
        #expect(try await client.call("version")["version"]?.stringValue == OrchestraVersion.current)
        let cfg = try await client.call("getConfig").decode(Config.self)
        #expect(cfg.maxConcurrentRevivals == 4)
    }

    @Test("capture round-trips a pane read over the socket via the typed client method")
    func captureRoundTrip() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }

        let client = TestEnv.controlClient(path, source: .cli)
        try client.connect(); defer { client.close() }

        let spawnRes = try await client.call("spawn", .object(["id": .string(UUID().uuidString), 
            "prompt": .string("x"), "repo": .string(repo), "branch": .string("feat"),
        ]))
        let task = try spawnRes.decode(Task.self)
        env.sessions.setAlive(task.id, true)   // same StubSessions instance the server holds

        let cap = try await client.capture(task.shortId)
        #expect(cap.window == "agent")
        #expect(cap.text.contains(env.sessions.sessionName(task.id)))
    }
}
