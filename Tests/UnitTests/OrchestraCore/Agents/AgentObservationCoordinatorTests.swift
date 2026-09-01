import Testing
@testable import OrchestraCore
import TestSupport

@Suite("Agent observation coordinator")
struct AgentObservationCoordinatorTests {
    private let epoch = 41

    @Test("a delayed terminal observation cannot close a newer identified turn")
    func staleCompletionCannotCloseNewerTurn() async {
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

        #expect(await state.turnStatus() == .running)
    }

    @Test("only exact activity can reactivate the just-completed prompt")
    func samePromptReactivationIsFenced() async {
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
        #expect(await state.turnStatus() == .running)
        #expect(await stale.values().isEmpty)
    }

    @Test("the matching duplicate terminal source can enrich automatic resume")
    func matchingDuplicateCompletionEnrichesResume() async {
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

        #expect(await state.turnStatus() == .waiting(.init(resume: .init())))
    }

    @Test("a terminal observation without a turn identity loses current observation")
    func missingTerminalIdentityLosesObservation() async {
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

        #expect(await state.turnStatus() == .unavailable)
    }

    @Test("a terminal for no provable current turn fails closed")
    func orphanTerminalFailsClosed() async {
        let coordinator = AgentObservationCoordinator()
        let state = AgentStateBox()
        let scope = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "session-1")

        await coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "orphan-prompt", kind: .turnCompleted())]
        ) { await state.apply($0, epoch: epoch) }

        #expect(await state.turnStatus() == .unavailable)
    }

    @Test("an identified terminal after an uncorrelated running snapshot fails closed")
    func terminalAfterUncorrelatedRunningSnapshotLosesObservation() async {
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

        #expect(await state.turnStatus() == .unavailable)
    }

    @Test("a running snapshot preserves an identified active-turn fence")
    func runningSnapshotPreservesActiveTurnFence() async {
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

        #expect(await state.turnStatus() == .waiting())
    }

    @Test("a terminal snapshot preserves the matching completion fence")
    func terminalSnapshotPreservesCompletionFence() async {
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

        #expect(await state.turnStatus() == .waiting())
    }

    @Test("a distinct turn start clears the prior turn detail while a duplicate is ignored")
    func distinctStartIsSemanticBoundary() async {
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

        #expect(await state.snapshot() == current)
    }

    @Test("a suspended apply prevents a later source from overtaking it")
    func submissionsAreSerializedAcrossSuspension() async {
        let coordinator = AgentObservationCoordinator()
        let scope = AgentSignalContext(sessionEpoch: epoch, harnessSessionId: "session-1")
        let gate = Gate()
        let recorder = SubmissionRecorder()

        async let first: Void = coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "prompt-a", kind: .turnStarted)]
        ) { _ in
            _ = await gate.park()
            await recorder.append("first")
        }
        await gate.reached()

        async let second: Void = coordinator.submit(
            scope: scope,
            signals: [.init(sessionEpoch: epoch, turnID: "prompt-b", kind: .turnStarted)]
        ) { _ in
            await recorder.append("second")
        }
        await yieldBriefly()
        #expect(await recorder.values().isEmpty)

        gate.release()
        await first
        await second
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
