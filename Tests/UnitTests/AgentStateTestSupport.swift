import Foundation
import OrchestraKit
@testable import OrchestraCore

extension OrchestraService {
    func testSetTurnStatus(_ id: UUID, _ status: TurnStatus) async {
        guard let card = await store.get(id) else { return }
        await receiveAgentSignals(
            cardId: id,
            signals: [.init(sessionEpoch: card.sessionEpoch, kind: .turnReconciled(status))]
        )
    }

    func testCompleteTurn(_ id: UUID, resume: AutomaticResume? = nil) async {
        guard let card = await store.get(id) else { return }
        await receiveAgentSignals(
            cardId: id,
            signals: [.init(sessionEpoch: card.sessionEpoch, kind: .turnCompleted(resume: resume))]
        )
    }

    func testSetRequests(_ id: UUID, _ requests: [AgentRequest]) async {
        guard let card = await store.get(id) else { return }
        await receiveAgentSignals(
            cardId: id,
            signals: [.init(sessionEpoch: card.sessionEpoch, kind: .requests(requests))]
        )
    }
}
