/// Serializes all normalized observations for one card and rejects positively identified events
/// from a turn that has already been superseded. Claude hooks and OTLP share this path, so a delayed
/// terminal span for prompt A cannot close prompt B after B has started.
actor AgentObservationCoordinator {
    private struct Submission: Sendable {
        let scope: AgentSignalContext
        let signals: [AgentSignal]
        let apply: @Sendable ([AgentSignal]) async -> Void
        let continuation: CheckedContinuation<Void, Never>
    }

    private var submissions: [Submission] = []
    private var isDraining = false
    private var scope: AgentSignalContext?
    private var activeTurnID: String?
    private var lastCompletedTurnID: String?

    func submit(
        scope: AgentSignalContext,
        signals: [AgentSignal],
        apply: @escaping @Sendable ([AgentSignal]) async -> Void
    ) async {
        guard !signals.isEmpty else { return }

        await withCheckedContinuation { continuation in
            submissions.append(.init(
                scope: scope,
                signals: signals,
                apply: apply,
                continuation: continuation
            ))
            guard !isDraining else { return }
            isDraining = true
            _Concurrency.Task { await self.drain() }
        }
    }

    private func drain() async {
        while !submissions.isEmpty {
            let submission = submissions.removeFirst()
            let accepted = filter(submission.signals, in: submission.scope)
            if !accepted.isEmpty {
                await submission.apply(accepted)
            }
            submission.continuation.resume()
        }
        isDraining = false
    }

    private func filter(
        _ signals: [AgentSignal],
        in newScope: AgentSignalContext
    ) -> [AgentSignal] {
        if scope != newScope {
            scope = newScope
            activeTurnID = nil
            lastCompletedTurnID = nil
        }

        return signals.filter(accept)
    }

    private func accept(_ signal: AgentSignal) -> Bool {
        switch signal.kind {
        case .turnStarted:
            guard let turnID = signal.turnID else { return true }
            activeTurnID = turnID
            return true

        case .turnCompleted:
            guard let turnID = signal.turnID else {
                activeTurnID = nil
                lastCompletedTurnID = nil
                return true
            }
            if let activeTurnID {
                guard activeTurnID == turnID else { return false }
            } else if let lastCompletedTurnID {
                guard lastCompletedTurnID == turnID else { return false }
            }
            activeTurnID = nil
            lastCompletedTurnID = turnID
            return true

        case .requests(let requests):
            guard let turnID = signal.turnID else { return true }
            if let activeTurnID {
                return activeTurnID == turnID
            }
            // A terminal event may clear its own request after marking the turn complete. A delayed
            // request creation for a completed turn must never resurrect that prompt.
            if requests.isEmpty {
                return lastCompletedTurnID == nil || lastCompletedTurnID == turnID
            }
            return lastCompletedTurnID == nil

        case .activity:
            guard let turnID = signal.turnID else { return true }
            if let activeTurnID { return activeTurnID == turnID }
            return lastCompletedTurnID == nil

        case .observationLost:
            activeTurnID = nil
            lastCompletedTurnID = nil
            return true

        case .turnReconciled:
            // Snapshot-style providers supersede event-pair history atomically. Claude also uses this
            // signal for session clear/resume, which must not retain the prior prompt's fence.
            activeTurnID = nil
            lastCompletedTurnID = nil
            return true
        }
    }
}
