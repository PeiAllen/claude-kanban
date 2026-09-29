import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

/// Regression coverage for the `AgentObservationCoordinator` self-deadlock: `submit()` used to block
/// the caller on a `CheckedContinuation` that only `drain()` resumed, and the `apply` closure it awaited
/// re-entered the same actor's `submit()` (via `transition()` -> `reconcileAgentObservation` ->
/// `submitAgentSignals`) whenever a card's observation identity was rebuilt mid-drain — boot adoption of
/// a still-running card, or a session-id rollover. Both scenarios below deadlock on the pre-fix
/// coordinator and must complete promptly on the fixed one.
///
/// Uses a small local push-only adapter rather than `StubAdapter`, so this file's result is never
/// entangled with `StubAdapter`'s own (separately verified) `observationEndpoint` change.
@Suite("Agent observation coordinator — one-way submit")
struct AgentObservationOneWaySubmitTests {
    @Test("a session-id rollover while running does not deadlock the observation queue")
    func sessionRolloverDoesNotDeadlock() async throws {
        let env = TestEnv.make(registry: AgentRegistry(adapters: [PushOnlyTestAdapter()]))
        let repo = TestEnv.repo(env.base)
        let card = try await TestEnv.spawnAndAwaitLive(
            env.svc,
            SpawnInput(id: UUID(), prompt: "work", repo: repo, branch: "rollover-deadlock",
                      agentId: PushOnlyTestAdapter.staticId)
        )
        try await env.svc.testSetTurnStatus(card.id, .running)
        #expect(await env.svc.store.get(card.id)?.turnStatus == .running)

        let epoch = card.sessionEpoch
        let reportReturned = DeadlockFlag()
        // Unstructured, not `withDeadline`: a `withTaskGroup`-based deadline implicitly awaits every
        // child at scope exit, and a task parked on the pre-fix coordinator's `CheckedContinuation`
        // never observes cancellation — the deadline itself would hang waiting for it.
        _Concurrency.Task {
            try? await env.svc.report(
                card.id, StatusReport(sessionId: "replacement-session-id"), observedEpoch: epoch)
            await reportReturned.set()
        }
        // The PRIMARY regression signal is "did `report()` return at all": on the pre-fix coordinator,
        // its call into `invalidateAgentObservation` never returns (the drain task that would resume
        // its continuation is itself stuck awaiting the nested rebind submit). Polling durable state
        // ALONE is not enough to catch that — `transition()` commits `store.update` to `.unavailable`
        // BEFORE it calls the `reconcileAgentObservation` that triggers the nested hang, so a
        // state-only poll would read `.unavailable` and pass even on the deadlocking coordinator
        // (confirmed by temporarily reverting the fix and rerunning this test: false green in 0.07s).
        try await pollUntil(
            "report() to return without wedging the observation queue", timeout: .seconds(10)
        ) {
            await reportReturned.isSet
        }
        // Secondary correctness check: `report()` returning only proves no deadlock, since submit is
        // one-way — the queued signal converges asynchronously after.
        try await pollUntil("session rollover to converge to unavailable") {
            await env.svc.store.get(card.id)?.turnStatus == .unavailable
        }
    }

    @Test("boot adoption of a still-running card does not wedge the rest of that boot pass")
    func bootAdoptionOfRunningCardDoesNotBlockOthers() async throws {
        let original = TestEnv.make(registry: AgentRegistry(adapters: [PushOnlyTestAdapter()]))
        let repo = TestEnv.repo(original.base)
        let a = try await TestEnv.spawnAndAwaitLive(
            original.svc,
            SpawnInput(id: UUID(), prompt: "a", repo: repo, branch: "boot-a", agentId: PushOnlyTestAdapter.staticId)
        )
        let b = try await TestEnv.spawnAndAwaitLive(
            original.svc,
            SpawnInput(id: UUID(), prompt: "b", repo: repo, branch: "boot-b", agentId: PushOnlyTestAdapter.staticId)
        )
        // Both land on a non-`.unavailable` status BEFORE the simulated restart: this is what routes
        // boot adoption through `invalidateAgentObservation` (submits before any identity is recorded)
        // instead of the safe `reconcileAgentObservation` branch (OrchestraService+Reconcile.swift).
        try await original.svc.testSetTurnStatus(a.id, .running)
        try await original.svc.testSetTurnStatus(b.id, .running)
        let aEpoch = try #require(await original.svc.store.get(a.id)).sessionEpoch
        let bEpoch = try #require(await original.svc.store.get(b.id)).sessionEpoch

        // A fresh service over the same on-disk store, with an EMPTY in-memory runtime — simulates a
        // daemon restart, so `agentObservationIdentity` is nil for both cards going in.
        let restarted = TestEnv.remake(
            base: original.base, registry: AgentRegistry(adapters: [PushOnlyTestAdapter()]))
        restarted.sessions.setStampedEpoch(a.id, aEpoch)
        restarted.sessions.setStampedEpoch(b.id, bEpoch)

        let done = DeadlockFlag()
        _Concurrency.Task {
            await restarted.svc.reconcilePhasesAtBoot()
            await done.set()
        }
        // The pre-fix boot loop awaits the wedged card's `invalidateAgentObservation` INSIDE its
        // `for t in tasks` loop, so a hang on card A also starves card B's adoption, not only A's.
        try await pollUntil(
            "boot reconciliation to finish without wedging on a still-running card", timeout: .seconds(10)
        ) {
            await done.isSet
        }
        #expect(await restarted.svc.store.get(a.id)?.phase.kind == .live)
        #expect(await restarted.svc.store.get(b.id)?.phase.kind == .live)
    }
}

/// Claude-shaped on the one axis this file needs: an unconditional push-only observation endpoint,
/// exactly like `ClaudeCodeAdapter`. Deliberately NOT `StubAdapter` — see the file doc comment.
private struct PushOnlyTestAdapter: Adapter {
    static let staticId = "push-only-test-agent"
    let id = PushOnlyTestAdapter.staticId
    let name = "Push-only test agent"
    let icon = "bolt"
    let bin = "fake-push-only-agent"
    let enabled = true
    let capabilities = AgentCapabilities.stub

    func catalog() -> [AgentModel] { [AgentModel(id: "m1")] }
    func newSessionId() -> String? { UUID().uuidString.lowercased() }
    func start(_ ctx: AdapterContext) -> [String] { [bin] }
    func resume(_ ctx: AdapterContext) -> [String]? { nil }
    func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
        AgentSessionInfo(agentId: id, sessionId: current, transcriptPath: nil,
                         priorSessionIds: prior, priorTranscripts: [], resumeCmd: nil)
    }
    func observationEndpoint(_ setup: AgentObservationSetup) -> AgentObservationEndpoint? { .pushed }
}

private actor DeadlockFlag {
    private var flag = false
    func set() { flag = true }
    var isSet: Bool { flag }
}
