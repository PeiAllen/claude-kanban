import Testing
@testable import OrchestraCore

@Suite("Agent state reducer")
struct AgentStateReducerTests {
    private let epoch = 4

    private var permission: AgentRequest {
        AgentRequest(id: "permission-1", kind: .permission, prompt: "Allow Bash?")
    }

    @Test("turn start enters running and retires prior-turn detail")
    func turnStarted() {
        var state = AgentState(
            turnStatus: .waiting(),
            activity: .init(text: "old activity"),
            activeRequests: [.init(id: "old-question", kind: .input, prompt: "Old question")]
        )

        let changed = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnStarted),
            to: &state,
            currentSessionEpoch: epoch
        )

        #expect(changed)
        #expect(state == AgentState(turnStatus: .running))
    }

    @Test("a duplicate turn start preserves current-turn detail")
    func duplicateTurnStarted() {
        let original = AgentState(
            turnStatus: .running,
            activity: .init(text: "Running Bash"),
            activeRequests: [permission]
        )
        var state = original

        let changed = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnStarted),
            to: &state,
            currentSessionEpoch: epoch
        )

        #expect(!changed)
        #expect(state == original)
    }

    @Test("turn completion waits, clears activity, and preserves unresolved requests")
    func turnCompleted() {
        var state = AgentState(
            turnStatus: .running,
            activity: .init(text: "Running Bash"),
            activeRequests: [permission]
        )

        let changed = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnCompleted(resume: .init())),
            to: &state,
            currentSessionEpoch: epoch
        )

        #expect(changed)
        #expect(state == AgentState(
            turnStatus: .waiting(.init(resume: .init())),
            activeRequests: [permission]
        ))
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

    @Test("an unmatched completion does not disturb an already-waiting agent")
    func unmatchedCompletion() {
        let original = AgentState(
            turnStatus: .waiting(.init(resume: .init())),
            activeRequests: [.init(id: "question-1", kind: .input, prompt: "Still open")]
        )
        var state = original

        let changed = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnCompleted()),
            to: &state,
            currentSessionEpoch: epoch
        )

        #expect(!changed)
        #expect(state == original)
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

    @Test("request snapshots never change running or waiting")
    func requestsAreOrthogonal() {
        let question = AgentRequest(id: "question-1", kind: .input, prompt: "Choose A or B")
        var running = AgentState(turnStatus: .running)
        var waiting = AgentState(turnStatus: .waiting())

        _ = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .requests([question])),
            to: &running,
            currentSessionEpoch: epoch
        )
        _ = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .requests([question])),
            to: &waiting,
            currentSessionEpoch: epoch
        )

        #expect(running.turnStatus == .running)
        #expect(running.activeRequests == [question])
        #expect(waiting.turnStatus == .waiting())
        #expect(waiting.activeRequests == [question])
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
            activeRequests: [permission]
        )

        let changed = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .observationLost),
            to: &state,
            currentSessionEpoch: epoch
        )

        #expect(changed)
        #expect(state == AgentState(turnStatus: .unavailable))
    }

    @Test("turn reconciliation uses the same field lifecycle as turn edges")
    func turnReconciliation() {
        var state = AgentState(
            turnStatus: .waiting(),
            activity: .init(text: "old activity"),
            activeRequests: [permission]
        )

        _ = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnReconciled(.running)),
            to: &state,
            currentSessionEpoch: epoch
        )
        #expect(state == AgentState(turnStatus: .running))

        state.activity = .init(text: "new activity")
        state.activeRequests = [permission]
        _ = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnReconciled(.waiting())),
            to: &state,
            currentSessionEpoch: epoch
        )
        #expect(state == AgentState(turnStatus: .waiting(), activeRequests: [permission]))

        _ = AgentStateReducer.apply(
            .init(sessionEpoch: epoch, kind: .turnReconciled(.unavailable)),
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
