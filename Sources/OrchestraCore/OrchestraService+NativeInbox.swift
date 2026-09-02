import Foundation

extension OrchestraService {
    static let nativeInboxAttemptLimit = 3
    static let nativeInboxAttemptTimeout: TimeInterval = 5

    /// The one enqueue boundary for human and daemon messages. A replayed explicit id still arms: a prior
    /// provider acceptance may have reached the provider while its durable `handedOff` write failed.
    @discardableResult
    func enqueueAndArm(_ cardId: UUID, _ text: String, messageId: UUID? = nil,
                       source: InboxMessageSource? = .orchestra,
                       dedupKey: String? = nil) async throws -> Bool {
        let inserted: Bool
        if let messageId {
            inserted = try await inbox.enqueueIfUnknown(cardId, text, id: messageId, source: source)
        } else {
            try await inbox.enqueue(cardId, text, source: source, dedupKey: dedupKey)
            inserted = true
        }
        if let card = await store.get(cardId) { armNativeInbox(card.id) }
        return inserted
    }

    /// Each request advances the wake generation, while at most one token-fenced loop owns FIFO work.
    /// The loop validates lifecycle and provider identity at its one durable snapshot immediately before it
    /// submits, so this method intentionally does not consult any provider-status estimate.
    func armNativeInbox(_ card: Task) { armNativeInbox(card.id) }

    func armNativeInbox(_ cardId: UUID) {
        guard var cardRuntime = runtime[cardId] else { return }
        cardRuntime.nativeInboxWakeGeneration &+= 1
        let wakeGeneration = cardRuntime.nativeInboxWakeGeneration
        guard cardRuntime.tasks[.nativeInbox] == nil else {
            runtime[cardId] = cardRuntime
            return
        }

        let token = nextRuntimeToken()
        cardRuntime.tasks[.nativeInbox] = .init(token: token, task: _Concurrency.Task { [weak self] in
            await self?.drainNativeInbox(cardId, token: token, wakeGeneration: wakeGeneration)
        })
        runtime[cardId] = cardRuntime
    }

    /// Retry starts a new delivery budget for the explicitly requeued FIFO head.
    func inboxRetry(_ cardId: UUID, messageId: UUID) async throws {
        let card = try await require(cardId)
        if try await inbox.retry(cardId: card.id, messageId: messageId) {
            runtime[card.id]?.nativeInboxAttempt = nil
            armNativeInbox(card.id)
        }
    }

    private struct NativeInboxSubmission {
        let message: InboxMessage
        let identity: CardRuntime.AgentMessageIdentity
        let handle: CardRuntime.AgentMessageHandle?
    }

    private func drainNativeInbox(_ cardId: UUID, token: UInt64, wakeGeneration initialWakeGeneration: UInt64) async {
        var wakeGeneration = initialWakeGeneration
        defer { clearSlot(cardId, .nativeInbox, ifToken: token) }

        while !_Concurrency.Task.isCancelled {
            guard armingToken(cardId, .nativeInbox) == token else { return }
            let message = await inbox.nextDeliverable(cardId)
            guard armingToken(cardId, .nativeInbox) == token else { return }
            guard let message else {
                runtime[cardId]?.nativeInboxAttempt = nil
                let currentWake = runtime[cardId]?.nativeInboxWakeGeneration ?? wakeGeneration
                guard currentWake != wakeGeneration else { return }
                wakeGeneration = currentWake
                continue
            }

            guard let submission = await nativeInboxSubmission(cardId, message: message, token: token),
                  ownsNativeInboxSubmission(submission, cardId: cardId, token: token),
                  let attempt = nextNativeInboxAttempt(cardId, submission: submission)
            else { return }

            if attempt == 0 {
                if await failNativeInboxSubmission(submission, cardId: cardId, token: token) { return }
                continue
            }

            let accepted: Bool
            if let handle = submission.handle {
                do {
                    try await handle.sender.send(
                        nativeInboxPayload(for: submission.message),
                        timeout: Self.nativeInboxAttemptTimeout
                    )
                    accepted = true
                } catch {
                    accepted = false
                }
            } else {
                accepted = false
            }
            guard !_Concurrency.Task.isCancelled,
                  ownsNativeInboxSubmission(submission, cardId: cardId, token: token)
            else { return }

            if accepted {
                // Provider acceptance is the boundary. Clearing before the CAS intentionally leaves a durable
                // write failure queued for an explicit replay with no invented receipt state.
                clearNativeInboxAttempt(cardId, submission: submission)
                do {
                    _ = try await inbox.markHandedOff(
                        cardId: cardId, messageId: submission.message.id, expectedText: submission.message.text)
                } catch {
                    return
                }
                continue
            }

            if attempt == Self.nativeInboxAttemptLimit {
                if await failNativeInboxSubmission(submission, cardId: cardId, token: token) { return }
                continue
            }
            do {
                try await clock.sleep(for: nativeInboxBackoff(after: attempt))
            } catch {
                return
            }
            guard !_Concurrency.Task.isCancelled,
                  ownsNativeInboxSubmission(submission, cardId: cardId, token: token)
            else { return }
        }
    }

    /// One durable identity snapshot before each provider submission. A missing current handle is an attempt
    /// too; a replacement invalidates the exact-reference fence and lets its own loop continue the budget.
    private func nativeInboxSubmission(_ cardId: UUID, message: InboxMessage,
                                       token: UInt64) async -> NativeInboxSubmission? {
        guard armingToken(cardId, .nativeInbox) == token,
              let card = await store.get(cardId),
              card.phase.kind == .live,
              let harnessSessionId = card.agentSessionId, !harnessSessionId.isEmpty,
              armingToken(cardId, .nativeInbox) == token
        else { return nil }
        let identity = CardRuntime.AgentMessageIdentity(
            providerId: card.agentId, sessionEpoch: card.sessionEpoch, harnessSessionId: harnessSessionId)
        let current = runtime[cardId]?.agentMessageHandle
        let handle = current?.identity == identity ? current : nil
        return .init(message: message, identity: identity, handle: handle)
    }

    /// A credential refresh can preserve identity, so reference equality remains the post-await authority.
    private func ownsNativeInboxSubmission(_ submission: NativeInboxSubmission,
                                           cardId: UUID, token: UInt64) -> Bool {
        guard armingToken(cardId, .nativeInbox) == token else { return false }
        if let handle = submission.handle {
            return runtime[cardId]?.agentMessageHandle === handle
                && runtime[cardId]?.agentMessageHandle?.identity == submission.identity
        }
        return runtime[cardId]?.agentMessageHandle == nil
    }

    /// Returns 0 only when the exact snapshot already used all three slots; callers mark it failed without a
    /// fourth send. Changing text, message id, or provider/session identity starts a fresh key.
    private func nextNativeInboxAttempt(_ cardId: UUID, submission: NativeInboxSubmission) -> Int? {
        guard let prior = runtime[cardId]?.nativeInboxAttempt else {
            runtime[cardId]?.nativeInboxAttempt = .init(
                messageId: submission.message.id, text: submission.message.text,
                identity: submission.identity, count: 1)
            return 1
        }
        guard prior.messageId == submission.message.id,
              prior.text == submission.message.text,
              prior.identity == submission.identity
        else {
            runtime[cardId]?.nativeInboxAttempt = .init(
                messageId: submission.message.id, text: submission.message.text,
                identity: submission.identity, count: 1)
            return 1
        }
        guard prior.count < Self.nativeInboxAttemptLimit else { return 0 }
        runtime[cardId]?.nativeInboxAttempt = .init(
            messageId: prior.messageId, text: prior.text, identity: prior.identity, count: prior.count + 1)
        return prior.count + 1
    }

    /// `false` means a text/state CAS lost to an editor, so the same loop must re-read the new FIFO snapshot.
    private func failNativeInboxSubmission(_ submission: NativeInboxSubmission,
                                           cardId: UUID, token: UInt64) async -> Bool {
        guard ownsNativeInboxSubmission(submission, cardId: cardId, token: token) else { return true }
        do {
            if try await inbox.markFailed(
                cardId: cardId, messageId: submission.message.id, expectedText: submission.message.text
            ) {
                clearNativeInboxAttempt(cardId, submission: submission)
                return true
            }
            return false
        } catch {
            return true
        }
    }

    private func clearNativeInboxAttempt(_ cardId: UUID, submission: NativeInboxSubmission) {
        guard let attempt = runtime[cardId]?.nativeInboxAttempt,
              attempt.messageId == submission.message.id,
              attempt.text == submission.message.text,
              attempt.identity == submission.identity
        else { return }
        runtime[cardId]?.nativeInboxAttempt = nil
    }

    private func nativeInboxBackoff(after attempt: Int) -> Duration {
        attempt == 1 ? .milliseconds(500) : .seconds(1)
    }

    /// Card provenance is immutable row metadata, so add it at delivery time without changing the editable
    /// durable body or the text used to fence retry and acceptance transitions.
    private func nativeInboxPayload(for message: InboxMessage) -> String {
        guard case let .card(id, title)? = message.source else { return message.text }
        let oneLineTitle = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        let shortID = String(id.uuidString.prefix(6)).lowercased()
        return "From Card \(oneLineTitle) (\(shortID)):\n\n\(message.text)"
    }
}
