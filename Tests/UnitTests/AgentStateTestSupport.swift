import Foundation
import OrchestraKit
@testable import OrchestraCore

extension OrchestraService {
    func testSetTurnStatus(_ id: UUID, _ status: TurnStatus) async {
        guard let card = await store.get(id) else { return }
        await receiveAgentSignals(
            cardId: id,
            signals: [.init(sessionEpoch: card.sessionEpoch, kind: .turnReconciled(status, humanNeed: nil))]
        )
    }

    func testCompleteTurn(_ id: UUID, resume: AutomaticResume? = nil) async {
        guard let card = await store.get(id) else { return }
        await receiveAgentSignals(
            cardId: id,
            signals: [
                .init(sessionEpoch: card.sessionEpoch, turnID: "test-turn", kind: .turnStarted),
                .init(sessionEpoch: card.sessionEpoch, turnID: "test-turn", kind: .turnCompleted(resume: resume)),
            ]
        )
    }

    func testSetHumanNeed(_ id: UUID, _ humanNeed: ProviderHumanNeed?) async {
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
    }
}
