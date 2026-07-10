import Foundation
import Testing
@testable import OrchestraCore

@Suite("D3 · spawn seed (Fork/Fan-out primitive)")
struct SpawnSeedTests {

    @Test("spawn with a seed folds it ahead of the prompt into the launch positional")
    func seedFoldedIntoLaunch() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, 
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
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, 
            SpawnInput(prompt: "", repo: repo, branch: "fk2", seed: "SLICE"))
        #expect(t.titleProvisional == false)
        #expect(t.phaseDisplay == .running)
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(try #require(argv.last).contains("SLICE"))
    }

    @Test("spawn without a seed is unchanged (no seed positional)")
    func noSeedUnchanged() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(prompt: "plain", repo: repo, branch: "p"))
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
        // Non-blocking spawn: drive the reconciler so the LaunchStepper brings the session up, then assert
        // the seed rode the launch positional.
        try await pollUntil {
            await env.svc.reconcile()
            return env.sessions.ensureArgv[env.sessions.sessionName(task.id)] != nil
        }
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(task.id)])
        #expect(try #require(argv.last).contains("FORK-SEED"))
    }
}

@Suite("D3 · trustState query (read-only)")
struct TrustStateTests {

    @Test("registry includes trustState")
    func inRegistry() {
        #expect(CommandRegistry().command("trustState") != nil)
    }

    @Test("untrusted path → trusted:false; recorded path → trusted:true; query has no side effect")
    func trustStateQuery() async throws {
        let env = TestEnv.make()
        let reg = CommandRegistry()
        let cmd = try #require(reg.command("trustState"))
        let dir = env.base + "/borrowed-dir"

        let before = try await cmd.run(env.svc, .object(["path": .string(dir)]), .app)
        #expect(before["trusted"]?.boolValue == false)
        // Querying must NOT record — a second query is still false.
        let again = try await cmd.run(env.svc, .object(["path": .string(dir)]), .app)
        #expect(again["trusted"]?.boolValue == false)

        try await env.trust.record(dir, grantedBy: .human)
        let after = try await cmd.run(env.svc, .object(["path": .string(dir)]), .app)
        #expect(after["trusted"]?.boolValue == true)
    }
}
