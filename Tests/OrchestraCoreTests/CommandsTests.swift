import Foundation
import Testing
@testable import OrchestraCore

@Suite("CommandRegistry — the one shared command set")
struct CommandsTests {

    @Test("registry exposes the full command set with param schemas")
    func fullSet() {
        let reg = CommandRegistry()
        // The command *set* is pinned once in CommandRegistryCatalogTests (registry == catalog, and the
        // catalog against a literal) — no second hand-maintained name list to drift here. This test's
        // unique job: the registry is non-empty and every command it exposes carries an object param
        // schema with properties.
        #expect(!reg.commands.isEmpty)
        for c in reg.commands {
            #expect(c.schema.params["type"]?.stringValue == "object")
            #expect(c.schema.params["properties"] != nil)
        }
    }

    @Test("spawn dispatches to the service and returns a Task incl. ref")
    func dispatchSpawn() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let reg = CommandRegistry()
        let spawn = try #require(reg.command("spawn"))
        let params = JSONValue.object([
            "prompt": .string("Do the thing"),
            "repo": .string(repo),
            "branch": .string("feat"),
            "col": .string("plan"),
        ])
        let result = try await spawn.run(env.svc, params, .mcp)
        let task = try result.decode(Task.self)
        #expect(task.title == "Do the thing")
        #expect(task.ref().hasPrefix("orchestra://task/"))
    }

    @Test("move/status/exec dispatch by ref")
    func dispatchByRef() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        let reg = CommandRegistry()

        // move by shortId
        let move = try #require(reg.command("move"))
        let moved = try await move.run(env.svc, .object(["ref": .string(t.shortId), "col": .string("review")]), .cli)
        #expect(try moved.decode(Task.self).column == .review)

        // status by orchestra:// URI
        let status = try #require(reg.command("status"))
        let st = try await status.run(env.svc, .object(["ref": .string(t.ref())]), .cli)
        #expect(try st.decode(TaskStatus.self).task.id == t.id)

        // exec
        let exec = try #require(reg.command("exec"))
        let ex = try await exec.run(env.svc, .object(["ref": .string(t.shortId), "cmd": .string("echo yo")]), .mcp)
        #expect(try ex.decode(ExecResult.self).stdout.contains("yo"))
    }

    @Test("capture dispatches to a read of the card's agent pane")
    func dispatchCapture() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        // Make the card's tmux session deterministically alive for the read (spawn's ensure is async).
        env.sessions.setAlive(t.id, true)

        let reg = CommandRegistry()
        let capture = try #require(reg.command("capture"))
        let res = try await capture.run(env.svc, .object(["ref": .string(t.shortId)]), .mcp)
        let cap = try res.decode(CaptureResult.self)
        #expect(cap.window == "agent")
        // The stub echoes the session name into its pane text.
        #expect(cap.text.contains(env.sessions.sessionName(t.id)))

        // A read of a card whose session isn't running surfaces an error.
        let t2 = try await env.svc.spawn(SpawnInput(prompt: "y", repo: repo, branch: "c"))
        env.sessions.setAlive(t2.id, false)
        await #expect(throws: OrchestraError.self) {
            _ = try await capture.run(env.svc, .object(["ref": .string(t2.shortId)]), .mcp)
        }
    }

    @Test("reopen dispatches to the service and unarchives the card")
    func dispatchReopen() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        try await env.svc.archive(t.id)
        let reg = CommandRegistry()
        let reopen = try #require(reg.command("reopen"))
        let result = try await reopen.run(env.svc, .object(["ref": .string(t.shortId)]), .app)
        #expect(try result.decode(Task.self).archived == false)
    }

    @Test("batch-spawn creates N cards")
    func batchSpawn() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let reg = CommandRegistry()
        let bs = try #require(reg.command("batch-spawn"))
        let params = JSONValue.object(["tasks": .array([
            .object(["prompt": .string("one"), "repo": .string(repo), "branch": .string("o")]),
            .object(["prompt": .string("two"), "repo": .string(repo), "branch": .string("t")]),
        ])])
        let res = try await bs.run(env.svc, params, .cli)
        let result = try res.decode(BatchSpawnResult.self)
        #expect(result.spawned.count == 2)
        #expect(result.failed.isEmpty)
    }

    @Test("batch-spawn reports partial failure instead of aborting")
    func batchSpawnPartial() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let reg = CommandRegistry()
        let bs = try #require(reg.command("batch-spawn"))
        let params = JSONValue.object(["tasks": .array([
            .object(["prompt": .string("ok"), "repo": .string(repo), "branch": .string("a")]),
            // a non-allowlisted repo fails resolveRepo → recorded, not thrown
            .object(["prompt": .string("bad"), "repo": .string("/not/allowed"), "branch": .string("b")]),
        ])])
        let result = try await bs.run(env.svc, params, .cli).decode(BatchSpawnResult.self)
        #expect(result.spawned.count == 1)
        #expect(result.failed.count == 1)
        #expect(result.failed.first?.index == 1)
        #expect(result.failed.first?.prompt == "bad")
    }

    @Test("an unknown ref surfaces as a thrown OrchestraError")
    func unknownRef() async throws {
        let env = TestEnv.make()
        let reg = CommandRegistry()
        let status = try #require(reg.command("status"))
        await #expect(throws: OrchestraError.self) {
            _ = try await status.run(env.svc, .object(["ref": .string("zzzzzz")]), .cli)
        }
    }

    @Test("inbox lists, inbox-edit rewrites, inbox-remove drops, inbox-reorder permutes")
    func inboxCrud() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let reg = CommandRegistry()
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        try await env.svc.send(t.id, "one")
        try await env.svc.send(t.id, "two")

        // inbox (list)
        let list = try #require(reg.command("inbox"))
        let msgs = try await list.run(env.svc, .object(["ref": .string(t.shortId)]), .mcp)
            .decode([InboxMessage].self)
        #expect(msgs.map(\.text) == ["one", "two"])

        // inbox-edit
        let edit = try #require(reg.command("inbox-edit"))
        _ = try await edit.run(env.svc, .object(["ref": .string(t.shortId),
            "id": .string(msgs[0].id.uuidString), "text": .string("ONE")]), .mcp)

        // inbox-reorder → [two, one]
        let reorder = try #require(reg.command("inbox-reorder"))
        _ = try await reorder.run(env.svc, .object(["ref": .string(t.shortId),
            "ids": .array([.string(msgs[1].id.uuidString), .string(msgs[0].id.uuidString)])]), .mcp)

        let afterEdit = try await list.run(env.svc, .object(["ref": .string(t.shortId)]), .mcp)
            .decode([InboxMessage].self)
        #expect(afterEdit.map(\.text) == ["two", "ONE"])

        // inbox-remove
        let remove = try #require(reg.command("inbox-remove"))
        _ = try await remove.run(env.svc, .object(["ref": .string(t.shortId),
            "id": .string(msgs[1].id.uuidString)]), .mcp)
        let final = try await list.run(env.svc, .object(["ref": .string(t.shortId)]), .mcp)
            .decode([InboxMessage].self)
        #expect(final.map(\.text) == ["ONE"])
    }

    @Test("inbox-edit rejects a non-UUID id")
    func inboxBadId() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let reg = CommandRegistry()
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        let edit = try #require(reg.command("inbox-edit"))
        await #expect(throws: OrchestraError.self) {
            _ = try await edit.run(env.svc, .object(["ref": .string(t.shortId),
                "id": .string("not-a-uuid"), "text": .string("z")]), .mcp)
        }
    }

    @Test("JSONValue round-trips Codable models")
    func jsonRoundTrip() throws {
        // whole-second date so ISO8601 (no fractional seconds) round-trips exactly
        let item = ActivityItem(at: Date(timeIntervalSince1970: 1_700_000_000),
                                taskId: UUID(), ref: "orchestra://task/abc", source: .agent,
                                kind: .spawned, text: "hi")
        let jv = try JSONValue(encodable: item)
        let back = try jv.decode(ActivityItem.self)
        #expect(back == item)
    }
}
