import Foundation

extension OrchestraService {

    // MARK: - F2 wake + merge-watch (C2)

    /// Register a watcher's interest in `children` so each child's conclusion routes into the watcher's
    /// durable inbox (F3, coalesces) and wakes it (F2). Idempotent (unions). Writes through to the durable
    /// `watchStore` so the registration survives a daemon restart (carry #4).
    public func registerWatch(_ watcher: UUID, _ children: Set<UUID>) {
        guard !children.isEmpty else { return }
        ensureWatchRegistryLoaded()
        watchRegistry[watcher, default: []].formUnion(children)
        if !watchRegistryLoadFailed { watchStore.save(watchRegistry) }
    }

    /// Lazy-load the durable watch registry into memory on first access (mirrors
    /// `WorktreeRegistry.loadBorrows`). `server.start()` accepts RPCs BEFORE boot's `reloadWatchRegistry`
    /// runs (after the slow phase reconciliation), so a boot-window `wait`/`watch` RPC that mutated the
    /// STILL-EMPTY in-memory map and saved would CLOBBER the on-disk registry, losing every prior watch.
    /// Loading here means the boot-window mutation loads-then-unions-then-saves — the disk map is the merge
    /// and the later `reloadWatchRegistry` sees everything. ALWAYS marks loaded so a torn read never
    /// retry-loads-and-clobbers; on a torn file `watchRegistryLoadFailed` makes mutations skip the save.
    func ensureWatchRegistryLoaded() {
        guard !watchRegistryLoaded else { return }
        watchRegistryLoaded = true
        let (map, loadFailed) = watchStore.load()
        if loadFailed { watchRegistryLoadFailed = true; return }   // torn ⇒ keep in-memory, refuse to persist over
        watchRegistry = map
    }

    /// Reload the persisted watch registry at boot (after phase reconciliation) and deliver conclusions
    /// for any watched child that is ALREADY terminal at reload — a child that concluded while the daemon
    /// was down (or one just marked `dead(.rebootUnrevived)` by `reconcilePhasesAtBoot`) still notifies its
    /// watcher. An unreadable file is ignored (keep zero watchers rather than trust a torn write).
    public func reloadWatchRegistry() async {
        ensureWatchRegistryLoaded()   // a boot-window register may already have loaded+merged; don't reload-clobber
        // Snapshot the (watcher,child) pairs before mutating; `concludeCard` removes the child from the
        // registry (write-through) as it delivers, so a terminal child notifies exactly once.
        for (_, children) in watchRegistry {
            for child in children {
                if let t = await store.get(child), let kind = isConcluded(t) {
                    await concludeCard(child, kind, deadReason: Self.concludedReason(t))
                }
            }
        }
    }

    /// Register a durable watch without a CLI wait process. Returns an already-settled child if one exists;
    /// otherwise the watcher will be notified through its inbox and woken when a child later concludes.
    public func watch(watcher: UUID, refs: [UUID]) async -> Conclusion? {
        let children = Set(refs)
        registerWatch(watcher, children)
        if let concluded = await firstConcluded(in: children) {
            unregisterWatch(watcher, concluded.cardId)   // settled inline → drop it so a re-death can't re-notify
            return concluded
        }
        return nil
    }

    /// CLI wait path: suspend until ONE of `refs` concludes; returns that `Conclusion` (or nil if
    /// cancelled). If `watcher` is set, its inbox coalesces every conclusion (F3) and it is woken per
    /// `wakeTransport` (F2). Reads conclusion from REAL card state — never `git merge-base`.
    public func wait(watcher: UUID?, refs: [UUID]) async -> Conclusion? {
        let children = Set(refs)
        if let watcher {
            registerWatch(watcher, children)
            activeWaitProcesses[watcher, default: 0] += 1
        }
        // SUBSCRIBE BEFORE READING CARD STATE. `transition` writes the terminal phase to the store BEFORE it
        // calls `concludeCard` → `mergeWatch.conclude`, so with the subscription already armed every
        // conclusion is caught by exactly one of the two below: one that lands from here on resolves the
        // subscription; one that landed earlier is already visible in the store to `firstConcluded`.
        //
        // The old order (read, then subscribe) left a gap between them — both are actor hops, so `wait`
        // suspends across them — and a conclusion arriving in that gap reached ZERO subscribers and was
        // dropped. `wait` then parked forever on a continuation nobody would ever resume, with no timeout to
        // save it: an unrecoverable lost wakeup. (`watch`, below, already had this order right.)
        let token = await mergeWatch.subscribe(children)
        let result: Conclusion?
        // Short-circuit on a child that is ALREADY settled-terminal (handles the re-issue race where a
        // child concluded between two `wait` calls). This IS the real-card-state read.
        if let concluded = await firstConcluded(in: children) {
            await mergeWatch.unsubscribe(token)
            // Unregister the settled child (mirror `concludeCard`'s remove) so a later revival→re-death
            // of the same child cannot re-notify this watcher through a stale registry entry.
            if let watcher { unregisterWatch(watcher, concluded.cardId) }
            result = concluded
        } else {
            result = await mergeWatch.awaitConclusion(token: token)
        }
        if let watcher { releaseActiveWaitProcess(watcher) }
        return result
    }

    private func firstConcluded(in children: Set<UUID>) async -> Conclusion? {
        for id in children {
            if let t = await store.get(id), let kind = isConcluded(t) {
                return Conclusion(cardId: id, ref: t.ref(), kind: kind, deadReason: Self.concludedReason(t))
            }
        }
        return nil
    }

    /// The terminal `DeadReason` a settled card carries on its conclusion — the raw reason for an
    /// `.exited`, nil for a `.done` (archived / `.dead(.completed)`). Kept in step with `isConcluded`.
    static func concludedReason(_ t: Task) -> DeadReason? {
        if case .dead(let r) = t.phase, r != .completed { return r }
        return nil
    }

    /// Remove one settled child from a watcher's registry (mirror of `concludeCard`'s `remove(id)` +
    /// empty-set cleanup) — used by the `wait`/`watch` short-circuit so a re-death can't re-notify.
    func unregisterWatch(_ watcher: UUID, _ child: UUID) {
        ensureWatchRegistryLoaded()
        guard watchRegistry[watcher]?.contains(child) == true else { return }   // no-op ⇒ no needless persist
        watchRegistry[watcher]?.remove(child)
        if watchRegistry[watcher]?.isEmpty == true { watchRegistry[watcher] = nil }
        if !watchRegistryLoadFailed { watchStore.save(watchRegistry) }
    }

    private func releaseActiveWaitProcess(_ watcher: UUID) {
        guard let count = activeWaitProcesses[watcher] else { return }
        if count <= 1 { activeWaitProcesses[watcher] = nil }
        else { activeWaitProcesses[watcher] = count - 1 }
    }

    /// The single authority declares a card SETTLED terminal (a conclusion). Called from `archive`
    /// (Done) and a clean agent exit — NOT from a revivable crash. Routes the conclusion into every
    /// watching parent's inbox (F3) + wakes it (F2), then resolves any active `awaitConclusion` (the
    /// native-reinvoke wake: `orchestra wait` returns → its process exits → the harness re-invokes).
    func concludeCard(_ id: UUID, _ kind: Conclusion.Kind, deadReason: DeadReason? = nil) async {
        guard let t = await store.get(id) else { return }
        ensureWatchRegistryLoaded()   // a card concluding in the boot window must see the persisted watchers
        let conc = Conclusion(cardId: id, ref: t.ref(), kind: kind, deadReason: deadReason)
        // F3 inbox routing + F2 wake for every registered watcher of this child. If the watcher has a
        // live CLI `orchestra wait`, that process's output is already the conclusion notice, so do not
        // enqueue a duplicate automatic inbox notice. MCP/tool watches have no later process output, so
        // they need the durable inbox notice as their wake context.
        for (watcher, children) in watchRegistry where children.contains(id) {
            if activeWaitProcesses[watcher] == nil {
                let detail = deadReason.map { " — \($0.rawValue)" } ?? ""
                try? await inbox.enqueue(watcher, "Card \(t.shortId) concluded (\(kind.rawValue)\(detail)).")
                await wake(watcher)
            }
            // Route through `unregisterWatch` so the removal PERSISTS (write-through). A missed inline
            // remove would leave a concluded child registered on disk → duplicate conclusion on the next
            // boot reload (carry #4 / Opus finding 5).
            unregisterWatch(watcher, id)
        }
        // Resolve any active CLI `orchestra wait` subscribed to this child (per-child, first-wins).
        await mergeWatch.conclude(conc)
    }

    /// F2 — the ONE wake primitive: start a turn on an idle card so it drains its durable inbox (F3).
    /// Every caller funnels through here — `send` (a just-queued message) and the fan-out `concludeCard`
    /// (a child's conclusion). It is idempotent and non-intrusive by construction: it only ever acts on a
    /// card that is genuinely IDLE (`.waiting`, from the authoritative telemetry — never a pane scrape) with
    /// no turn already coming, so it can be called freely without risk of double-driving.
    ///
    /// Both live agents wake the SAME way — resume-seed (`resumeInCard`: kill + resume with the pending
    /// inbox folded into the opening turn). The ONLY per-agent difference is whether a *watching* card will
    /// be brought back by something else: Claude's harness re-invokes it when a CLI `orchestra wait`
    /// process exits, so we must NOT relaunch in that one case (it would replace the live wait); MCP/tool
    /// watches and Codex have no such CLI process, so they resume-seed. That single distinction is
    /// `watcherWillReinvoke` plus the `activeWaitProcesses` gate. A card mid-relaunch (`relaunchClaimed`) or
    /// archived is never woken.
    ///
    /// REVISIT — `controlChannel` (a real `turn/start` RPC via the Codex app-server) is the agent-agnostic
    /// target that would retire the resume-*relaunch* for wake (deliver a turn without tearing the session
    /// down). It needs the app-server run-mode (drops the TUI for a viewer); until then wake is resume-seed.
    /// See notes/designs/agent-provider-interface.md §8 ("generalize F2 wake").
    func wake(_ id: UUID) async {
        guard let t = await store.get(id), let adapter = try? registry.get(t.agentId),
              !t.archived, case .live = t.phase, !relaunchClaimed.contains(id) else { return }
        switch adapter.capabilities.wakeTransport {
        case .nativeReinvoke: await resumeSeedWake(t, watcherWillReinvoke: true)   // Claude: harness re-invokes on wait-exit
        case .relaunch:       await resumeSeedWake(t, watcherWillReinvoke: false)  // Codex: no reinvoke — resume even when watching
        case .controlChannel: break                                               // future: turn/start RPC (no relaunch)
        }
    }

    /// Resume-seed wake (Claude no-wait + Codex idle): start a turn by RESUMING the session with the pending
    /// inbox folded into its opening turn — the proven `resumeInCard` primitive (the same engine `handoff`
    /// uses; delivery rides the durable inbox, never a keystroke). Acts ONLY on a genuinely idle card with
    /// nothing already bringing it back — otherwise DEFER (the inbox stays durable for the turn that IS
    /// coming):
    ///   • not `.waiting` → a running turn drains it at its Stop; a dead/done card can't turn.
    ///   • `watcherWillReinvoke` AND an active CLI wait (`activeWaitProcesses` non-empty) → its
    ///     `orchestra wait` process re-invokes it when that wait exits; relaunching would replace the live
    ///     wait and break the fan-out. A durable MCP/tool watch has no CLI process, so it must resume-seed.
    ///     Codex (`.relaunch`) also resumes regardless, since nothing else would bring a watching-but-idle
    ///     card back.
    ///   • not resumable (never-prompted / no transcript) → nothing to resume; it waits for its first turn.
    /// Fire-and-forget so the caller acks immediately (the inbox is durable regardless; a failed resume just
    /// leaves it for the next turn). No loop: the resumed session runs ONE turn off the drained seed and its
    /// Stop finds the inbox empty.
    func resumeSeedWake(_ t: Task, watcherWillReinvoke: Bool) async {
        guard case .live(.waiting) = t.phase, await isResumable(t) else { return }
        if watcherWillReinvoke, activeWaitProcesses[t.id] != nil { return }
        // Claim the relaunch SYNCHRONOUSLY (before the detached hop) so a concurrent wake sees the claim and
        // defers — else two resumes race and the second drains an already-emptied inbox and kills the first's
        // freshly-resumed session. This is the narrow atomic-claim role the deleted `recovering` set played;
        // the reconcile no longer reads it (it gates on phase). Cleared when the resume settles.
        guard !relaunchClaimed.contains(t.id) else { return }
        relaunchClaimed.insert(t.id)
        _Concurrency.Task { [weak self] in
            _ = try? await self?.resumeInCard(t.id, source: .daemon)
            await self?.clearRelaunchClaimed(t.id)
        }
    }

    /// Release a wake/idle-resume's atomic claim once the relaunch settles, then re-drive `wake` for a
    /// message that a `send` queued DURING the claim window (its `wake` deferred at the `relaunchClaimed`
    /// gate and nothing else retries it). `wakeIfPending` re-checks every gate, so it is a no-op unless a
    /// genuinely stranded message remains.
    func clearRelaunchClaimed(_ id: UUID) async {
        relaunchClaimed.remove(id)
        await wakeIfPending(id)
    }

    /// A card's conclusion kind from REAL card state, or nil if not settled-terminal. NEVER git.
    /// ANY `.dead` reason is terminal for conclusion purposes: `.completed` → `.done`; every other dead reason
    /// (incl. `sessionVanished`/`rebootUnrevived`/`resumeFailed`) → `.exited`, so a suspended `wait` resolves on
    /// crash death rather than hanging. `.archived` (and the `archived` Bool bridge) → `.done`.
    func isConcluded(_ t: Task) -> Conclusion.Kind? {
        if case .archived = t.phase { return .done }
        if t.archived { return .done }                 // archive-verb funnel routing is Stage 4; keep the Bool bridge
        if case .dead(let r) = t.phase { return r == .completed ? .done : .exited }
        return nil
    }

    /// Test / introspection: count of active conclusion subscriptions.
    public func activeWaitSubscriptionCount() async -> Int { await mergeWatch.subscriptionCount() }
}
