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
        /// Provider activity carrying an exact turn identity. The coordinator classifies it as
        /// current-turn noise, a same-turn continuation, or a distinct turn start.
        case turnActivity
        case turnCompleted(resume: AutomaticResume? = nil)
        case turnReconciled(TurnStatus, humanNeed: ProviderHumanNeed?)
        case activity(ActivitySummary?)
        case humanNeedChanged(ProviderHumanNeed?)
        case observationLost
    }

    public var sessionEpoch: Int
    /// Provider-native identity for the turn/prompt this observation describes. This is an
    /// in-memory correlation fence, not durable agent state.
    public var turnID: String?
    public var kind: Kind

    public init(sessionEpoch: Int, turnID: String? = nil, kind: Kind) {
        self.sessionEpoch = sessionEpoch
        self.turnID = turnID
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
            // The coordinator admits only a distinct provider turn here. Treat it as a semantic
            // boundary even when the visible status was already running.
            state = AgentState(turnStatus: .running)

        case .turnActivity:
            // The coordinator only leaves this kind intact for a same-turn continuation, so preserve
            // its detail and human-needed facts. It is not the semantic boundary that retires a
            // durable pendingQuestion.
            state.turnStatus = .running

        case .turnCompleted(let resume):
            // Providers can emit terminal spans for built-in commands that had no normalized turn start
            // (for example Claude `/exit`). A nil duplicate is therefore a no-op. A second source may,
            // however, know that the just-closed turn will resume automatically, so allow that one
            // monotonic enrichment regardless of arrival order.
            if case .waiting(let waiting) = state.turnStatus {
                if waiting.resume == nil, let resume {
                    state.turnStatus = .waiting(.init(resume: resume))
                }
            } else {
                state.turnStatus = .waiting(.init(resume: resume))
            }
            state.activity = nil
            state.humanNeed = nil

        case .turnReconciled(let status, let humanNeed):
            applyTurnSnapshot(status, humanNeed: humanNeed, to: &state)

        case .activity(let activity):
            state.activity = activity

        case .humanNeedChanged(let humanNeed):
            state.humanNeed = humanNeed

        case .observationLost:
            state = AgentState(turnStatus: .unavailable)
        }

        return state != before
    }

    private static func applyTurnSnapshot(
        _ status: TurnStatus,
        humanNeed: ProviderHumanNeed?,
        to state: inout AgentState
    ) {
        switch status {
        case .running:
            if state.turnStatus != .running {
                state = AgentState(turnStatus: .running)
            }
            state.humanNeed = humanNeed
        case .waiting:
            state.turnStatus = status
            state.activity = nil
            state.humanNeed = humanNeed
        case .unavailable:
            state = AgentState(turnStatus: .unavailable)
        }
    }
}
