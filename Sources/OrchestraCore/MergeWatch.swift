import Foundation

/// A settled-terminal conclusion for a watched card. Conclusions ride the inbox (F3); artifacts ride git.
public struct Conclusion: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable { case done, exited }
    public let cardId: UUID
    public let ref: String
    public let kind: Kind
    public init(cardId: UUID, ref: String, kind: Kind) {
        self.cardId = cardId; self.ref = ref; self.kind = kind
    }
}

/// Conclusion-watch for the reactive fan-out (F2). A **subscriber, not a detector**: it owns NO
/// detection — no git poll, no file stat, no per-card watcher. `OrchestraService` (the single
/// authority for terminal state) feeds it via `conclude`; MergeWatch just parks a continuation keyed
/// on the watch set and resolves it when one of those cards concludes. This mirrors the existing
/// `resumeWaiters` / `awaitResume` / `resolveResume` pattern in `OrchestraService+Recovery.swift`.
public actor MergeWatch {
    private var waiters: [UUID: (watch: Set<UUID>, cont: CheckedContinuation<Conclusion?, Never>)] = [:]

    public init() {}

    /// Block until ONE of `cardIds` concludes; returns that `Conclusion`, or nil if the task is
    /// cancelled (e.g. the `orchestra wait` process is killed). The caller re-issues on the remaining
    /// children — resolution is per-child, never a barrier on all N.
    public func awaitConclusion(_ cardIds: Set<UUID>) async -> Conclusion? {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Conclusion?, Never>) in
                if _Concurrency.Task.isCancelled { cont.resume(returning: nil); return }
                waiters[token] = (cardIds, cont)
            }
        } onCancel: {
            _Concurrency.Task { await self.cancel(token) }
        }
    }

    /// The authority informs the watcher a card settled terminal. Resolves EVERY waiter whose watch
    /// set contains it (each with its own copy) and drops them.
    public func conclude(_ c: Conclusion) {
        for (token, w) in waiters where w.watch.contains(c.cardId) {
            waiters.removeValue(forKey: token)
            w.cont.resume(returning: c)
        }
    }

    private func cancel(_ token: UUID) {
        if let w = waiters.removeValue(forKey: token) { w.cont.resume(returning: nil) }
    }

    public func waiterCount() -> Int { waiters.count }
}
