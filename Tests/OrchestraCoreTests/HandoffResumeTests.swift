import Foundation
import Testing
@testable import OrchestraCore

@Suite("C3 · F1 — HandoffSeed.fold")
struct HandoffSeedTests {

    private func msg(_ card: UUID, _ text: String) -> InboxMessage { InboxMessage(cardId: card, text: text) }

    @Test("fold: handoff first, then inbox in FIFO order, joined by blank lines")
    func order() {
        let c = UUID()
        let s = HandoffSeed.fold(handoff: "HANDOFF", inbox: [msg(c, "one"), msg(c, "two")])
        #expect(s == "HANDOFF\n\none\n\ntwo")
    }

    @Test("fold: nil handoff falls back to inbox only")
    func handoffNil() {
        let c = UUID()
        #expect(HandoffSeed.fold(handoff: nil, inbox: [msg(c, "only")]) == "only")
    }

    @Test("fold: whitespace-only handoff is dropped")
    func handoffBlank() {
        let c = UUID()
        #expect(HandoffSeed.fold(handoff: "   \n ", inbox: [msg(c, "x")]) == "x")
    }

    @Test("fold: empty handoff + empty inbox → nil (no seed delivered)")
    func empty() {
        #expect(HandoffSeed.fold(handoff: nil, inbox: []) == nil)
        #expect(HandoffSeed.fold(handoff: "", inbox: []) == nil)
    }

    @Test("fold: over-long payload is clamped with a truncation marker")
    func clamp() {
        let c = UUID()
        let big = String(repeating: "z", count: StopDrain.maxPayloadChars + 500)
        let s = try! #require(HandoffSeed.fold(handoff: big, inbox: [msg(c, "tail")]))
        #expect(s.count <= StopDrain.maxPayloadChars)
        #expect(s.hasPrefix("[…truncated]"))
    }
}

@Suite("C3 · F1 — adapters deliver ctx.seed on resume")
struct SeedDeliveryTests {
    private func ctx(seed: String?) -> AdapterContext {
        AdapterContext(cwd: "/tmp/wt", model: "m", sessionId: "sid-1", name: "Card", seed: seed)
    }

    @Test("Claude resume appends the seed as the trailing positional turn")
    func claudeCarriesSeed() {
        let argv = try! #require(ClaudeCodeAdapter().resume(ctx(seed: "SEED-CTX")))
        #expect(argv.contains("--resume"))
        #expect(argv.last == "SEED-CTX")
    }

    @Test("Claude resume without a seed adds no trailing positional (unchanged)")
    func claudeNoSeed() {
        let argv = try! #require(ClaudeCodeAdapter().resume(ctx(seed: nil)))
        #expect(argv.contains("--resume"))
        #expect(argv.last != "SEED-CTX")
    }

    @Test("Codex resume appends the seed as the trailing positional turn")
    func codexCarriesSeed() {
        let argv = try! #require(CodexAdapter().resume(ctx(seed: "SEED-CTX")))
        #expect(argv.contains("resume"))
        #expect(argv.last == "SEED-CTX")
    }

    @Test("Codex resume without a seed adds no trailing positional (unchanged)")
    func codexNoSeed() {
        let argv = try! #require(CodexAdapter().resume(ctx(seed: nil)))
        #expect(argv.last == "m")            // tail is the `-m m` model flag; no seed positional follows
        #expect(!argv.contains("SEED-CTX"))
    }
}

@Suite("C3 · F1 — OrchestraService.resume(seed:)")
struct ResumeSeedTests {

    @Test("resume(seed:) sets ctx.seed so the launch argv carries the seed; id kept")
    func resumeWithSeed() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        let oldId = t.agentSessionId

        async let resumed = env.svc.resume(t.id, seed: "SEEDED-CTX")
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))
        let updated = try await resumed

        #expect(updated.status == .waiting)
        #expect(updated.agentSessionId == oldId)   // resume keeps the id — NOT a fresh restart
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--resume"))
        #expect(argv.last == "SEEDED-CTX")          // seed delivered as the opening turn
    }
}

@Suite("C3 · F1 — OrchestraService.resumeInCard")
struct ResumeInCardTests {

    /// Spawn a dead-but-resumable card with a transcript on disk.
    private func makeResumable(
        _ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
        branch: String) async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: branch))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        return t
    }

    @Test("resumeInCard carries the handoff seed; keeps the session id (resume, not blank restart)")
    func carriesSeedKeepsId() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await makeResumable(env, branch: "b")
        let oldId = t.agentSessionId

        async let resumed = env.svc.resumeInCard(t.id, seed: "HANDOFF")
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))
        let updated = try await resumed

        #expect(updated.agentSessionId == oldId)   // SAME session id — resume, not restart
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--resume"))          // resume argv, never a fresh `start`
        #expect(argv.last == "HANDOFF")
    }

    @Test("resumeInCard folds the pending inbox into the seed and drains it")
    func inboxFoldsIntoSeed() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await makeResumable(env, branch: "b")
        try await env.svc.send(t.id, "queued-1")
        try await env.svc.send(t.id, "queued-2")

        async let resumed = env.svc.resumeInCard(t.id, seed: "HANDOFF")
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))
        _ = try await resumed

        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        let seed = try #require(argv.last)
        #expect(seed.contains("HANDOFF"))
        #expect(seed.contains("queued-1"))
        #expect(seed.contains("queued-2"))
        // Inbox was drained by the fold — nothing left to double-deliver via a later Stop-drain.
        #expect(await env.svc.drainForStop(t.id) == nil)
    }

    @Test("resumeInCard with no seed and empty inbox delivers no positional (pure resume)")
    func noSeedNoInbox() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await makeResumable(env, branch: "b")

        async let resumed = env.svc.resumeInCard(t.id)
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))
        _ = try await resumed

        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--resume"))
        // StubAdapter.resume tail is `--name <title>`; with no seed nothing follows the name value.
        let nameIdx = try #require(argv.firstIndex(of: "--name"))
        #expect(argv.count == nameIdx + 2)
    }
}
