import Testing
@testable import OrchestraCore

@Suite("Agent state reducer")
struct AgentStateReducerTests {
    private let epoch = 4

    @Test("an accepted distinct turn start resets old detail even while remaining running")
    func turnStartedResetsRunningDetail() {
        var state = AgentState(
            turnStatus: .running,
            activity: .init(text: "old activity"),
            humanNeed: .permission
        )

        let changed = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnStarted),
            to: &state,
            currentSessionEpoch: epoch
        )

        #expect(changed)
        #expect(state == AgentState(turnStatus: .running))
    }

    @Test("turn completion waits and clears provider detail")
    func turnCompleted() {
        var state = AgentState(
            turnStatus: .running,
            activity: .init(text: "Running Bash"),
            humanNeed: .permission
        )

        let changed = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnCompleted(resume: .init())),
            to: &state,
            currentSessionEpoch: epoch
        )

        #expect(changed)
        #expect(state == AgentState(turnStatus: .waiting(.init(resume: .init()))))
    }

    @Test("a terminal event recovers unavailable observation to waiting")
    func terminalEventRecoversUnavailable() {
        var state = AgentState(turnStatus: .unavailable)

        let changed = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnCompleted()),
            to: &state,
            currentSessionEpoch: epoch
        )

        #expect(changed)
        #expect(state == AgentState(turnStatus: .waiting()))
    }

    @Test("an accepted terminal clears stale human need from an already-waiting agent")
    func terminalClearsWaitingHumanNeed() {
        var state = AgentState(
            turnStatus: .waiting(.init(resume: .init())),
            humanNeed: .input
        )

        let changed = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnCompleted()),
            to: &state,
            currentSessionEpoch: epoch
        )

        #expect(changed)
        #expect(state == AgentState(turnStatus: .waiting(.init(resume: .init()))))
    }

    @Test("a duplicate completion may enrich waiting with automatic resume")
    func duplicateCompletionEnrichesResume() {
        var state = AgentState(turnStatus: .waiting())

        let changed = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnCompleted(resume: .init())),
            to: &state,
            currentSessionEpoch: epoch
        )

        #expect(changed)
        #expect(state == AgentState(turnStatus: .waiting(.init(resume: .init()))))
    }

    @Test("human-need changes never change turn status")
    func humanNeedIsOrthogonal() {
        var running = AgentState(turnStatus: .running)
        var waiting = AgentState(turnStatus: .waiting())

        _ = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .humanNeedChanged(.permission)),
            to: &running,
            currentSessionEpoch: epoch
        )
        _ = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .humanNeedChanged(.input)),
            to: &waiting,
            currentSessionEpoch: epoch
        )

        #expect(running.turnStatus == .running)
        #expect(running.humanNeed == .permission)
        #expect(waiting.turnStatus == .waiting())
        #expect(waiting.humanNeed == .input)
    }

    @Test("activity snapshots never change turn status")
    func activityIsOrthogonal() {
        var state = AgentState(turnStatus: .waiting())

        let changed = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .activity(.init(text: "Background indexing"))),
            to: &state,
            currentSessionEpoch: epoch
        )

        #expect(changed)
        #expect(state.turnStatus == .waiting())
        #expect(state.activity == ActivitySummary(text: "Background indexing"))
    }

    @Test("observation loss becomes unavailable and clears untrusted detail")
    func observationLost() {
        var state = AgentState(
            turnStatus: .running,
            activity: .init(text: "Running Bash"),
            humanNeed: .permission
        )

        let changed = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .observationLost),
            to: &state,
            currentSessionEpoch: epoch
        )

        #expect(changed)
        #expect(state == AgentState(turnStatus: .unavailable))
    }

    @Test("turn reconciliation atomically replaces turn and human-need facts")
    func turnReconciliation() {
        var state = AgentState(
            turnStatus: .waiting(),
            activity: .init(text: "old activity"),
            humanNeed: .input
        )

        _ = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnReconciled(.running, humanNeed: .permission)),
            to: &state,
            currentSessionEpoch: epoch
        )
        #expect(state == AgentState(turnStatus: .running, humanNeed: .permission))

        state.activity = .init(text: "new activity")
        state.humanNeed = .permission
        _ = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnReconciled(.waiting(), humanNeed: nil)),
            to: &state,
            currentSessionEpoch: epoch
        )
        #expect(state == AgentState(turnStatus: .waiting()))

        _ = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnReconciled(.unavailable, humanNeed: nil)),
            to: &state,
            currentSessionEpoch: epoch
        )
        #expect(state == AgentState(turnStatus: .unavailable))
    }

    @Test("stale session signals are no-ops")
    func staleEpoch() {
        let original = AgentState(turnStatus: .waiting(), activity: .init(text: "idle"))
        var state = original

        let changed = AgentStateReducer.apply(
            .init(sessionEpoch: epoch - 1, kind: .turnStarted),
            to: &state,
            currentSessionEpoch: epoch
        )

        #expect(!changed)
        #expect(state == original)
    }
}
