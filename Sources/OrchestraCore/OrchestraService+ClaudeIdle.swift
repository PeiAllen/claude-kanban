import Foundation

private struct ClaudeIdleCandidate: Sendable {
    let cardId: UUID
    let sessionEpoch: Int
    let harnessSessionId: String
    let observationGeneration: UInt64
    /// Captured at scan time; the recheck requires an EXACT match, not just membership in
    /// `{.running, .unavailable}`. The generation counter bumps at signal SUBMIT, not at apply, so a
    /// hook that submits between the scan and the recheck can leave the generation unchanged while the
    /// durable state has already moved (e.g. `.unavailable` → `.running` via a genuine new turn). Pinning
    /// the exact status closes that window: the recheck then sees a status it doesn't recognize and skips.
    let turnStatus: TurnStatus
}

extension OrchestraService {
    /// Repair two Claude hook gaps from one provider-native global snapshot. Hooks remain authoritative
    /// for starts, Stops, continuations, and human gates: this can only narrow a still-running,
    /// unchanged session to waiting (the hook-silent Ctrl-C gap), or carry an `.unavailable` card left
    /// by a daemon restart's boot-adoption invalidate to waiting once its session is confirmed idle
    /// (Claude has no snapshot-on-bind; Codex restores its state from its attach response instead).
    /// Never promotes `.unavailable` on a `busy` snapshot: with no correlated turn id, the eventual
    /// Stop hook would fall through to `observationLost` and flicker the card back to unavailable —
    /// busy cards instead self-heal from their own next `messagedisplay` hook.
    public func reconcileClaudeIdle() async {
        guard !claudeIdleReconcileInFlight else { return }
        claudeIdleReconcileInFlight = true
        defer { claudeIdleReconcileInFlight = false }

        let cards = await store.all()
        let candidates: [ClaudeIdleCandidate] = cards.compactMap { card in
            guard card.agentId == "claude-code",
                  case .live(let state) = card.phase,
                  state.turnStatus == .running || state.turnStatus == .unavailable,
                  state.humanNeed == nil,
                  let sessionID = card.agentSessionId,
                  !sessionID.isEmpty,
                  let generation = runtime[card.id]?.agentObservationGeneration
            else { return nil }
            return .init(
                cardId: card.id,
                sessionEpoch: card.sessionEpoch,
                harnessSessionId: sessionID,
                observationGeneration: generation,
                turnStatus: state.turnStatus
            )
        }
        guard !candidates.isEmpty,
              let adapter = try? registry.get("claude-code"),
              let result = try? await proc.run(
                [adapter.bin, "agents", "--json"], cwd: nil, env: [:], timeout: .seconds(3)
              ),
              result.ok,
              let root = try? JSONValue.parse(Data(result.stdout.utf8)),
              let agents = root.arrayValue
        else { return }

        let idleSessions = Set(agents.compactMap { agent -> String? in
            guard agent["status"]?.stringValue == "idle" else { return nil }
            return agent["sessionId"]?.stringValue
        })
        for candidate in candidates where idleSessions.contains(candidate.harnessSessionId) {
            guard let current = await store.get(candidate.cardId),
                  current.agentId == "claude-code",
                  current.sessionEpoch == candidate.sessionEpoch,
                  current.agentSessionId == candidate.harnessSessionId,
                  runtime[current.id]?.agentObservationGeneration == candidate.observationGeneration,
                  case .live(let state) = current.phase,
                  state.turnStatus == candidate.turnStatus,
                  state.humanNeed == nil
            else { continue }

            await submitAgentSignals(
                [.init(
                    sessionEpoch: current.sessionEpoch,
                    kind: .turnReconciled(.waiting(), humanNeed: nil)
                )],
                cardId: current.id,
                context: .init(
                    sessionEpoch: current.sessionEpoch,
                    harnessSessionId: current.agentSessionId
                )
            )
        }
    }
}
