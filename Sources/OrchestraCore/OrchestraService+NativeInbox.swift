import Foundation

extension OrchestraService {
    static let nativeInboxAttemptLimit = 3
    static let nativeInboxAttemptTimeout: TimeInterval = 5

    /// The one enqueue boundary for human and daemon messages. A sender may be absent while a card is
    /// launching; reconciliation installs it later and re-arms this same queue without a second path.
    @discardableResult
    func enqueueAndArm(_ cardId: UUID, _ text: String, messageId: UUID? = nil,
                       source: InboxMessageSource? = .orchestra,
                       dedupKey: String? = nil) async throws -> Bool {
        if let messageId {
            guard try await inbox.enqueueIfUnknown(cardId, text, id: messageId, source: source) else {
                return false
            }
        } else {
            try await inbox.enqueue(cardId, text, source: source, dedupKey: dedupKey)
        }
        if let card = await store.get(cardId) { armNativeInbox(card) }
        return true
    }

    /// Arm only one token-fenced sender loop for a card's exact current live session. Sender status is
    /// intentionally not consulted: the provider endpoint is the acceptance boundary, not a board guess.
    func armNativeInbox(_ card: Task) {
        guard card.phase.kind == .live,
              let harnessSessionId = card.agentSessionId, !harnessSessionId.isEmpty,
              let handle = runtime[card.id]?.agentMessageHandle,
              handle.identity == .init(providerId: card.agentId, sessionEpoch: card.sessionEpoch,
                                       harnessSessionId: harnessSessionId),
              runtime[card.id]?.tasks[.nativeInbox] == nil
        else { return }

        _ = arm(card.id, .nativeInbox) { token in
            _Concurrency.Task { [weak self] in
                await self?.drainNativeInbox(card.id, token: token)
            }
        }
    }

    /// Retry is explicitly owner-scoped at the service boundary. A failed head remains FIFO-blocking until
    /// this operation puts it back in the queue, at which point the normal sender loop resumes it.
    func inboxRetry(_ cardId: UUID, messageId: UUID) async throws {
        let card = try await require(cardId)
        if try await inbox.retry(cardId: card.id, messageId: messageId) { armNativeInbox(card) }
    }

    private struct NativeInboxAttempt {
        let messageId: UUID
        let text: String
        let identity: CardRuntime.AgentMessageIdentity
        let handle: CardRuntime.AgentMessageHandle
    }

    private func drainNativeInbox(_ cardId: UUID, token: UInt64) async {
        defer { clearSlot(cardId, .nativeInbox, ifToken: token) }
        while !_Concurrency.Task.isCancelled {
            guard let message = await inbox.nextDeliverable(cardId),
                  let attempt = await nativeInboxAttempt(cardId: cardId, message: message, token: token)
            else { return }

            var accepted = false
            for _ in 0..<Self.nativeInboxAttemptLimit {
                guard !_Concurrency.Task.isCancelled, ownsNativeInboxAttempt(attempt, cardId: cardId, token: token)
                else { return }
                do {
                    try await attempt.handle.sender.send(attempt.text, timeout: Self.nativeInboxAttemptTimeout)
                    accepted = true
                    break
                } catch {
                    guard ownsNativeInboxAttempt(attempt, cardId: cardId, token: token) else { return }
                }
            }

            guard !_Concurrency.Task.isCancelled, ownsNativeInboxAttempt(attempt, cardId: cardId, token: token)
            else { return }
            do {
                if accepted {
                    _ = try await inbox.markHandedOff(
                        cardId: cardId, messageId: attempt.messageId, expectedText: attempt.text)
                } else {
                    _ = try await inbox.markFailed(
                        cardId: cardId, messageId: attempt.messageId, expectedText: attempt.text)
                }
            } catch {
                // Provider acceptance is already a fact. On a persistence error leave the old queued row
                // durable and let a later arm retry rather than pretending a receipt exists.
                return
            }
        }
    }

    /// One durable card snapshot before submission carries every long-lived identity fence. No sender-loop
    /// decision reads `running`, `waiting`, or any other inferred provider status.
    private func nativeInboxAttempt(cardId: UUID, message: InboxMessage,
                                    token: UInt64) async -> NativeInboxAttempt? {
        guard runtime[cardId]?.tasks[.nativeInbox]?.token == token,
              let card = await store.get(cardId),
              card.phase.kind == .live,
              let harnessSessionId = card.agentSessionId, !harnessSessionId.isEmpty,
              let handle = runtime[cardId]?.agentMessageHandle
        else { return nil }
        let identity = CardRuntime.AgentMessageIdentity(
            providerId: card.agentId, sessionEpoch: card.sessionEpoch, harnessSessionId: harnessSessionId)
        guard handle.identity == identity else { return nil }
        return NativeInboxAttempt(messageId: message.id, text: message.text, identity: identity, handle: handle)
    }

    /// The reference check is deliberately stricter than identity equality: a credential refresh can keep
    /// the same provider/session fields while replacing the endpoint, and its old completion must not win.
    private func ownsNativeInboxAttempt(_ attempt: NativeInboxAttempt, cardId: UUID, token: UInt64) -> Bool {
        runtime[cardId]?.tasks[.nativeInbox]?.token == token
            && runtime[cardId]?.agentMessageHandle === attempt.handle
            && runtime[cardId]?.agentMessageHandle?.identity == attempt.identity
    }
}
