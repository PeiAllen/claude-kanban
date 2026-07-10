import Foundation
import Testing
@testable import OrchestraCore

@Suite("send-keys command — param validation")
struct SendKeysCommandTests {

    private func command() -> Command {
        let cmd = CommandRegistry().command("send-keys")
        #expect(cmd != nil)
        return cmd!
    }

    @Test("registry exposes send-keys with ref + keys required")
    func registered() throws {
        let cmd = command()
        #expect(cmd.name == "send-keys")
        let required = cmd.schema.params["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required.contains("ref"))
        #expect(required.contains("keys"))
    }

    @Test("empty keys array is rejected before any session work")
    func rejectsEmptyKeys() async {
        let svc = TestEnv.make().svc   // in-memory service; validation fails before session lookup
        let params = JSONValue.object(["ref": .string("nonexistent"), "keys": .array([])])
        await #expect(throws: (any Error).self) {
            _ = try await command().run(svc, params, .cli)
        }
    }

    @Test("a keys element with an empty text run is rejected")
    func rejectsEmptyText() async {
        let svc = TestEnv.make().svc
        let params = JSONValue.object([
            "ref": .string("nonexistent"),
            "keys": .array([.object(["text": .string("")])]),
        ])
        await #expect(throws: (any Error).self) {
            _ = try await command().run(svc, params, .cli)
        }
    }

    @Test("an unknown key name is rejected")
    func rejectsUnknownKey() async {
        let svc = TestEnv.make().svc
        let params = JSONValue.object([
            "ref": .string("nonexistent"),
            "keys": .array([.object(["key": .string("F13")])]),
        ])
        await #expect(throws: (any Error).self) {
            _ = try await command().run(svc, params, .cli)
        }
    }

    @Test("a valid chord dispatches to the session on a live card")
    func dispatchesValidChord() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        env.sessions.setAlive(t.id, true)

        let params = JSONValue.object([
            "ref": .string(t.shortId),
            "keys": .array([.object(["text": .string("y")]), .object(["key": .string("Enter")])]),
        ])
        let res = try await command().run(env.svc, params, .cli)
        #expect(res["ok"]?.boolValue == true)
        // The chord reached the stub session verbatim (text run then a named Enter).
        let chords = env.sessions.sentChords.filter { $0.name == env.sessions.sessionName(t.id) }
        #expect(chords.count == 1)
        #expect(chords.first?.tokens == [.text("y"), .named(.enter)])
    }
}
