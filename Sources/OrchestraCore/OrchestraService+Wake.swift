import Foundation

extension OrchestraService {

    // MARK: - F2 wake + merge-watch (C2)

    /// Register a watcher's interest in `children` so each child's conclusion routes into the watcher's
    /// durable inbox (F3, coalesces) and wakes it (F2). Idempotent (unions).
    public func registerWatch(_ watcher: UUID, _ children: Set<UUID>) {
        watchRegistry[watcher, default: []].formUnion(children)
    }

    /// Register a durable watch without a CLI wait process. Returns an already-settled child if one exists;
    /// otherwise the watcher will be notified through its inbox and woken when a child later concludes.
    public func watch(watcher: UUID, refs: [UUID]) async -> Conclusion? {
        let children = Set(refs)
        registerWatch(watcher, children)
        return await firstConcluded(in: children)
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
        let result: Conclusion?
        // Short-circuit on a child that is ALREADY settled-terminal (handles the re-issue race where a
        // child concluded between two `wait` calls). This IS the real-card-state read.
        if let concluded = await firstConcluded(in: children) {
            result = concluded
        } else {
            result = await mergeWatch.awaitConclusion(children)
        }
        if let watcher { releaseActiveWaitProcess(watcher) }
        return result
    }

    private func firstConcluded(in children: Set<UUID>) async -> Conclusion? {
        for id in children {
            if let t = await store.get(id), let kind = isConcluded(t) {
                return Conclusion(cardId: id, ref: t.ref(), kind: kind)
            }
        }
        return nil
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
    func concludeCard(_ id: UUID, _ kind: Conclusion.Kind) async {
        guard let t = await store.get(id) else { return }
        let conc = Conclusion(cardId: id, ref: t.ref(), kind: kind)
        // F3 inbox routing + F2 wake for every registered watcher of this child. If the watcher has a
        // live CLI `orchestra wait`, that process's output is already the conclusion notice, so do not
        // enqueue a duplicate automatic inbox notice. MCP/tool watches have no later process output, so
        // they need the durable inbox notice as their wake context.
        for (watcher, children) in watchRegistry where children.contains(id) {
            if activeWaitProcesses[watcher] == nil {
                try? await inbox.enqueue(watcher, "Card \(t.shortId) concluded (\(kind.rawValue)).")
                await wake(watcher)
            }
            watchRegistry[watcher]?.remove(id)
            if watchRegistry[watcher]?.isEmpty == true { watchRegistry[watcher] = nil }
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
    /// `watcherWillReinvoke` plus the `activeWaitProcesses` gate. A card mid-relaunch (`recovering`) or
    /// archived is never woken.
    ///
    /// REVISIT — `controlChannel` (a real `turn/start` RPC via the Codex app-server) is the agent-agnostic
    /// target that would retire the resume-*relaunch* for wake (deliver a turn without tearing the session
    /// down). It needs the app-server run-mode (drops the TUI for a viewer); until then wake is resume-seed.
    /// See notes/designs/agent-provider-interface.md §8 ("generalize F2 wake").
    func wake(_ id: UUID) async {
        guard let t = await store.get(id), let adapter = try? registry.get(t.agentId),
              !t.archived, !recovering.contains(id) else { return }
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
        guard case .live(.waiting) = t.phase, isResumable(t) else { return }
        if watcherWillReinvoke, activeWaitProcesses[t.id] != nil { return }
        // Claim the relaunch SYNCHRONOUSLY (before the detached hop) so a concurrent wake sees `recovering`
        // and defers — else two resumes race and the second drains an already-emptied inbox and kills the
        // first's freshly-resumed session. `resume` re-inserts (idempotent); its `defer` clears it on finish.
        recovering.insert(t.id)
        _Concurrency.Task { [weak self] in _ = try? await self?.resumeInCard(t.id, source: .daemon) }
    }

    /// A card's conclusion kind from REAL card state, or nil if not settled-terminal. NEVER git.
    /// `.done`/archived = moved to Done; a clean agent exit (`.agentExited`) = `.exited`. A revivable
    /// crash (`sessionVanished`) is deliberately NOT terminal here.
    func isConcluded(_ t: Task) -> Conclusion.Kind? {
        if t.archived || t.phase == .dead(.completed) { return .done }
        if t.phase.kind == .dead, t.deadReason == .agentExited { return .exited }
        return nil
    }

    /// Test / introspection: count of active conclusion subscriptions.
    public func activeWaitSubscriptionCount() async -> Int { await mergeWatch.subscriptionCount() }
}
