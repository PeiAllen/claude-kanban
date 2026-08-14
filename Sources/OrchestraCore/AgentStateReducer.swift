import OrchestraKit

/// Identity captured by the provider observation source. `sessionEpoch` is the launch generation that
/// produced the raw event (for hooks, the session's `ORCH_EPOCH`; for a live observer, the epoch it was
/// armed under), not a fresh read of the card when the event happens to arrive. `harnessSessionId` is the
/// provider-native conversation identity used to reject cross-session events; Codex calls it `threadId`.
public struct AgentSignalContext: Equatable, Sendable {
    public var sessionEpoch: Int
    public var harnessSessionId: String?

    public init(sessionEpoch: Int, harnessSessionId: String? = nil) {
        self.sessionEpoch = sessionEpoch
        self.harnessSessionId = harnessSessionId
    }
}

/// One provider-normalized observation, fenced to the card session incarnation that produced it.
public struct AgentSignal: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case turnStarted
        case turnCompleted(resume: AutomaticResume? = nil)
        case turnReconciled(TurnStatus)
        case activity(ActivitySummary?)
        case requests([AgentRequest])
        case observationLost
    }

    public var sessionEpoch: Int
    public var kind: Kind

    public init(sessionEpoch: Int, kind: Kind) {
        self.sessionEpoch = sessionEpoch
        self.kind = kind
    }
}

/// The single provider-neutral fold for live agent state. Lifecycle decides when an `AgentState` exists;
/// this reducer only applies current-epoch observations to that state.
public enum AgentStateReducer {
    @discardableResult
    public static func apply(
        _ signal: AgentSignal,
        to state: inout AgentState,
        currentSessionEpoch: Int
    ) -> Bool {
        guard signal.sessionEpoch == currentSessionEpoch else { return false }

        let before = state
        switch signal.kind {
        case .turnStarted:
            // A second start while already running is a duplicate observation of the same open turn. It
            // must not erase activity or requests accumulated after the first start.
            if state.turnStatus != .running {
                state = AgentState(turnStatus: .running)
            }

        case .turnCompleted(let resume):
            // Providers can emit terminal spans for built-in commands that had no normalized turn start
            // (for example Claude `/exit`). A nil duplicate is therefore a no-op. A second source may,
            // however, know that the just-closed turn will resume automatically (Claude Stop vs its root
            // interaction span), so allow that one monotonic enrichment regardless of arrival order.
            if case .waiting(let waiting) = state.turnStatus {
                guard waiting.resume == nil, let resume else { return false }
                state.turnStatus = .waiting(.init(resume: resume))
                break
            }
            state.turnStatus = .waiting(.init(resume: resume))
            state.activity = nil

        case .turnReconciled(let status):
            applyTurnStatus(status, to: &state)

        case .activity(let activity):
            state.activity = activity

        case .requests(let requests):
            state.activeRequests = requests

        case .observationLost:
            state = AgentState(turnStatus: .unavailable)
        }

        return state != before
    }

    private static func applyTurnStatus(_ status: TurnStatus, to state: inout AgentState) {
        switch status {
        case .running:
            if state.turnStatus != .running {
                state = AgentState(turnStatus: .running)
            }
        case .waiting:
            state.turnStatus = status
            state.activity = nil
        case .unavailable:
            state = AgentState(turnStatus: .unavailable)
        }
    }
}
