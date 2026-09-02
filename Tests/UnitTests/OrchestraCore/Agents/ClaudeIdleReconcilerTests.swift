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
}

private typealias ReturnType = (
    svc: OrchestraService,
    sessions: StubSessions,
    worktrees: StubWorktrees,
    adapter: StubAdapter,
    trust: TrustLedger,
    base: String
)
