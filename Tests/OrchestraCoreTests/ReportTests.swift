import Foundation
import Testing
@testable import OrchestraCore

@Suite("OrchestraService.report — merge / rollover / seq-guard / re-title")
struct ReportTests {

    private func spawned() async throws -> (env: ReturnType, task: Task) {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "Initial task", repo: repo, branch: "b"))
        return (env, t)
    }
    typealias ReturnType = (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, base: String)

    @Test("merges only present fields; ctxPct/desc/model update in place")
    func mergeFields() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(ctxPct: 42, model: "m2", desc: "Editing Foo.swift", status: .running))
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.ctxPct == 42)
        #expect(after.desc == "Editing Foo.swift")
        #expect(after.model == "m2")
        #expect(after.status == .running)
    }

    @Test("a new sessionId rolls the old onto priorSessionIds")
    func sessionRollover() async throws {
        let (env, t) = try await spawned()
        let oldId = try #require(t.agentSessionId)
        try await env.svc.report(t.id, StatusReport(sessionId: "brand-new-id", sessionSource: "clear"))
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.agentSessionId == "brand-new-id")
        #expect(after.priorSessionIds.contains(oldId))
        #expect(after.titleProvisional == true)   // clear sets provisional
        #expect(after.status == .waiting)          // clear → idle
    }

    @Test("non-empty sessionName updates title + clears provisional; empty is ignored")
    func sessionName() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(sessionSource: "clear"))  // provisional = true
        try await env.svc.report(t.id, StatusReport(sessionName: "Renamed Card"))
        var after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "Renamed Card")
        #expect(after.titleProvisional == false)
        // empty sessionName must not clobber
        try await env.svc.report(t.id, StatusReport(sessionName: ""))
        after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "Renamed Card")
    }

    @Test("first prompt after /clear re-titles; a second prompt does not")
    func reTitleAfterClear() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(sessionSource: "clear"))   // provisional
        try await env.svc.report(t.id, StatusReport(promptText: "Now do something else\nmore"))
        var after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "Now do something else")
        #expect(after.titleProvisional == false)
        #expect(after.status == .running)
        // a later prompt does NOT re-title
        try await env.svc.report(t.id, StatusReport(promptText: "And another thing"))
        after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "Now do something else")
    }

    @Test("a /rename before a prompt clears provisional so the prompt won't re-title")
    func renameBeatsPrompt() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(sessionSource: "clear"))
        try await env.svc.report(t.id, StatusReport(sessionName: "Explicit Name"))   // clears provisional
        try await env.svc.report(t.id, StatusReport(promptText: "Should not become the title"))
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.title == "Explicit Name")
    }

    @Test("no-delta report = no persist, no event (idempotent)")
    func idempotent() async throws {
        let (env, t) = try await spawned()
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        try await env.svc.report(t.id, StatusReport(ctxPct: 10))
        try await env.svc.report(t.id, StatusReport(ctxPct: 10))   // same value → no event
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        let upserts = await collector.upserts.filter { $0.id == t.id }
        #expect(upserts.count == 1)
    }

    @Test("seq guard: stale snapshot dropped (1→3→2), gauge never ticks backward; per-card")
    func seqGuard() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(seq: 1, ctxPct: 41))
        try await env.svc.report(t.id, StatusReport(seq: 3, ctxPct: 43))
        try await env.svc.report(t.id, StatusReport(seq: 2, ctxPct: 42))   // stale → dropped
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.ctxPct == 43)
        // a second card's low seq is independent
        let t2 = try await env.svc.spawn(SpawnInput(prompt: "second", repo: TestEnv.repo(env.base), branch: "b2"))
        try await env.svc.report(t2.id, StatusReport(seq: 1, ctxPct: 9))
        let after2 = try #require(await env.svc.list().first { $0.id == t2.id })
        #expect(after2.ctxPct == 9)
    }

    @Test("event-ordered transitions are NOT seq-gated (rollover applies even with a low seq)")
    func transitionsNotGated() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(seq: 5, ctxPct: 50))
        // a low-seq report still applies the sessionId rollover (event-ordered), even though its
        // snapshot ctxPct is dropped
        try await env.svc.report(t.id, StatusReport(seq: 1, sessionId: "rolled", ctxPct: 1))
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.agentSessionId == "rolled")   // transition applied
        #expect(after.ctxPct == 50)                  // stale snapshot dropped
    }

    @Test("SessionEnd genuine exit → .dead (agentExited); transition reasons never reach report")
    func sessionEndDead() async throws {
        let (env, t) = try await spawned()
        try await env.svc.report(t.id, StatusReport(endReason: "exit"))
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.status == .dead)
        #expect(after.deadReason == .agentExited)
    }

    @Test("status transition emits .statusChanged; ctxPct-only emits no activity")
    func activityOnlyOnTransition() async throws {
        let (env, t) = try await spawned()
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        try await env.svc.report(t.id, StatusReport(ctxPct: 5))                      // no activity
        try await env.svc.report(t.id, StatusReport(status: .waiting))              // transition
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        let acts = await collector.activities
        #expect(acts.contains { $0.kind == .statusChanged })
        #expect(!acts.contains { $0.kind == .statusChanged && $0.text.contains("ctx") })
    }
}
