import Foundation
import Testing
@testable import OrchestraCore

@Suite("D3 · spawn seed (Fork/Fan-out primitive)")
struct SpawnSeedTests {

    @Test("spawn with a seed folds it ahead of the prompt into the launch positional")
    func seedFoldedIntoLaunch() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(
            SpawnInput(prompt: "Do the fork task", repo: repo, branch: "fk", seed: "PARENT-CONTEXT"))
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        let positional = try #require(argv.last)
        #expect(positional.contains("PARENT-CONTEXT"))
        #expect(positional.contains("Do the fork task"))
        // Seed comes first (it's the context the fresh task opens on).
        #expect(positional.range(of: "PARENT-CONTEXT")!.lowerBound
                < positional.range(of: "Do the fork task")!.lowerBound)
    }

    @Test("seed-only spawn (empty prompt) launches on the seed and is not provisional")
    func seedOnlyNotProvisional() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(
            SpawnInput(prompt: "", repo: repo, branch: "fk2", seed: "SLICE"))
        #expect(t.titleProvisional == false)
        #expect(t.status == .running)
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(try #require(argv.last).contains("SLICE"))
    }

    @Test("spawn without a seed is unchanged (no seed positional)")
    func noSeedUnchanged() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "plain", repo: repo, branch: "p"))
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.last == "plain")
    }

    @Test("spawn Command threads `seed` to the service")
    func spawnCommandSeed() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let reg = CommandRegistry()
        let spawn = try #require(reg.command("spawn"))
        let params = JSONValue.object([
            "prompt": .string("task"), "repo": .string(repo), "branch": .string("s"),
            "seed": .string("FORK-SEED"),
        ])
        let task = try await spawn.run(env.svc, params, .mcp).decode(Task.self)
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(task.id)])
        #expect(try #require(argv.last).contains("FORK-SEED"))
    }
}
