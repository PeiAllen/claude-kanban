import Testing
@testable import OrchestraCore
import TestSupport

@Suite("Agent observation coordinator")
struct AgentObservationCoordinatorTests {
    private let epoch = 41

    /// `submit` is one-way (see the coordinator's doc comment) — it no longer waits for its own
    /// `apply` to land. `isIdle` is the exact, race-free replacement: it is true only once every queued
    /// submission (including ones enqueued mid-drain) has actually been applied.
    private func waitIdle(_ coordinator: AgentObservationCoordinator) async throws {
        try await pollUntil("coordinator to finish draining") { await coordinator.isIdle }
    }

    @Test("a delayed terminal observation cannot close a newer identified turn")
    func staleCompletionCannotCloseNewerTurn() async throws {
        let coordinator = AgentObservationCoordinator()
        let state = AgentStateBox()
        let scope = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "session-1")

        await coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnStarted)]
        ) { await state.apply($0, epoch: epoch) }
        await coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnCompleted())]
        ) { await state.apply($0, epoch: epoch) }
        await coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "prompt-b", kind: .turnStarted)]
        ) { await state.apply($0, epoch: epoch) }

        await coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnCompleted())]
        ) { await state.apply($0, epoch: epoch) }

        try await waitIdle(coordinator)
        #expect(await state.turnStatus() == .running)
    }

    @Test("only exact activity can reactivate the just-completed prompt")
    func samePromptReactivationIsFenced() async throws {
        let coordinator = AgentObservationCoordinator()
        let state = AgentStateBox()
        let scope = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "session-1")

        for signal in [
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnStarted),
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnCompleted()),
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnActivity),
        ] {
            await coordinator.submit(scope: scope, signals: [signal]) {
                await state.apply($0, epoch: epoch)
            }
        }
        try await waitIdle(coordinator)
        #expect(await state.turnStatus() == .running)

        for signal in [
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnCompleted()),
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-b", kind: .turnStarted),
        ] {
            await coordinator.submit(scope: scope, signals: [signal]) {
                await state.apply($0, epoch: epoch)
            }
        }
        let stale = SubmissionRecorder()
        await coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnActivity)]
        ) { _ in await stale.append("accepted") }
        // Wait for quiescence FIRST, then check absence once: the drain has genuinely finished
        // filtering this submission (rejected as stale, per `accept()`), so an empty recorder here
        // is a fact, not a timing guess (a negative assertion cannot be polled for on its own).
        try await waitIdle(coordinator)
        #expect(await state.turnStatus() == .running)
        #expect(await stale.values().isEmpty)
    }

    @Test("the matching duplicate terminal source can enrich automatic resume")
    func matchingDuplicateCompletionEnrichesResume() async throws {
        let coordinator = AgentObservationCoordinator()
        let state = AgentStateBox()
        let scope = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "session-1")

        for signal in [
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnStarted),
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnCompleted()),
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnCompleted(resume: .init())),
        ] {
            await coordinator.submit(scope: scope, signals: [signal]) {
                await state.apply($0, epoch: epoch)
            }
        }

        try await waitIdle(coordinator)
        #expect(await state.turnStatus() == .waiting(.init(resume: .init())))
    }

    @Test("a terminal observation without a turn identity loses current observation")
    func missingTerminalIdentityLosesObservation() async throws {
        let coordinator = AgentObservationCoordinator()
        let state = AgentStateBox()
        let scope = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "session-1")

        await coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "prompt-b", kind: .turnStarted)]
        ) { await state.apply($0, epoch: epoch) }
        await coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, kind: .turnCompleted())]
        ) { await state.apply($0, epoch: epoch) }

        try await waitIdle(coordinator)
        #expect(await state.turnStatus() == .unavailable)
    }

    @Test("a terminal for no provable current turn fails closed")
    func orphanTerminalFailsClosed() async throws {
        let coordinator = AgentObservationCoordinator()
        let state = AgentStateBox()
        let scope = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "session-1")

        await coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "orphan-prompt", kind: .turnCompleted())]
        ) { await state.apply($0, epoch: epoch) }

        try await waitIdle(coordinator)
        #expect(await state.turnStatus() == .unavailable)
    }

    @Test("an identified terminal after an uncorrelated running snapshot fails closed")
    func terminalAfterUncorrelatedRunningSnapshotLosesObservation() async throws {
        let coordinator = AgentObservationCoordinator()
        let state = AgentStateBox()
        let scope = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "session-1")

        await coordinator.submit(
            scope: scope,
            signals: [.init(
                sessionEpoch: epoch,
                kind: .turnReconciled(.running, humanNeed: nil)
            )]
        ) { await state.apply($0, epoch: epoch) }
        await coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "unproven-turn", kind: .turnCompleted())]
        ) { await state.apply($0, epoch: epoch) }

        try await waitIdle(coordinator)
        #expect(await state.turnStatus() == .unavailable)
    }

    @Test("a running snapshot preserves an identified active-turn fence")
    func runningSnapshotPreservesActiveTurnFence() async throws {
        let coordinator = AgentObservationCoordinator()
        let state = AgentStateBox()
        let scope = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "session-1")

        for signal in [
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnStarted),
            AgentSignal(sessionEpoch: epoch, kind: .turnReconciled(.running, humanNeed: nil)),
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnCompleted()),
        ] {
            await coordinator.submit(scope: scope, signals: [signal]) {
                await state.apply($0, epoch: epoch)
            }
        }

        try await waitIdle(coordinator)
        #expect(await state.turnStatus() == .waiting())
    }

    @Test("a terminal snapshot preserves the matching completion fence")
    func terminalSnapshotPreservesCompletionFence() async throws {
        let coordinator = AgentObservationCoordinator()
        let state = AgentStateBox()
        let scope = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "session-1")

        for signal in [
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnStarted),
            AgentSignal(sessionEpoch: epoch, kind: .turnReconciled(.waiting(), humanNeed: nil)),
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnCompleted()),
        ] {
            await coordinator.submit(scope: scope, signals: [signal]) {
                await state.apply($0, epoch: epoch)
            }
        }

        try await waitIdle(coordinator)
        #expect(await state.turnStatus() == .waiting())
    }

    @Test("a distinct turn start clears the prior turn detail while a duplicate is ignored")
    func distinctStartIsSemanticBoundary() async throws {
        let coordinator = AgentObservationCoordinator()
        let state = AgentStateBox()
        let scope = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "session-1")

        for signal in [
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnStarted),
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .activity(.init(text: "old tool"))),
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-a", kind: .humanNeedChanged(.permission)),
            AgentSignal(sessionEpoch: epoch, turnID: "prompt-b", kind: .turnStarted),
        ] {
            await coordinator.submit(scope: scope, signals: [signal]) {
                await state.apply($0, epoch: epoch)
            }
        }
        try await waitIdle(coordinator)
        #expect(await state.snapshot() == AgentState(turnStatus: .running))

        let current = AgentState(
            turnStatus: .running,
            activity: .init(text: "current tool"),
            humanNeed: .input
        )
        await state.replace(current)
        await coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "prompt-b", kind: .turnStarted)]
        ) { await state.apply($0, epoch: epoch) }

        try await waitIdle(coordinator)
        #expect(await state.snapshot() == current)
    }

    @Test("a suspended apply prevents a later source from overtaking it")
    func submissionsAreSerializedAcrossSuspension() async throws {
        let coordinator = AgentObservationCoordinator()
        let scope = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "session-1")
        let gate = Gate()
        let recorder = SubmissionRecorder()

        await coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnStarted)]
        ) { _ in
            _ = await gate.park()
            await recorder.append("first")
        }
        await gate.reached()

        await coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "prompt-b", kind: .turnStarted)]
        ) { _ in
            await recorder.append("second")
        }
        // The drain is still parked inside the first apply's gate, so the second submission — already
        // enqueued — cannot have been applied yet: `isIdle` is false until every queued apply has run,
        // an exact proxy (not a timing guess) for "second has not landed".
        #expect(await !coordinator.isIdle)
        #expect(await recorder.values().isEmpty)

        gate.release()
        try await waitIdle(coordinator)
        #expect(await recorder.values() == ["first", "second"])
    }
}

private actor AgentStateBox {
    private var state = AgentState(turnStatus: .unavailable)

    func apply(_ signals: [AgentSignal], epoch: Int) {
        for signal in signals {
            _ = AgentStateReducer.apply(signal, to: &state, currentSessionEpoch: epoch)
        }
    }

    func turnStatus() -> TurnStatus { state.turnStatus }
    func snapshot() -> AgentState { state }
    func replace(_ replacement: AgentState) { state = replacement }
}

private actor SubmissionRecorder {
    private var items: [String] = []

    func append(_ item: String) { items.append(item) }
    func values() -> [String] { items }
}
