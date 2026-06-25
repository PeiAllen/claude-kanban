import Foundation
import Testing
@testable import OrchestraCore

@Suite("CommandRegistry — the one shared command set")
struct CommandsTests {

    @Test("registry exposes the full command set with param schemas")
    func fullSet() {
        let reg = CommandRegistry()
        let expected = ["list", "spawn", "move", "send", "status", "archive",
                        "restart", "resume", "shell", "exec", "sessions", "batch-spawn"]
        #expect(Set(reg.names) == Set(expected))
        for c in reg.commands {
            // every command has an object JSON schema for params
            #expect(c.params["type"]?.stringValue == "object")
            #expect(c.params["properties"] != nil)
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
