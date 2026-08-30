import Foundation

extension OrchestraService {
    /// Accept one endpoint only for the card/provider/session incarnation that owns it now. SessionStart
    /// may establish a replacement harness id; status-line refreshes are restricted to the already-current
    /// id by `handleHook` before its metadata report can mutate card identity.
    func receiveAgentMessageEndpoint(
        cardId: UUID,
        report: AgentMessageEndpointReport,
        observedEpoch: Int?,
        event: HookEvent
    ) async {
        guard event == .sessionStart || event == .statusLine,
              let observedEpoch,
              let card = await store.get(cardId),
              card.sessionEpoch == observedEpoch,
              card.agentId == report.providerId,
              card.agentSessionId == report.harnessSessionId
        else { return }

        // A credential-bearing callback may arrive after terminal teardown. Check lifecycle before the
        // only runtime creation seam so a dead or archived card cannot regain an empty CardRuntime.
        switch card.phase.kind {
        case .launching, .live, .relaunching:
            break
        default:
            return
        }
        guard ensureRuntime(for: card) else { return }

        let pending = CardRuntime.PendingAgentMessageEndpoint(
            identity: .init(
                providerId: report.providerId,
                sessionEpoch: observedEpoch,
                harnessSessionId: report.harnessSessionId
            ),
            endpoint: report.endpoint
        )
        switch card.phase.kind {
        case .live:
            runtime[card.id]?.pendingAgentMessageEndpoint = pending
            reconcileAgentMessageHandle(card)
        case .launching, .relaunching:
            runtime[card.id]?.pendingAgentMessageEndpoint = pending
        default:
            break
        }
    }

    /// Make the runtime sender match the durable card's exact live identity. A different endpoint is a
    /// credential refresh: the old sender is invalidated before replacement, and a rejected replacement
    /// fails closed instead of retaining either stale credentials or an endlessly retried pending value.
    func reconcileAgentMessageHandle(_ card: Task) {
        guard ensureRuntime(for: card) else { return }

        guard card.phase.kind == .live,
              let harnessSessionId = card.agentSessionId, !harnessSessionId.isEmpty
        else {
            stopAgentMessageHandle(card.id)
            if card.phase.kind != .launching && card.phase.kind != .relaunching {
                runtime[card.id]?.pendingAgentMessageEndpoint = nil
            } else if let pending = runtime[card.id]?.pendingAgentMessageEndpoint,
                      pending.identity.sessionEpoch != card.sessionEpoch
                      || pending.identity.providerId != card.agentId
                      || pending.identity.harnessSessionId != card.agentSessionId {
                runtime[card.id]?.pendingAgentMessageEndpoint = nil
            }
            return
        }

        let expected = CardRuntime.AgentMessageIdentity(
            providerId: card.agentId,
            sessionEpoch: card.sessionEpoch,
            harnessSessionId: harnessSessionId
        )
        if runtime[card.id]?.agentMessageHandle?.identity != expected {
            stopAgentMessageHandle(card.id)
        }
        guard let adapter = try? registry.get(expected.providerId) else { return }
        let endpoint: AgentMessageEndpoint
        if let pending = runtime[card.id]?.pendingAgentMessageEndpoint {
            guard pending.identity == expected else {
                runtime[card.id]?.pendingAgentMessageEndpoint = nil
                return
            }
            endpoint = pending.endpoint
        } else {
            guard let observationEndpoint = preparedObservationEndpoint(for: card, adapter: adapter),
                  let derived = adapter.messageEndpoint(
                    observationEndpoint: observationEndpoint,
                    harnessSessionId: harnessSessionId
                  )
            else { return }
            endpoint = derived
        }
        if let current = runtime[card.id]?.agentMessageHandle,
           current.identity == expected, current.endpoint == endpoint {
            runtime[card.id]?.pendingAgentMessageEndpoint = nil
            return
        }

        let previous = runtime[card.id]?.agentMessageHandle
        runtime[card.id]?.agentMessageHandle = nil
        previous?.sender.shutdown()
        guard let sender = adapter.makeMessageSender(for: endpoint)
        else {
            runtime[card.id]?.pendingAgentMessageEndpoint = nil
            return
        }

        runtime[card.id]?.agentMessageHandle = CardRuntime.AgentMessageHandle(
            identity: expected,
            endpoint: endpoint,
            sender: sender
        )
        runtime[card.id]?.pendingAgentMessageEndpoint = nil
    }

    private func stopAgentMessageHandle(_ cardId: UUID) {
        guard let current = runtime[cardId]?.agentMessageHandle else { return }
        runtime[cardId]?.agentMessageHandle = nil
        current.sender.shutdown()
    }
}
