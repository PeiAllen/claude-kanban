import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

@Suite("Claude idle reconciliation")
struct ClaudeIdleReconcilerTests {
    private func runningCard(_ env: ReturnType, promptID: String = "prompt-a") async throws -> Task {
        let spawned = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(env.base), branch: "idle-probe")
        )
        let card = try #require(await env.svc.store.get(spawned.id))
        await env.svc.receiveAgentSignals(
            cardId: card.id,
            signals: [.init(sessionEpoch: card.sessionEpoch, turnID: promptID, kind: .turnStarted)]
        )
        try await env.svc.waitForObservationQueueIdle(card.id)
        return try #require(await env.svc.store.get(card.id))
    }

    @Test("an exact idle snapshot repairs a hook-silent running turn")
    func idleRepairsRunning() async throws {
        let proc = FakeProc()
        let env = TestEnv.make(proc: proc)
        let card = try await runningCard(env)
        let sessionID = try #require(card.agentSessionId)
        proc.on([env.adapter.bin, "agents", "--json"]) { _ in
            .init(
                stdout: #"[{"sessionId":"\#(sessionID)","status":"idle"}]"#,
                stderr: "",
                exitCode: 0
            )
        }

        await env.svc.reconcileClaudeIdle()
        try await env.svc.waitForObservationQueueIdle(card.id)

        #expect(await env.svc.store.get(card.id)?.turnStatus == .waiting())
    }

    @Test("a newer turn fences a stale idle snapshot and concurrent polls coalesce")
    func generationFenceAndSingleFlight() async throws {
        let proc = FakeProc()
        let gate = proc.gate(on: ["fake-agent", "agents", "--json"])
        let env = TestEnv.make(proc: proc)
        let card = try await runningCard(env)
        let sessionID = try #require(card.agentSessionId)

        async let first: Void = env.svc.reconcileClaudeIdle()
        await gate.reached()
        async let overlapping: Void = env.svc.reconcileClaudeIdle()
        await overlapping
        #expect(proc.calls.filter { $0.argv == [env.adapter.bin, "agents", "--json"] }.count == 1)

        await env.svc.receiveAgentSignals(
            cardId: card.id,
            signals: [.init(sessionEpoch: card.sessionEpoch, turnID: "prompt-b", kind: .turnStarted)]
        )
        gate.release(.init(
            stdout: #"[{"sessionId":"\#(sessionID)","status":"idle"}]"#,
            stderr: "",
            exitCode: 0
        ))
        await first

        #expect(await env.svc.store.get(card.id)?.turnStatus == .running)
    }

    @Test("human-blocked and non-running cards do not invoke the snapshot")
    func ineligibleCardsDoNotPoll() async throws {
        let proc = FakeProc()
        let env = TestEnv.make(proc: proc)
        let card = try await runningCard(env)
        await env.svc.receiveAgentSignals(
            cardId: card.id,
            signals: [.init(
                sessionEpoch: card.sessionEpoch,
                turnID: "prompt-a",
                kind: .humanNeedChanged(.permission)
            )]
        )
        try await env.svc.waitForObservationQueueIdle(card.id)

        await env.svc.reconcileClaudeIdle()

        #expect(proc.calls.allSatisfy { $0.argv != [env.adapter.bin, "agents", "--json"] })
        #expect(await env.svc.store.get(card.id)?.turnStatus == .running)
        #expect(await env.svc.store.get(card.id)?.agentState?.humanNeed == .permission)
    }

    // MARK: - Snapshot-on-bind: healing a card left `.unavailable` by a daemon restart

    /// A fresh live card defaults to `.unavailable` (provider state unknown) — exactly the shape a
    /// daemon-restart adoption leaves a card in, without needing a real restart to produce it.
    private func unavailableCard(_ env: ReturnType) async throws -> Task {
        let spawned = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "Task", repo: TestEnv.repo(env.base), branch: "idle-probe-unavailable")
        )
        let card = try #require(await env.svc.store.get(spawned.id))
        #expect(card.turnStatus == .unavailable)
        return card
    }

    @Test("an unavailable card whose session reports idle heals to waiting")
    func unavailableHealsOnIdleSnapshot() async throws {
        let proc = FakeProc()
        let env = TestEnv.make(proc: proc)
        let card = try await unavailableCard(env)
        let sessionID = try #require(card.agentSessionId)
        proc.on([env.adapter.bin, "agents", "--json"]) { _ in
            .init(stdout: #"[{"sessionId":"\#(sessionID)","status":"idle"}]"#, stderr: "", exitCode: 0)
        }

        await env.svc.reconcileClaudeIdle()
        try await env.svc.waitForObservationQueueIdle(card.id)

        #expect(await env.svc.store.get(card.id)?.turnStatus == .waiting())
    }

    @Test("an unavailable card whose session reports busy stays unavailable (no flicker promotion)")
    func unavailableStaysOnBusySnapshot() async throws {
        // Pins the anti-symmetry: promoting on `busy` would leave no correlated turn id, so the
        // eventual Stop hook falls through to `observationLost` and flickers the card straight back.
        let proc = FakeProc()
        let env = TestEnv.make(proc: proc)
        let card = try await unavailableCard(env)
        let sessionID = try #require(card.agentSessionId)
        proc.on([env.adapter.bin, "agents", "--json"]) { _ in
            .init(stdout: #"[{"sessionId":"\#(sessionID)","status":"busy"}]"#, stderr: "", exitCode: 0)
        }

        await env.svc.reconcileClaudeIdle()
        try await env.svc.waitForObservationQueueIdle(card.id)

        // Proves this reached the busy path (a live subprocess call), not just "no candidate at all".
        #expect(proc.calls.contains { $0.argv == [env.adapter.bin, "agents", "--json"] })
        #expect(await env.svc.store.get(card.id)?.turnStatus == .unavailable)
    }

    @Test("an unavailable card whose session is absent from the snapshot stays unavailable")
    func unavailableStaysWhenSessionAbsent() async throws {
        let proc = FakeProc()
        let env = TestEnv.make(proc: proc)
        let card = try await unavailableCard(env)
        proc.on([env.adapter.bin, "agents", "--json"]) { _ in
            .init(stdout: "[]", stderr: "", exitCode: 0)
        }

        await env.svc.reconcileClaudeIdle()
        try await env.svc.waitForObservationQueueIdle(card.id)

        // Proves this reached the absent-from-snapshot path, not just "no candidate at all".
        #expect(proc.calls.contains { $0.argv == [env.adapter.bin, "agents", "--json"] })
        #expect(await env.svc.store.get(card.id)?.turnStatus == .unavailable)
    }

    @Test("a turn starting mid-subprocess fences a stale idle snapshot for a healing unavailable card")
    func generationFenceProtectsUnavailableCandidate() async throws {
        let proc = FakeProc()
        let gate = proc.gate(on: ["fake-agent", "agents", "--json"])
        let env = TestEnv.make(proc: proc)
        let card = try await unavailableCard(env)
        let sessionID = try #require(card.agentSessionId)

        async let reconcile: Void = env.svc.reconcileClaudeIdle()
        await gate.reached()
        // A real turn starts WHILE the subprocess is in flight — the fence must win over the stale
        // snapshot, so the recheck's generation compare must skip the write.
        await env.svc.receiveAgentSignals(
            cardId: card.id,
            signals: [.init(sessionEpoch: card.sessionEpoch, turnID: "prompt-mid-flight", kind: .turnStarted)]
        )
        gate.release(.init(
            stdout: #"[{"sessionId":"\#(sessionID)","status":"idle"}]"#, stderr: "", exitCode: 0
        ))
        await reconcile
        try await env.svc.waitForObservationQueueIdle(card.id)

        #expect(await env.svc.store.get(card.id)?.turnStatus == .running)
    }

    @Test("the configured Claude-idle first-tick delay stays shorter than the steady-state cadence")
    func firstTickDelayStaysShorterThanSteadyStateCadence() async throws {
        // Pins the INVARIANT main.swift's loop relies on (delay once, then the full interval forever),
        // asserted on the configured values rather than by sleeping either duration. It does not exercise
        // main.swift's own sequencing — that executable has no unit-test target, and its loop is as thin
        // as the neighboring (also untested) `reconcile()` poll loop it sits beside — so a regression in
        // the LOOP ITSELF (e.g. reusing the short delay on every tick) would not be caught here.
        let env = TestEnv.make()
        #expect(env.svc.claudeIdleFirstPollDelay > 0)
        #expect(env.svc.claudeIdleFirstPollDelay < env.svc.claudeIdlePollInterval)
    }
}

private typealias ReturnType = (
    svc: OrchestraService,
    sessions: StubSessions,
    worktrees: StubWorktrees,
    adapter: StubAdapter,
    trust: TrustLedger,
    base: String
)
