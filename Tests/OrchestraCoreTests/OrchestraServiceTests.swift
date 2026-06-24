import Foundation
import Testing
@testable import OrchestraCore

@Suite("OrchestraService — spawn / move / archive / exec / sessions")
struct OrchestraServiceTests {

    @Test("spawn takes only a prompt; seeds title; persists initialPrompt; mints session id + argv; emits")
    func spawnSeeds() async throws {
        let env = TestEnv.make()
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        let repo = TestEnv.repo(env.base)

        let task = try await env.svc.spawn(
            SpawnInput(prompt: "Add OAuth login flow\nwith refresh", repo: repo, branch: "feat", startIn: .plan),
            source: .app)

        #expect(task.title == "Add OAuth login flow")     // first line seeds the title
        #expect(task.titleProvisional == false)
        #expect(task.desc == "")
        #expect(task.initialPrompt == "Add OAuth login flow\nwith refresh")
        #expect(task.column == .plan)
        #expect(task.status == .running)
        let sid = try #require(task.agentSessionId)
        // launch argv carries --session-id <that id> + the prompt
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(task.id)])
        #expect(argv.contains("--session-id"))
        #expect(argv.contains(sid))
        #expect(argv.last == "Add OAuth login flow\nwith refresh")

        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(await collector.upserts.contains { $0.id == task.id })
        #expect(await collector.activities.contains { $0.kind == .spawned && $0.source == .app })
    }

    @Test("spawn rejects a non-allowlisted repo before creating anything")
    func spawnRejectsRepo() async throws {
        let env = TestEnv.make()
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.spawn(SpawnInput(prompt: "x", repo: "/etc", branch: "b"), source: .cli)
        }
        #expect(env.sessions.ensureCount == 0)
    }

    @Test("move sets column + reorders + emits .moved")
    func move() async throws {
        let env = TestEnv.make()
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b", startIn: .plan))
        let moved = try await env.svc.move(t.id, to: .review, source: .app)
        #expect(moved.column == .review)
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(await collector.activities.contains { $0.kind == .moved })
    }

    @Test("archive sets done + archived, kills session, emits")
    func archive() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        try await env.svc.archive(t.id, source: .app)
        let after = await env.svc.list(includeArchived: true).first { $0.id == t.id }
        #expect(after?.status == .done)
        #expect(after?.archived == true)
        #expect(env.sessions.killed.contains(env.sessions.sessionName(t.id)))
        // archived cards are off the board
        #expect(await env.svc.list().isEmpty)
    }

    @Test("exec runs in the worktree and returns output without throwing on non-zero exit")
    func exec() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        let ok = try await env.svc.exec(t.id, "echo hi")
        #expect(ok.stdout.contains("hi"))
        #expect(ok.exitCode == 0)
        let bad = try await env.svc.exec(t.id, "exit 7")
        #expect(bad.exitCode == 7)   // non-zero is a value, not a throw
    }

    @Test("sessions returns tmux targets + agent session id; dead session → empty targets but id persists")
    func sessions() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        let cs = try await env.svc.sessions(t.id)
        #expect(cs.running)
        #expect(cs.targets.first?.kind == .agent)
        #expect(cs.agent.sessionId == t.agentSessionId)
        // kill -> dead session: empty targets but the persisted id still returns
        try env.sessions.kill(env.sessions.sessionName(t.id))
        let cs2 = try await env.svc.sessions(t.id)
        #expect(!cs2.running)
        #expect(cs2.targets.isEmpty)
        #expect(cs2.agent.sessionId == t.agentSessionId)
    }
}
