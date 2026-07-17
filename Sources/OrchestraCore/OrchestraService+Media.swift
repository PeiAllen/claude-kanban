import Foundation

extension OrchestraService {
    /// Publish a new daemon-owned image for the task's current session epoch.
    public func publishImage(_ id: UUID, sourcePath: String,
                             caption: String?) async throws -> TranscriptImageReference {
        let card = try await require(id)
        guard !card.archived else { throw OrchestraError.imageExpired }
        return try await mediaStore.publish(cardId: card.id, sessionEpoch: card.sessionEpoch,
                                            sourcePath: sourcePath, caption: caption)
    }

    /// Resolve an opaque reference only within the requested card's current durable session.
    public func transcriptImage(_ id: UUID, referenceID: UUID) async throws -> TranscriptImagePayload {
        let card = try await require(id)
        guard !card.archived else { throw OrchestraError.imageExpired }
        return try await mediaStore.payload(cardId: card.id, sessionEpoch: card.sessionEpoch,
                                            referenceID: referenceID)
    }

    /// Boot cleanup runs after durable task reconciliation, retaining only existing non-archived cards'
    /// current session directory.
    public func reconcileTranscriptMediaAtBoot() async {
        let active = Dictionary(uniqueKeysWithValues: (await store.all())
            .filter { !$0.archived }
            .map { ($0.id, $0.sessionEpoch) })
        await mediaStore.reconcile(activeCards: active)
    }
}
