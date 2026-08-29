import Foundation

extension OrchestraService {
    /// The agent-agnostic SessionStart orientation for a card — which column it's in, whether it's
    /// read-only, and its own id — so an agent knows where it was opened and starts on that footing
    /// without being told (the open-time counterpart to `payloadForStop`). Read **live** so a reopened or
    /// dragged card reflects its CURRENT lane, not the launch-time `startIn`. `nil` if the card is gone.
    public func sessionBrief(_ cardId: UUID) async -> String? {
        guard let task = await store.get(cardId) else { return nil }
        return SessionBrief.sentence(column: task.column, access: task.access, shortId: task.shortId,
                                     origin: task.origin, titlePinned: task.titleSource == .explicit)
    }

    /// The core-owned hook-channel dispatch — the single place both directions of the hook channel meet,
    /// and it is ADAPTER-FREE (dispatch keys on `HookEvent`, never on agent identity). The `_report` edge
    /// has already split the raw payload into metadata and a compact adapter-owned status observation.
    /// This applies both, then composes the existing `sessionBrief`/`payloadForStop` content into a neutral
    /// `HookResponse` for the adapter to encode. `nil` on unknown ref or when there is nothing to send back.
    public func handleHook(_ ref: String, event: HookEvent,
                           report: StatusReport?, source: SessionSource?,
                           observedEpoch: Int? = nil, stopHookActive: Bool = false,
                           observationPayload: JSONValue? = nil,
                           messageEndpoint: AgentMessageEndpointReport? = nil) async -> HookResponse? {
        guard let task = try? await resolveRef(ref) else { return nil }

        // Validate the ephemeral endpoint against the PRE-REPORT card. A stale status-line can carry a
        // different harness id in the same launch epoch; report() may observe that metadata, but it must not
        // authorize the same stale callback to replace the current sender. SessionStart may establish a
        // genuinely new provider id (for example Claude `/clear`), but never one already recorded as prior.
        let acceptedMessageEndpoint: AgentMessageEndpointReport?
        let sessionMatchesCurrent: Bool
        if let messageEndpoint {
            sessionMatchesCurrent = task.agentSessionId == messageEndpoint.harnessSessionId
                || (event == .sessionStart
                    && !task.priorSessionIds.contains(messageEndpoint.harnessSessionId))
        } else {
            sessionMatchesCurrent = false
        }
        if let messageEndpoint,
           event == .sessionStart || event == .statusLine,
           observedEpoch == task.sessionEpoch,
           messageEndpoint.providerId == task.agentId,
           sessionMatchesCurrent {
            acceptedMessageEndpoint = messageEndpoint
        } else {
            acceptedMessageEndpoint = nil
        }
        // A decoded endpoint proves this is a credential-bearing current-version hook. If its identity is
        // stale, drop that hook's metadata too: applying its session id first would roll the card backward,
        // close the valid handle during report reconciliation, then make the endpoint fence meaningless.
        // Endpoint-absent (older provider/helper) hooks retain their existing compatibility behavior.
        let hookIdentityAccepted = messageEndpoint == nil || acceptedMessageEndpoint != nil
        let acceptedReport = hookIdentityAccepted ? report : nil

        // STOP: claim/confirm the stopDrain BEFORE applying the Stop observation. A real Claude Stop
        // observation lands `.live(.waiting)`, whose wake-on-live (+Lifecycle step 7) would else
        // cold-relaunch a `nativeReinvoke` card with no active CLI wait — bumping the epoch out from under
        // this same-epoch claim, so `payloadForStop`'s entry fence then fails and a HEALTHY session is
        // needlessly restarted on every send. The Stop hook IS the reinvoke, so its same-epoch stopDrain
        // claim must win over a cold relaunch: claiming first mints a live same-epoch lease, and the
        // subsequent waiting-landing wake then DEFERS on `hasLiveLease` (deliver rung 3) instead of
        // relaunching. Applying the observation afterward still lands the phase; the epoch fence's real purpose
        // is untouched — a genuinely stale Stop (observedEpoch ≠ sessionEpoch) still no-ops in payloadForStop.
        if event == .stop {
            let continuation = await payloadForStop(task.id, observedEpoch: observedEpoch,
                                                    stopHookActive: stopHookActive)
            if let acceptedReport {
                try? await self.report(task.id, acceptedReport, observedEpoch: observedEpoch)
            }
            if let observationPayload {
                await receivePushedAgentObservation(
                    cardId: task.id,
                    observedEpoch: observedEpoch,
                    raw: .hooksPush(kind: event.rawValue, payload: observationPayload)
                )
            }
            if let acceptedMessageEndpoint {
                await receiveAgentMessageEndpoint(
                    cardId: task.id, report: acceptedMessageEndpoint,
                    observedEpoch: observedEpoch, event: event
                )
            }
            return continuation.map { HookResponse(continuation: $0) }
        }

        if let acceptedReport {
            try? await self.report(task.id, acceptedReport, observedEpoch: observedEpoch)
        }
        if let observationPayload {
            await receivePushedAgentObservation(
                cardId: task.id,
                observedEpoch: observedEpoch,
                raw: .hooksPush(kind: event.rawValue, payload: observationPayload)
            )
        }
        if let acceptedMessageEndpoint {
            await receiveAgentMessageEndpoint(
                cardId: task.id, report: acceptedMessageEndpoint,
                observedEpoch: observedEpoch, event: event
            )
        }
        if hookIdentityAccepted, event == .sessionStart, let source,
           source != .startup, source != .compact,
           acceptedReport?.event?.sessionSource == nil {
            try? await self.report(task.id, StatusReport(sessionSource: source.rawValue),
                                   observedEpoch: observedEpoch)
        }
        switch event {
        case .sessionStart where source != .compact:
            // Skip re-orienting on a mid-turn compact (the agent already has its bearings).
            return await sessionBrief(task.id).map { HookResponse(additionalContext: $0) }
        default:
            return nil
        }
    }
}
