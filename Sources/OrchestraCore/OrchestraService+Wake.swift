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
        // F3 inbox routing + F2 wake for every registered watcher of this child. Wake BEFORE clearing the
        // registry entry: `wake` reads `watchRegistry` to tell whether a live `orchestra wait` will already
        // re-invoke the watcher (native) — so while it's still registered here, the native branch correctly
        // no-ops and lets the wait-exit (`mergeWatch.conclude`, below) be the re-invoke, rather than racing
        // it with a resume that would kill the live wait. (A send-keys watcher is nudged either way.)
        for (watcher, children) in watchRegistry where children.contains(id) {
            try? await inbox.enqueue(watcher, "Card \(t.shortId) concluded (\(kind.rawValue)).")
            await wake(watcher)
            watchRegistry[watcher]?.remove(id)
            if watchRegistry[watcher]?.isEmpty == true { watchRegistry[watcher] = nil }
        }
        // Resolve any active `orchestra wait` blocked on this child (per-child, first-wins).
        await mergeWatch.conclude(conc)
    }

    /// F2 — the ONE wake primitive: start a turn on an idle card so it drains its durable inbox (F3).
    /// Every caller funnels through here — `send` (a just-queued message) and the fan-out `concludeCard`
    /// (a child's conclusion). It is idempotent and non-intrusive by construction: it only ever acts on a
    /// card that is IDLE with no turn ALREADY coming, so it can be called freely without risk of
    /// double-driving. WHETHER to act, and the "is a turn already coming?" test, is transport-specific:
    ///   • sendKeys (Codex TUI): fire a fixed content-free nudge, with just-in-time pane detect-and-defer
    ///     (a draft / in-flight turn / dead pane all defer). No daemon-side state test needed.
    ///   • nativeReinvoke (Claude): there is no in-session push, so start a turn by RELAUNCHING via
    ///     resume-seed — UNLESS a turn is already coming (see `resumeSeedWake`).
    /// A card mid-relaunch (`recovering`) or archived is never woken by any transport.
    ///
    /// REVISIT — generalize F2 across agents. The two live transports are stopgaps: `sendKeys` leans on a
    /// fragile TUI pane-scraper (the adapter's `canNudge`, e.g. `CodexComposer`) and `nativeReinvoke`'s
    /// no-wait case leans on a heavy relaunch (`resumeSeedWake`). The agent-agnostic target is
    /// `controlChannel` (a real `turn/start` RPC), which retires both. See
    /// notes/designs/agent-provider-interface.md §8 ("generalize F2 wake").
    func wake(_ id: UUID) async {
        guard let t = await store.get(id), let adapter = try? registry.get(t.agentId),
              !t.archived, !recovering.contains(id) else { return }
        switch adapter.capabilities.wakeTransport {
        case .sendKeys:                  await sendKeysWake(t, adapter)
        case .nativeReinvoke:            await resumeSeedWake(t)
        case .controlChannel, .relaunch: break   // future transports.
        }
    }

    /// nativeReinvoke wake (Claude): start a turn by RESUMING the session with the pending inbox folded
    /// into its opening turn — the proven resume-seed primitive (`resumeInCard`, the same engine `handoff`
    /// uses; delivery rides the durable inbox, never a keystroke into the TUI). Acts ONLY on a genuinely
    /// idle card with nothing already bringing it back — otherwise DEFER (the inbox stays durable for the
    /// turn that IS coming):
    ///   • not `.waiting` → a running turn Stop-drains it; a dead/done card can't turn.
    ///   • watching children (`watchRegistry` non-empty) → its background `orchestra wait` re-invokes it
    ///     when that wait exits; relaunching would KILL the live wait and break the fan-out. (`concludeCard`
    ///     wakes a watcher BEFORE clearing its registry entry, so this sees the still-live wait and no-ops —
    ///     the wait-exit is the watcher's re-invoke, not a resume-seed.)
    ///   • not resumable (never-prompted / no transcript) → nothing to `--resume`; it waits for its first turn.
    /// Fire-and-forget so the caller acks immediately (the inbox is durable regardless; a failed resume just
    /// leaves it for the next turn). No loop: the resumed session runs ONE turn off the drained seed (a
    /// user-prompt-shaped turn that resets the inject guard) and its Stop finds the inbox empty.
    func resumeSeedWake(_ t: Task) async {
        guard t.status == .waiting, watchRegistry[t.id] == nil, isResumable(t) else { return }
        // Claim the relaunch SYNCHRONOUSLY (before the detached hop) so a concurrent wake sees `recovering`
        // and defers — else two resumes race and the second drains an already-emptied inbox and kills the
        // first's freshly-resumed session. `resume` re-inserts (idempotent); its `defer` clears it on finish.
        recovering.insert(t.id)
        _Concurrency.Task { [weak self] in _ = try? await self?.resumeInCard(t.id, source: .daemon) }
    }

    /// The FIXED, content-free wake keystroke for send-keys agents (Codex TUI). Its ONLY job is to
    /// start a turn on an idle composer. Inbox payloads NEVER ride this keystroke — content is delivered
    /// by F3 (the durable inbox / session seed), so this stays a constant and carries no message content.
    public static let sendKeysWakeNudge = "Please continue."

    /// F2 wake for a send-keys agent (Codex TUI): NUDGE-ONLY + detect-and-defer.
    /// Fire the fixed nudge ONLY when the card is idle AND its composer is empty, read just-in-time from
    /// `capture-pane` (this single capture IS the "re-check right before the nudge"; focus is NOT a gate).
    /// A draft, an in-flight turn, an unparseable pane, or a dead session all DEFER — we drop the nudge
    /// and leave the inbox durable; a later event-driven wake / turn-end delivers it. No retry loop here
    /// (that would risk the F3 inject cap). Content is never sent — only `sendKeysWakeNudge`.
    func sendKeysWake(_ t: Task, _ adapter: any Adapter) async {
        let name = sessions.sessionName(t.id)
        guard (try? sessions.isAlive(name)) == true else { return }   // no live TUI → inbox stays durable
        let pane = (try? sessions.capture(name, window: "agent")) ?? ""
        guard adapter.canNudge(pane: pane) else { return }            // adapter-owned pane-gate: draft / busy / unknown → defer
        try? sessions.sendKeys(name, text: Self.sendKeysWakeNudge, window: "agent")
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
