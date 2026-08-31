import Foundation

private final class AgentObservationAttemptMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func markObserved() { lock.withLock { value = true } }
    var observed: Bool { lock.withLock { value } }
}

extension OrchestraService {
    func agentObservationActive(_ id: UUID) -> Bool { runtime[id]?.tasks[.agentObservation] != nil }

    func invalidateAgentObservation(_ card: Task) async {
        await submitAgentSignals(
            [.init(sessionEpoch: card.sessionEpoch, kind: .observationLost)],
            cardId: card.id,
            context: .init(
                sessionEpoch: card.sessionEpoch,
                harnessSessionId: card.agentSessionId
            )
        )
    }

    func receiveAgentSignals(cardId: UUID, signals: [AgentSignal]) async {
        guard let card = await store.get(cardId) else { return }
        await submitAgentSignals(
            signals,
            cardId: cardId,
            context: .init(
                sessionEpoch: card.sessionEpoch,
                harnessSessionId: card.agentSessionId
            )
        )
    }

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
              card.sessionEpoch == observedEpoch,
              let adapter = try? registry.get(card.agentId)
        else { return }

        let context = AgentSignalContext(
            sessionEpoch: observedEpoch,
            harnessSessionId: card.agentSessionId
        )
        let signals = adapter.agentSignals(from: raw, context: context)
        guard !signals.isEmpty else { return }

        switch card.phase.kind {
        case .live:
            await submitAgentSignals(signals, cardId: card.id, context: context)
        case .launching, .relaunching:
            guard ensureRuntime(for: card) else { return }
            if runtime[card.id]?.pendingAgentSignals?.context == context {
                runtime[card.id]?.pendingAgentSignals?.signals.append(contentsOf: signals)
            } else {
                runtime[card.id]?.pendingAgentSignals = .init(context: context, signals: signals)
            }
        default:
            return
        }
    }

    /// Make the structured source match the card's current live session. Repeated calls with the same
    /// identity are no-ops, so boot adoption, phase transitions, and session-id binding can all converge
    /// through this one function without reconnect churn.
    func reconcileAgentObservation(_ card: Task) async {
        guard ensureRuntime(for: card) else { return }
        guard card.phase.kind == .live else {
            stopAgentObservation(card.id)
            return
        }

        guard let adapter = try? registry.get(card.agentId),
              let endpoint = preparedObservationEndpoint(for: card, adapter: adapter)
        else {
            stopAgentObservation(card.id)
            return
        }

        let binding = AgentObservationBinding(
            harnessSessionId: card.agentSessionId,
            cwd: card.cwd,
            startedAfter: card.agentSessionId == nil ? card.sessionDiscoverySince : nil
        )
        if endpoint.isPushOnly,
           binding.harnessSessionId?.isEmpty != false {
            stopAgentObservation(card.id)
            return
        }

        let identity = CardRuntime.AgentObservationIdentity(
            endpoint: endpoint,
            sessionEpoch: card.sessionEpoch,
            binding: binding
        )
        if runtime[card.id]?.agentObservationIdentity == identity,
           (endpoint.isPushOnly || runtime[card.id]?.tasks[.agentObservation] != nil) {
            return
        }
        if endpoint.isPushOnly {
            let pending = runtime[card.id]?.pendingAgentSignals
            stopAgentObservation(card.id)
            runtime[card.id]?.agentObservationIdentity = identity
            let context = AgentSignalContext(
                sessionEpoch: card.sessionEpoch,
                harnessSessionId: binding.harnessSessionId
            )
            if let pending, pending.context == context {
                await submitAgentSignals(pending.signals, cardId: card.id, context: context)
            } else {
                // Hooks do not replay a provider snapshot on bind. A reconstructed Claude source therefore
                // starts unavailable until its next exactly-correlated hook establishes current observation.
                await submitAgentSignals(
                    [.init(sessionEpoch: card.sessionEpoch, kind: .observationLost)],
                    cardId: card.id,
                    context: context
                )
            }
            return
        }
        guard let firstSource = adapter.makeObservationSource(
            endpoint: endpoint,
            binding: binding
        ) else {
            stopAgentObservation(card.id)
            return
        }

        stopAgentObservation(card.id)
        runtime[card.id]?.agentObservationIdentity = identity
        _ = arm(card.id, .agentObservation) { token in
            _Concurrency.Task { [weak self, clock] in
                var source: (any AgentObservationSource)? = firstSource
                var failedAttempts = 0
                while !_Concurrency.Task.isCancelled, let current = source {
                    let attempt = AgentObservationAttemptMarker()
                    do {
                        try await withTaskCancellationHandler {
                            for try await raw in AgentObservationIngress(source: current).stream() {
                                guard let self else { continue }
                                attempt.markObserved()
                                // The async sequence retains callback order and awaits each actor apply, so
                                // a later completion or disconnect cannot overtake an earlier turn start.
                                await self.receiveAgentObservation(
                                    cardId: card.id,
                                    identity: identity,
                                    token: token,
                                    raw: raw
                                )
                            }
                        } onCancel: {
                            current.shutdown()   // synchronously unblocks the dispatch-backed read
                        }
                    } catch {
                        // A closed/refused stream has one meaning for state: observation is unavailable.
                        // The reconnect below is transport recovery, not provider-status polling.
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
                        binding: identity.binding
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
              card.agentSessionId == identity.binding.harnessSessionId,
              observationStillOwns(cardId, identity: identity, token: token),
              let adapter = try? registry.get(card.agentId)
        else { return }

        // A structured provider may create or replace its durable session identity after launch. The
        // source has already fenced and provider-filtered this raw event; persist the adapter-normalized
        // identity first, which synchronously retires this source and rearms against the exact session.
        if let patch = adapter.parse(raw),
           let sessionId = patch.event?.sessionId,
           !sessionId.isEmpty {
            try? await report(card.id, patch, observedEpoch: identity.sessionEpoch)
            return
        }

        let context = AgentSignalContext(
            sessionEpoch: identity.sessionEpoch,
            harnessSessionId: identity.binding.harnessSessionId
        )
        await submitAgentSignals(
            adapter.agentSignals(from: raw, context: context),
            cardId: card.id,
            context: context
        )
    }

    private func agentObservationDisconnected(
        cardId: UUID,
        identity: CardRuntime.AgentObservationIdentity,
        token: UInt64
    ) async {
        guard observationStillOwns(cardId, identity: identity, token: token),
              let card = await store.get(cardId),
              observationStillOwns(cardId, identity: identity, token: token)
        else { return }
        await submitAgentSignals(
            [.init(sessionEpoch: identity.sessionEpoch, kind: .observationLost)],
            cardId: card.id,
            context: .init(
                sessionEpoch: identity.sessionEpoch,
                harnessSessionId: identity.binding.harnessSessionId
            )
        )
    }

    private func observationStillOwns(
        _ cardId: UUID,
        identity: CardRuntime.AgentObservationIdentity,
        token: UInt64
    ) -> Bool {
        runtime[cardId]?.agentObservationIdentity == identity
            && runtime[cardId]?.tasks[.agentObservation]?.token == token
    }

    private func stopAgentObservation(_ id: UUID) {
        disarm(id, .agentObservation)
        runtime[id]?.agentObservationIdentity = nil
        runtime[id]?.pendingAgentSignals = nil
    }

    /// Route every source through the card-owned queue before touching durable state. The apply closure
    /// re-reads the card after it reaches the front, so two suspended callers can never reduce from the
    /// same stale snapshot and overwrite each other.
    private func submitAgentSignals(
        _ signals: [AgentSignal],
        cardId: UUID,
        context: AgentSignalContext
    ) async {
        guard !signals.isEmpty,
              let coordinator = runtime[cardId]?.agentObservationCoordinator
        else { return }

        await coordinator.submit(scope: context, signals: signals) { [weak self] accepted in
            await self?.applyAgentSignals(
                accepted,
                cardId: cardId,
                context: context,
                coordinator: coordinator
            )
        }
    }

    /// Apply a provider-neutral batch through the lifecycle transition funnel. The durable live value is
    /// the only state copy: reducer output, Card broadcast, wake-on-waiting, and persistence happen on the
    /// same `.live(old) → .live(new)` edge.
    private func applyAgentSignals(
        _ signals: [AgentSignal],
        cardId: UUID,
        context: AgentSignalContext,
        coordinator: AgentObservationCoordinator
    ) async {
        guard !signals.isEmpty,
              let currentCoordinator = runtime[cardId]?.agentObservationCoordinator,
              currentCoordinator === coordinator,
              let card = await store.get(cardId),
              card.sessionEpoch == context.sessionEpoch,
              card.agentSessionId == context.harnessSessionId,
              case .live(var state) = card.phase
        else { return }

        let before = state
        let acceptedDistinctTurnStart = signals.contains { signal in
            if case .turnStarted = signal.kind { return true }
            return false
        }
        for signal in signals {
            _ = AgentStateReducer.apply(
                signal,
                to: &state,
                currentSessionEpoch: card.sessionEpoch
            )
        }
        guard state != before || acceptedDistinctTurnStart else { return }

        let result = await transition(
            card.id,
            to: .live(state),
            observedEpoch: card.sessionEpoch,
            expecting: .live,
            refreshPhaseAge: acceptedDistinctTurnStart
        ) { task in
            if acceptedDistinctTurnStart { task.pendingQuestion = nil }
        }
        guard result == .applied else { return }

        if before.turnStatus != state.turnStatus,
           let updated = await store.get(card.id) {
            let word: String
            switch state.turnStatus {
            case .running:     word = "running"
            case .waiting:     word = "waiting"
            case .unavailable: word = "unavailable"
            }
            emitActivity(.statusChanged, updated, .agent, "agent \(word)")
        }
    }

    private nonisolated static func agentObservationReconnectDelay(attempt: Int) -> Duration {
        let milliseconds = min(5_000, 250 * (1 << min(max(0, attempt), 5)))
        return .milliseconds(milliseconds)
    }
}
