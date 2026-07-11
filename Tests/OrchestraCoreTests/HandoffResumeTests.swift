import Foundation
import Testing
@testable import OrchestraCore

@Suite("C3 · F1 — HandoffSeed.fold")
struct HandoffSeedTests {

    private func msg(_ card: UUID, _ text: String) -> InboxMessage { InboxMessage(cardId: card, text: text) }

    @Test("fold: handoff first, then the shared numbered inbox render, joined by blank lines")
    func order() {
        let c = UUID()
        let inbox = [msg(c, "one"), msg(c, "two")]
        let s = HandoffSeed.fold(handoff: "HANDOFF", inbox: inbox)
        // Byte-identical to the Claude Stop-drain rendering (agent-agnostic): header + [k/N] numbering.
        #expect(s == "HANDOFF\n\n" + StopDrain.renderMessages(inbox))
    }

    @Test("fold: nil handoff falls back to the numbered inbox render")
    func handoffNil() {
        let c = UUID()
        let inbox = [msg(c, "only")]
        #expect(HandoffSeed.fold(handoff: nil, inbox: inbox) == StopDrain.renderMessages(inbox))
    }

    @Test("fold: whitespace-only handoff is dropped, leaving the numbered inbox render")
    func handoffBlank() {
        let c = UUID()
        let inbox = [msg(c, "x")]
        #expect(HandoffSeed.fold(handoff: "   \n ", inbox: inbox) == StopDrain.renderMessages(inbox))
    }

    @Test("fold: pure handoff with no inbox gets NO inbox header (header rides only the inbox portion)")
    func handoffOnlyNoHeader() {
        #expect(HandoffSeed.fold(handoff: "HANDOFF", inbox: []) == "HANDOFF")
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
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        let oldId = t.agentSessionId

        // Intent-only: the seed is persisted as `pendingSeed` in the relaunch patch (carried #1 write side).
        let intent = try await env.svc.resume(t.id, seed: "SEEDED-CTX")
        #expect(intent.pendingSeed == "SEEDED-CTX")
        let updated = try await TestEnv.reconcileToLive(env.svc, t.id)

        #expect(updated.waitReason != nil)
        #expect(updated.agentSessionId == oldId)   // resume keeps the id — NOT a fresh restart
        #expect(updated.pendingSeed == nil)         // consumed + cleared on readiness
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--resume"))
        #expect(argv.last == "SEEDED-CTX")          // seed delivered as the opening turn (RelaunchStepper)
    }
}

@Suite("C3 · F1 — OrchestraService.resumeInCard")
struct ResumeInCardTests {

    /// Spawn a dead-but-resumable card with a transcript on disk.
    private func makeResumable(
        _ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
        branch: String) async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: branch))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        return t
    }

    @Test("resumeInCard carries the handoff seed; keeps the session id (resume, not blank restart)")
    func carriesSeedKeepsId() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await makeResumable(env, branch: "b")
        let oldId = t.agentSessionId

        let intent = try await env.svc.resumeInCard(t.id, seed: "HANDOFF")
        #expect(intent.pendingSeed == "HANDOFF")    // folded seed persisted for the RelaunchStepper
        let updated = try await TestEnv.reconcileToLive(env.svc, t.id)

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

        // The inbox is drained + folded at INTENT time (into pendingSeed); the RelaunchStepper delivers it.
        _ = try await env.svc.resumeInCard(t.id, seed: "HANDOFF")
        #expect(await env.svc.drainForStop(t.id) == nil)   // already drained — nothing to double-deliver
        _ = try await TestEnv.reconcileToLive(env.svc, t.id)

        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        let seed = try #require(argv.last)
        #expect(seed.contains("HANDOFF"))
        #expect(seed.contains("queued-1"))
        #expect(seed.contains("queued-2"))
    }

    @Test("test_handoffSeedSurvivesCrash")
    func test_handoffSeedSurvivesCrash() async throws {
        // handoff persists `pendingSeed` (folded HANDOFF + drained inbox) in the SAME patch as `.relaunching`,
        // so a crash before launch keeps it on disk and the re-driven relaunch delivers it.
        let env = TestEnv.make(grace: 30)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        try await env.svc.send(t.id, "queued-1")

        let intent = try await env.svc.resumeInCard(t.id, seed: "HANDOFF")
        #expect(intent.phase.kind == .relaunching)
        let seed = try #require(intent.pendingSeed)
        #expect(seed.contains("HANDOFF"))
        #expect(seed.contains("queued-1"))   // drained inbox folded into the durable seed

        // Crash BEFORE launch: a fresh daemon re-derives from the persisted card + delivers the seed.
        let env2 = TestEnv.remake(base: env.base)
        _ = try await TestEnv.reconcileToLive(env2.svc, t.id)
        let argv = try #require(env2.sessions.ensureArgv[env2.sessions.sessionName(t.id)])
        #expect(argv.last?.contains("HANDOFF") == true)
        #expect(argv.last?.contains("queued-1") == true)
        #expect(try #require(await env2.svc.store.get(t.id)).pendingSeed == nil)   // consumed on readiness

        // A resumeFailed KEEPS the seed (fail-safe): a card whose transcript vanished mid-relaunch stays
        // seeded so a later retry still delivers it.
        let f = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "y", repo: repo, branch: "f"))
        await env.svc.markDead(f.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: f.agentSessionId!)
        _ = try await env.svc.resumeInCard(f.id, seed: "KEEPME")
        env.adapter.deleteTranscript(for: f.agentSessionId!)   // transcript vanishes → RelaunchStepper fails safe
        try await pollUntil {
            await env.svc.reconcile()
            return await env.svc.list(includeArchived: true).first { $0.id == f.id }?.phase.kind == .dead
        }
        let dead = try #require(await env.svc.store.get(f.id))
        #expect(dead.deadReason == .resumeFailed)
        #expect(dead.pendingSeed?.contains("KEEPME") == true)   // seed retained for a later retry
    }

    @Test("resumeInCard with no seed and empty inbox delivers no positional (pure resume)")
    func noSeedNoInbox() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await makeResumable(env, branch: "b")

        _ = try await env.svc.resumeInCard(t.id)
        _ = try await TestEnv.reconcileToLive(env.svc, t.id)

        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--resume"))
        // StubAdapter.resume tail is `--name <title>`; with no seed nothing follows the name value.
        let nameIdx = try #require(argv.firstIndex(of: "--name"))
        #expect(argv.count == nameIdx + 2)
    }
}

@Suite("D1 · handoff Command — dispatches to resumeInCard")
struct HandoffCommandTests {

    /// Spawn a dead-but-resumable card with a transcript on disk (mirrors ResumeInCardTests).
    private func makeResumable(
        _ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
        branch: String) async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: branch))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        return t
    }

    @Test("handoff Command resumes the card with the context seed and keeps the session id")
    func dispatchesToResumeInCard() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await makeResumable(env, branch: "b")
        let oldId = t.agentSessionId
        let cmd = try #require(CommandRegistry().command("handoff"))

        // Intent-only: the command records the relaunch (pendingSeed = folded HANDOFF-CTX) + returns.
        let result = try await cmd.run(
            env.svc,
            .object(["ref": .string(t.id.uuidString), "context": .string("HANDOFF-CTX")]),
            .agent)
        // returns the updated Task (same id — resume, not a blank restart)
        #expect(try result.decode(Task.self).agentSessionId == oldId)
        _ = try await TestEnv.reconcileToLive(env.svc, t.id)
        // the resume argv carried the handoff context as its opening turn
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--resume"))
        #expect(argv.last == "HANDOFF-CTX")
    }
}
