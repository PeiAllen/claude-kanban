import Foundation
import Dispatch

private final class AgentObservationAttemptMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func markObserved() { lock.withLock { value = true } }
    var observed: Bool { lock.withLock { value } }
}

extension OrchestraService {
    /// Dark-state test seam. This intentionally has no event/broadcast counterpart: legacy `Phase.live`
    /// remains the only externally visible status authority until the atomic cutover.
    func shadowAgentState(_ id: UUID) -> AgentState? { runtime[id]?.shadowAgentState }
    func agentObservationActive(_ id: UUID) -> Bool { runtime[id]?.tasks[.agentObservation] != nil }

    func preparedObservationEndpoint(for card: Task, adapter: any Adapter) -> AgentObservationEndpoint? {
        adapter.observationEndpoint(.init(
            cardId: card.id,
            cardRef: card.shortId,
            sessionEpoch: card.sessionEpoch,
            runtimeStateDir: config.runtimeStateDir,
            traceHTTPBaseURL: traceHTTPBaseURL
        ))
    }

    /// Apply one ephemeral push (hook or local OTLP receiver) against the card identity that exists now.
    /// Unlike a held observation source, a push has no source token to fence, so the launch epoch is
    /// mandatory and the adapter checks the provider-native session carried inside the raw event.
    public func receivePushedAgentObservation(
        cardId: UUID,
        observedEpoch: Int?,
        raw: RawTelemetry
    ) async {
        guard let observedEpoch,
              let card = await store.get(cardId),
              card.phase.kind == .live,
              card.sessionEpoch == observedEpoch,
              let adapter = try? registry.get(card.agentId)
        else { return }

        let context = AgentSignalContext(
            sessionEpoch: observedEpoch,
            harnessSessionId: card.agentSessionId
        )
        var state = runtime[cardId]?.shadowAgentState ?? AgentState(turnStatus: .unavailable)
        for signal in adapter.agentSignals(from: raw, context: context) {
            _ = AgentStateReducer.apply(
                signal,
                to: &state,
                currentSessionEpoch: card.sessionEpoch
            )
        }
        runtime[cardId]?.shadowAgentState = state
    }

    /// Make the structured source match the card's current live session. Repeated calls with the same
    /// identity are no-ops, so boot adoption, phase transitions, and session-id binding can all converge
    /// through this one function without reconnect churn.
    func reconcileAgentObservation(_ card: Task) {
        guard ensureRuntime(for: card) else { return }
        guard card.phase.kind == .live else {
            stopAgentObservation(card.id, discardState: true)
            return
        }

        let unavailable = AgentState(turnStatus: .unavailable)
        guard let adapter = try? registry.get(card.agentId),
              let endpoint = preparedObservationEndpoint(for: card, adapter: adapter),
              let sessionId = card.agentSessionId, !sessionId.isEmpty
        else {
            stopAgentObservation(card.id, discardState: false)
            runtime[card.id]?.shadowAgentState = unavailable
            return
        }

        let identity = CardRuntime.AgentObservationIdentity(
            endpoint: endpoint,
            sessionEpoch: card.sessionEpoch,
            harnessSessionId: sessionId
        )
        if runtime[card.id]?.agentObservationIdentity == identity,
           (endpoint.isPushOnly || runtime[card.id]?.tasks[.agentObservation] != nil) {
            return
        }
        if endpoint.isPushOnly {
            stopAgentObservation(card.id, discardState: false)
            runtime[card.id]?.agentObservationIdentity = identity
            runtime[card.id]?.shadowAgentState = unavailable
            return
        }
        guard let firstSource = adapter.makeObservationSource(
            endpoint: endpoint,
            harnessSessionId: sessionId
        ) else {
            stopAgentObservation(card.id, discardState: false)
            runtime[card.id]?.shadowAgentState = unavailable
            return
        }

        stopAgentObservation(card.id, discardState: false)
        runtime[card.id]?.agentObservationIdentity = identity
        runtime[card.id]?.shadowAgentState = unavailable
        _ = arm(card.id, .agentObservation) { token in
            _Concurrency.Task.detached { [weak self, clock] in
                var source: (any AgentObservationSource)? = firstSource
                var failedAttempts = 0
                while !_Concurrency.Task.isCancelled, let current = source {
                    let attempt = AgentObservationAttemptMarker()
                    await withTaskCancellationHandler {
                        guard !_Concurrency.Task.isCancelled else { return }
                        do {
                            try current.run { [weak self] raw in
                                guard let self else { return }
                                attempt.markObserved()
                                // `run` is a serial provider read loop. Back-pressure it until the actor
                                // applies this event so a later turn-completed or disconnect cannot overtake
                                // an earlier turn-started merely because two unstructured Tasks scheduled
                                // in the opposite order.
                                let applied = DispatchSemaphore(value: 0)
                                _Concurrency.Task {
                                    await self.receiveAgentObservation(
                                        cardId: card.id,
                                        identity: identity,
                                        token: token,
                                        raw: raw
                                    )
                                    applied.signal()
                                }
                                applied.wait()
                            }
                        } catch {
                            // A closed/refused stream has one meaning for state: observation is unavailable.
                            // The reconnect below is transport recovery, not provider-status polling.
                        }
                    } onCancel: {
                        current.shutdown()   // synchronously unblocks the source's blocking receive
                    }

                    if _Concurrency.Task.isCancelled { break }
                    await self?.agentObservationDisconnected(
                        cardId: card.id,
                        identity: identity,
                        token: token
                    )
                    if attempt.observed { failedAttempts = 0 }
                    let reconnectDelay = Self.agentObservationReconnectDelay(attempt: failedAttempts)
                    if !attempt.observed { failedAttempts = min(failedAttempts + 1, 5) }
                    do { try await clock.sleep(for: reconnectDelay) }
                    catch { break }
                    guard !_Concurrency.Task.isCancelled else { break }
                    source = adapter.makeObservationSource(
                        endpoint: identity.endpoint,
                        harnessSessionId: identity.harnessSessionId
                    )
                }
                await self?.clearSlot(card.id, .agentObservation, ifToken: token)
            }
        }
    }

    /// Apply one raw event only if the source still owns the exact live card/session incarnation it was
    /// armed for. The reducer repeats the epoch check on every normalized signal; the surrounding checks
    /// additionally fence queued callbacks from a replaced provider session in the same epoch (`/clear`).
    private func receiveAgentObservation(
        cardId: UUID,
        identity: CardRuntime.AgentObservationIdentity,
        token: UInt64,
        raw: RawTelemetry
    ) async {
        guard observationStillOwns(cardId, identity: identity, token: token),
              let card = await store.get(cardId),
              card.phase.kind == .live,
              card.sessionEpoch == identity.sessionEpoch,
              card.agentSessionId == identity.harnessSessionId,
              observationStillOwns(cardId, identity: identity, token: token),
              let adapter = try? registry.get(card.agentId)
        else { return }

        let context = AgentSignalContext(
            sessionEpoch: identity.sessionEpoch,
            harnessSessionId: identity.harnessSessionId
        )
        var state = runtime[cardId]?.shadowAgentState ?? AgentState(turnStatus: .unavailable)
        for signal in adapter.agentSignals(from: raw, context: context) {
            _ = AgentStateReducer.apply(
                signal,
                to: &state,
                currentSessionEpoch: card.sessionEpoch
            )
        }
        runtime[cardId]?.shadowAgentState = state
    }

    private func agentObservationDisconnected(
        cardId: UUID,
        identity: CardRuntime.AgentObservationIdentity,
        token: UInt64
    ) {
        guard observationStillOwns(cardId, identity: identity, token: token) else { return }
        var state = runtime[cardId]?.shadowAgentState ?? AgentState(turnStatus: .unavailable)
        _ = AgentStateReducer.apply(
            .init(sessionEpoch: identity.sessionEpoch, kind: .observationLost),
            to: &state,
            currentSessionEpoch: identity.sessionEpoch
        )
        runtime[cardId]?.shadowAgentState = state
    }

    private func observationStillOwns(
        _ cardId: UUID,
        identity: CardRuntime.AgentObservationIdentity,
        token: UInt64
    ) -> Bool {
        runtime[cardId]?.agentObservationIdentity == identity
            && runtime[cardId]?.tasks[.agentObservation]?.token == token
    }

    private func stopAgentObservation(_ id: UUID, discardState: Bool) {
        disarm(id, .agentObservation)
        runtime[id]?.agentObservationIdentity = nil
        if discardState { runtime[id]?.shadowAgentState = nil }
    }

    private nonisolated static func agentObservationReconnectDelay(attempt: Int) -> Duration {
        let milliseconds = min(5_000, 250 * (1 << min(max(0, attempt), 5)))
        return .milliseconds(milliseconds)
    }
}
