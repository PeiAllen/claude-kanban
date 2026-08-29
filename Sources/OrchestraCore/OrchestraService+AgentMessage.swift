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
              card.agentSessionId == report.harnessSessionId,
              ensureRuntime(for: card)
        else { return }

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

    /// Make the runtime sender match the durable card's exact live identity. The endpoint buffer is
    /// intentionally retained if this adapter has not supplied its sender yet (commit 2 adds providers).
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
        guard let pending = runtime[card.id]?.pendingAgentMessageEndpoint else { return }
        guard pending.identity == expected else {
            runtime[card.id]?.pendingAgentMessageEndpoint = nil
            return
        }
        if let current = runtime[card.id]?.agentMessageHandle,
           current.identity == expected, current.endpoint == pending.endpoint {
            runtime[card.id]?.pendingAgentMessageEndpoint = nil
            return
        }
        guard let adapter = try? registry.get(expected.providerId),
              let sender = adapter.makeMessageSender(for: pending.endpoint)
        else { return }

        let previous = runtime[card.id]?.agentMessageHandle
        runtime[card.id]?.agentMessageHandle = CardRuntime.AgentMessageHandle(
            identity: expected,
            endpoint: pending.endpoint,
            sender: sender
        )
        runtime[card.id]?.pendingAgentMessageEndpoint = nil
        previous?.sender.shutdown()
    }

    private func stopAgentMessageHandle(_ cardId: UUID) {
        guard let current = runtime[cardId]?.agentMessageHandle else { return }
        runtime[cardId]?.agentMessageHandle = nil
        current.sender.shutdown()
    }
}
