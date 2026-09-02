import Foundation
import OrchestraKit
import TestSupport
@testable import OrchestraCore

extension OrchestraService {
    func testSetTurnStatus(_ id: UUID, _ status: TurnStatus) async throws {
        guard let card = await store.get(id) else { return }
        await receiveAgentSignals(
            cardId: id,
            signals: [.init(sessionEpoch: card.sessionEpoch, kind: .turnReconciled(status, humanNeed: nil))]
        )
        try await waitForObservationQueueIdle(id)
    }

    func testCompleteTurn(_ id: UUID, resume: AutomaticResume? = nil) async throws {
        guard let card = await store.get(id) else { return }
        await receiveAgentSignals(
            cardId: id,
            signals: [
                .init(sessionEpoch: card.sessionEpoch, turnID: "test-turn", kind: .turnStarted),
                .init(sessionEpoch: card.sessionEpoch, turnID: "test-turn", kind: .turnCompleted(resume: resume)),
            ]
        )
        try await waitForObservationQueueIdle(id)
    }

    func testSetHumanNeed(_ id: UUID, _ humanNeed: ProviderHumanNeed?) async throws {
        guard let card = await store.get(id) else { return }
        await receiveAgentSignals(
            cardId: id,
            signals: [
                .init(
                    sessionEpoch: card.sessionEpoch,
                    kind: .turnReconciled(card.agentState?.turnStatus ?? .unavailable, humanNeed: humanNeed)
                ),
            ]
        )
        try await waitForObservationQueueIdle(id)
    }

    /// `submit` is one-way (`AgentObservationCoordinator`'s doc comment) — a caller no longer blocks
    /// until its submission is applied. These test helpers restore that old synchronous contract at
    /// this one seam, so the ~30 call sites that assert immediately after them don't each need their
    /// own poll. THROWS (not `try?`) on a genuine timeout — a wedged queue must abort the test loudly
    /// here, per `Wait.swift`'s own discipline, not surface as a confusing downstream assertion failure.
    /// A card/coordinator that no longer exists is a legitimate idle state (nothing left to wait for),
    /// not a timeout.
    func waitForObservationQueueIdle(_ id: UUID, timeout: Duration = .seconds(30)) async throws {
        try await pollUntil("card \(id)'s observation queue to drain", timeout: timeout) {
            await self.runtime[id]?.agentObservationCoordinator.isIdle ?? true
        }
    }
}
