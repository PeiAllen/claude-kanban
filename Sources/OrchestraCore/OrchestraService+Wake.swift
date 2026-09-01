import Foundation

extension OrchestraService {
    // MARK: - Conclusion subscriptions

    public func registerWatch(_ watcher: UUID, _ children: Set<UUID>) {
        guard !children.isEmpty else { return }
        ensureWatchRegistryLoaded()
        watchRegistry[watcher, default: []].formUnion(children)
        if !watchRegistryLoadFailed { watchStore.save(watchRegistry) }
    }

    func ensureWatchRegistryLoaded() {
        guard !watchRegistryLoaded else { return }
        watchRegistryLoaded = true
        let (map, loadFailed) = watchStore.load()
        if loadFailed { watchRegistryLoadFailed = true; return }
        watchRegistry = map
    }

    public func reloadWatchRegistry() async {
        ensureWatchRegistryLoaded()
        for (_, children) in watchRegistry {
            for child in children {
                if let task = await store.get(child), let kind = isConcluded(task) {
                    await concludeCard(child, kind, deadReason: Self.concludedReason(task))
                }
            }
        }
    }

    public func watch(watcher: UUID, refs: [UUID]) async -> Conclusion? {
        let children = Set(refs)
        registerWatch(watcher, children)
        if let conclusion = await firstConcluded(in: children) {
            unregisterWatch(watcher, conclusion.cardId)
            return conclusion
        }
        return nil
    }

    /// The process-backed `wait` path subscribes before reading durable state, closing the conclusion
    /// race between a terminal write and a later subscription.
    public func wait(watcher: UUID?, refs: [UUID]) async -> Conclusion? {
        let children = Set(refs)
        if let watcher {
            registerWatch(watcher, children)
            if let task = await store.get(watcher) { ensureRuntime(for: task) }
            runtime[watcher]?.activeWaitProcesses += 1
        }
        let token = await mergeWatch.subscribe(children)
        let result: Conclusion?
        if let conclusion = await firstConcluded(in: children) {
            await mergeWatch.unsubscribe(token)
            if let watcher { unregisterWatch(watcher, conclusion.cardId) }
            result = conclusion
        } else {
            result = await mergeWatch.awaitConclusion(token: token)
        }
        if let watcher { releaseActiveWaitProcess(watcher) }
        return result
    }

    private func firstConcluded(in children: Set<UUID>) async -> Conclusion? {
        for id in children {
            if let task = await store.get(id), let kind = isConcluded(task) {
                return Conclusion(cardId: id, ref: task.ref(), kind: kind,
                                  deadReason: Self.concludedReason(task))
            }
        }
        return nil
    }

    static func concludedReason(_ task: Task) -> DeadReason? {
        if case .dead(let reason) = task.phase { return reason }
        return nil
    }

    func unregisterWatch(_ watcher: UUID, _ child: UUID) {
        ensureWatchRegistryLoaded()
        guard watchRegistry[watcher]?.contains(child) == true else { return }
        watchRegistry[watcher]?.remove(child)
        if watchRegistry[watcher]?.isEmpty == true { watchRegistry[watcher] = nil }
        if !watchRegistryLoadFailed { watchStore.save(watchRegistry) }
    }

    private func releaseActiveWaitProcess(_ watcher: UUID) {
        guard let count = runtime[watcher]?.activeWaitProcesses, count > 0 else { return }
        runtime[watcher]?.activeWaitProcesses = count - 1
    }

    /// A settled terminal card resolves direct subscribers and notifies durable non-process watches through
    /// the same enqueue-and-arm path as every other system producer.
    func concludeCard(_ id: UUID, _ kind: Conclusion.Kind, deadReason: DeadReason? = nil) async {
        guard let task = await store.get(id) else { return }
        runtime[id]?.modelOverrideWatch = nil
        ensureWatchRegistryLoaded()
        let conclusion = Conclusion(cardId: id, ref: task.ref(), kind: kind, deadReason: deadReason)
        for (watcher, children) in watchRegistry where children.contains(id) {
            if (runtime[watcher]?.activeWaitProcesses ?? 0) == 0 {
                let detail = deadReason.map { " — \($0.rawValue)" } ?? ""
                _ = try? await enqueueAndArm(
                    watcher,
                    "Card \(task.shortId) concluded (\(kind.rawValue)\(detail)).",
                    source: .orchestra
                )
            }
            unregisterWatch(watcher, id)
        }
        await mergeWatch.conclude(conclusion)
    }

    func isConcluded(_ task: Task) -> Conclusion.Kind? {
        if case .archived = task.phase { return .done }
        if task.archived { return .done }
        if case .dead = task.phase { return .exited }
        return nil
    }

    public func activeWaitSubscriptionCount() async -> Int { await mergeWatch.subscriptionCount() }
}
