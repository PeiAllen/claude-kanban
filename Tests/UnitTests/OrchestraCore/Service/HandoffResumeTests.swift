import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

// The `HandoffSeed.fold` battery is RETIRED with the function (B3 de-drain): the render behavior it
// pinned now lives in `HandoffSeedComposeTests` (compose is the sole entry point, running INSIDE the
// relaunchSeed claim so the consumed-prefix guarantee covers the final argv bytes).

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

        #expect(updated.turnStatus == .unavailable) // the seed owns launch argv, not a status claim
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
        #expect(intent.pendingSeed == "HANDOFF")    // handoff persisted for the RelaunchStepper's claim
        let updated = try await TestEnv.reconcileToLive(env.svc, t.id)

        #expect(updated.agentSessionId == oldId)   // SAME session id — resume, not restart
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--resume"))          // resume argv, never a fresh `start`
        #expect(argv.last == "HANDOFF")
    }

    @Test("resumeInCard NO LONGER drains — the inbox stays durable and is composed into the seed at claim time")
    func inboxStaysDurableAndComposesIntoSeed() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await makeResumable(env, branch: "b")
        try await env.svc.send(t.id, "queued-1")
        try await env.svc.send(t.id, "queued-2")

        // B3 de-drain: resumeInCard carries ONLY the handoff; the inbox is NOT eaten here.
        _ = try await env.svc.resumeInCard(t.id, seed: "HANDOFF")
        #expect(await env.svc.store.get(t.id)?.pendingSeed == "HANDOFF")
        #expect(await env.svc.inbox.peek(t.id).count == 2)   // inbox untouched by the intent — no drain

        // The RelaunchStepper's relaunchSeed claim composes handoff + inbox into the launch seed.
        _ = try await TestEnv.reconcileToLive(env.svc, t.id)
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        let seed = try #require(argv.last)
        #expect(seed.contains("HANDOFF"))
        #expect(seed.contains("queued-1"))
        #expect(seed.contains("queued-2"))
    }

    @Test("test_handoffSeedSurvivesCrash")
    func test_handoffSeedSurvivesCrash() async throws {
        // B3 de-drain: `pendingSeed` carries ONLY the handoff; the inbox stays DURABLE (no drain), so a crash
        // before launch loses nothing — the re-driven relaunch's claim composes handoff + the still-queued
        // inbox into the seed. (The old fold-into-pendingSeed crash window is gone by REMOVING the drain.)
        let env = TestEnv.make(grace: 30)
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: "b"))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        try await env.svc.send(t.id, "queued-1")

        let intent = try await env.svc.resumeInCard(t.id, seed: "HANDOFF")
        #expect(intent.phase.kind == .relaunching)
        #expect(intent.pendingSeed == "HANDOFF")             // handoff only — no inbox folded in
        #expect(await env.svc.inbox.peek(t.id).count == 1)   // the message stays durable (never drained)

        // Crash BEFORE launch: a fresh daemon re-derives from the persisted card + inbox, claims the seed,
        // and delivers handoff + the still-queued message.
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
        // StubAdapter.resume tail is `--name <title> --model <id>`; with no seed no positional follows it.
        let nameIdx = try #require(argv.firstIndex(of: "--name"))
        #expect(Array(argv[(nameIdx + 2)...]) == ["--model", "m1"])
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
