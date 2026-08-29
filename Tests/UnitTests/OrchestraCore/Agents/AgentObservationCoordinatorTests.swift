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
}

private actor SubmissionRecorder {
    private var items: [String] = []

    func append(_ item: String) { items.append(item) }
    func values() -> [String] { items }
}
