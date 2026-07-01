import Foundation

extension OrchestraService {

    // MARK: - F2 wake + merge-watch (C2)

    /// Register a watcher's interest in `children` so each child's conclusion routes into the watcher's
    /// durable inbox (F3, coalesces) and wakes it (F2). Idempotent (unions).
    public func registerWatch(_ watcher: UUID, _ children: Set<UUID>) {
        watchRegistry[watcher, default: []].formUnion(children)
    }

    /// Block until ONE of `refs` concludes; returns that `Conclusion` (or nil if cancelled). Backs
    /// `orchestra wait`. If `watcher` is set, its inbox coalesces every conclusion (F3) and it is woken
    /// per `wakeTransport` (F2). Reads conclusion from REAL card state — never `git merge-base`.
    public func wait(watcher: UUID?, refs: [UUID]) async -> Conclusion? {
        let children = Set(refs)
        if let watcher { registerWatch(watcher, children) }
        // Short-circuit on a child that is ALREADY settled-terminal (handles the re-issue race where a
        // child concluded between two `wait` calls). This IS the real-card-state read.
        for id in children {
            if let t = await store.get(id), let kind = isConcluded(t) {
                return Conclusion(cardId: id, ref: t.ref(), kind: kind)
            }
        }
        return await mergeWatch.awaitConclusion(children)
    }

    /// The single authority declares a card SETTLED terminal (a conclusion). Called from `archive`
    /// (Done) and a clean agent exit — NOT from a revivable crash. Routes the conclusion into every
    /// watching parent's inbox (F3) + wakes it (F2), then resolves any blocked `awaitConclusion` (the
    /// native-reinvoke wake: `orchestra wait` returns → its process exits → the harness re-invokes).
    func concludeCard(_ id: UUID, _ kind: Conclusion.Kind) async {
        guard let t = await store.get(id) else { return }
        let conc = Conclusion(cardId: id, ref: t.ref(), kind: kind)
        // F3 inbox routing + F2 wake for every registered watcher of this child.
        for (watcher, children) in watchRegistry where children.contains(id) {
            try? await inbox.enqueue(watcher, "Card \(t.shortId) concluded (\(kind.rawValue)).")
            watchRegistry[watcher]?.remove(id)
            if watchRegistry[watcher]?.isEmpty == true { watchRegistry[watcher] = nil }
            await wake(watcher)
        }
        // Resolve any active `orchestra wait` blocked on this child (per-child, first-wins).
        await mergeWatch.conclude(conc)
    }

    /// Trigger a turn on an idle card (F2), dispatched on the adapter's `wakeTransport`.
    func wake(_ id: UUID) async {
        guard let t = await store.get(id), let adapter = try? registry.get(t.agentId) else { return }
        switch adapter.capabilities.wakeTransport {
        case .nativeReinvoke:
            // No daemon push: the harness re-invokes when the card's background `orchestra wait` exits,
            // and that exit is driven by `mergeWatch.conclude` resolving the blocked wait. Nothing to
            // send. (An idle Claude card with no background wait stays inbox-durable until it next runs.)
            break
        case .sendKeys:
            break   // Codex send-keys nudge + detect-and-defer — C4 (deferred; nudge only, no content).
        case .controlChannel, .relaunch:
            break   // future transports.
        }
    }

    /// A card's conclusion kind from REAL card state, or nil if not settled-terminal. NEVER git.
    /// `.done`/archived = moved to Done; a clean agent exit (`.agentExited`) = `.exited`. A revivable
    /// crash (`sessionVanished`) is deliberately NOT terminal here.
    func isConcluded(_ t: Task) -> Conclusion.Kind? {
        if t.archived || t.status == .done { return .done }
        if t.status == .dead, t.deadReason == .agentExited { return .exited }
        return nil
    }

    /// Test / introspection: count of parked conclusion waiters.
    public func mergeWaiterCount() async -> Int { await mergeWatch.waiterCount() }
}
