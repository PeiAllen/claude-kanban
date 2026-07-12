import Foundation

/// A settled-terminal conclusion for a watched card. Conclusions ride the inbox (F3); artifacts ride git.
public struct Conclusion: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable { case done, exited }
    public let cardId: UUID
    public let ref: String
    public let kind: Kind
    /// The terminal `DeadReason` that settled the card — carried so `wait`/`watch` resolve on EVERY
    /// terminal reason (the durable bug-#2 fix), not just `.agentExited`. `nil` for archived / `.done`.
    public let deadReason: DeadReason?
    public init(cardId: UUID, ref: String, kind: Kind, deadReason: DeadReason? = nil) {
        self.cardId = cardId; self.ref = ref; self.kind = kind; self.deadReason = deadReason
    }
}

/// Conclusion-watch for the reactive fan-out (F2). A **subscriber, not a detector**: it owns NO
/// detection — no git poll, no file stat, no per-card watcher. `OrchestraService` (the single
/// authority for terminal state) feeds it via `conclude`; MergeWatch just records a continuation keyed
/// on the watch set and resolves it when one of those cards concludes.
///
/// Subscribing is TWO-PHASE (`subscribe` → `awaitConclusion(token:)`) because `wait` must read card state
/// between the two: it registers first, then reads. A one-shot subscribe-and-park forced the opposite order
/// (read, then subscribe), and a conclusion landing in that gap reached ZERO subscribers and was dropped —
/// `wait` then parked forever on a continuation nobody would ever resume. `wait` has no timeout, so that
/// lost wakeup is unrecoverable. The `delivered` slot state is what makes the two phases safe: a conclusion
/// that arrives while the caller is still on its way to `awaitConclusion` is RETAINED, not dropped.
public actor MergeWatch {
    private enum Slot {
        case armed(Set<UUID>)                                        // subscribed; caller not parked yet
        case delivered(Conclusion)                                   // concluded before the caller parked
        case parked(Set<UUID>, CheckedContinuation<Conclusion?, Never>)
    }
    private var slots: [UUID: Slot] = [:]

    public init() {}

    /// Arm a subscription and return its token. A caller that must read card state (`wait`) subscribes
    /// through this BEFORE the read, so no conclusion can slip through the gap between the two.
    public func subscribe(_ cardIds: Set<UUID>) -> UUID {
        let token = UUID()
        slots[token] = .armed(cardIds)
        return token
    }

    /// Drop an armed subscription the caller no longer needs (it resolved from card state instead).
    public func unsubscribe(_ token: UUID) {
        if case .parked(_, let cont)? = slots[token] { cont.resume(returning: nil) }
        slots[token] = nil
    }

    /// Suspend on an armed subscription until one of its cards concludes; returns that `Conclusion`, or nil
    /// if the task is cancelled (e.g. the `orchestra wait` process is killed) or the token was dropped. A
    /// conclusion that already landed on the slot returns IMMEDIATELY — the lost wakeup that hung `wait`.
    /// One park per token: a token is `armed` exactly once and consumed by the first `awaitConclusion`.
    /// Parking a second caller on the same token would strand one of the two continuations, so it is a
    /// programmer error — it returns nil rather than displacing the parked waiter. (No in-tree caller does
    /// this: `wait` either `unsubscribe`s its token or parks on it exactly once.)
    public func awaitConclusion(token: UUID) async -> Conclusion? {
        guard let slot = slots[token] else { return nil }
        if case .delivered(let c) = slot { slots[token] = nil; return c }
        guard case .armed(let ids) = slot else { return nil }   // already parked ⇒ don't displace it
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Conclusion?, Never>) in
                if _Concurrency.Task.isCancelled { slots[token] = nil; cont.resume(returning: nil); return }
                if case .delivered(let c)? = slots[token] { slots[token] = nil; cont.resume(returning: c); return }
                slots[token] = .parked(ids, cont)
            }
        } onCancel: {
            _Concurrency.Task { await self.cancel(token) }
        }
    }

    /// Subscribe + suspend in one step, for a caller with no card-state read to interleave.
    public func awaitConclusion(_ cardIds: Set<UUID>) async -> Conclusion? {
        await awaitConclusion(token: subscribe(cardIds))
    }

    /// The authority informs the watcher a card settled terminal. Resolves EVERY subscription whose watch
    /// set contains it (each with its own copy); a subscription that is armed-but-not-yet-parked RETAINS the
    /// conclusion so its caller picks it up the moment it parks.
    public func conclude(_ c: Conclusion) {
        for (token, slot) in slots {
            switch slot {
            case .armed(let ids) where ids.contains(c.cardId):
                slots[token] = .delivered(c)
            case .parked(let ids, let cont) where ids.contains(c.cardId):
                slots[token] = nil
                cont.resume(returning: c)
            default:
                break
            }
        }
    }

    private func cancel(_ token: UUID) {
        if case .parked(_, let cont)? = slots[token] { cont.resume(returning: nil) }
        slots[token] = nil
    }

    /// Live subscriptions — `armed` (registered, not yet parked), `parked`, and `delivered`-but-unconsumed.
    /// NB this is no longer "parked waiters": a `wait` that has subscribed and is still reading card state
    /// counts here too. Tests poll it to know a waiter is registered, which is exactly what it now means.
    public func subscriptionCount() -> Int { slots.count }
}
