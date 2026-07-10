import Foundation

/// The outcome of awaiting a relaunch's inline readiness confirmation. `.superseded` is distinct from
/// `.timedOut` so a relaunch displaced by a newer relaunch for the same card exits quietly (the survivor
/// owns the card) instead of being treated as a failure and marked dead.
public enum ReadinessOutcome: Sendable { case confirmed, timedOut, superseded }

/// How spawn / reopen bring the agent session up once the card is being walked to `.live`. `.blank`
/// starts a fresh session (readiness is the successful `ensure` — the 2.5 sync-spawn readiness stub;
/// dedicated signals arrive in 2.6) and lands on the given run-state. `.resume` relaunches the vendor
/// transcript and confirms readiness via `awaitReadiness` (the SessionStart(resume) hook / relaunch
/// liveness), landing `.waiting`.
public enum LaunchFlavor: Sendable {
    case blank(landing: RunState, prompt: String?)
    case resume(seed: String?)
}

extension OrchestraService {

    /// Daemon-startup recovery pass. For every non-terminal card whose tmux session is not alive
    /// (true for ALL after a reboot; a no-op after a daemon-only crash since the external tmux server
    /// outlived it): resumable cards (agentSessionId + transcript on disk) are revived via a throttled
    /// `resume`; the rest are marked `.dead` (rebootUnrevived). Idempotent.
    public func recoverSessions() async {
        let tasks = await store.all().filter { !$0.phase.isTerminal }
        let grace = config.revivalGraceSeconds
        var jobs: [@Sendable () async -> Void] = []

        // One `tmux list-sessions` instead of an `has-session` per card.
        let aliveNames = Set((try? sessions.list())?.map(\.name) ?? [])

        for t in tasks {
            if aliveNames.contains(sessions.sessionName(t.id)) { continue }   // daemon-crash no-op / still-running
            let id = t.id
            if isResumable(t) {
                jobs.append { _ = try? await self.resume(id, graceSeconds: grace, source: .daemon) }
            } else if t.titleProvisional {
                // Never-prompted (or freshly restarted/cleared): no current-session work to lose and no
                // transcript to resume, so relaunch a blank session rather than killing the card.
                jobs.append { _ = try? await self.restart(id, source: .daemon) }
            } else {
                await markDead(t.id, reason: .rebootUnrevived, detail: nil, source: .daemon)
            }
        }

        guard !jobs.isEmpty else { return }
        let cap = max(1, config.maxConcurrentRevivals)
        // Windowed task group: keep at most `cap` revivals (resume or restart) in flight (start one more
        // each time one finishes). resume is inert until prompted, so the cap only paces process launches.
        await withTaskGroup(of: Void.self) { group in
            var iter = jobs.makeIterator()
            func startNext() {
                guard let job = iter.next() else { return }
                group.addTask { await job() }
            }
            for _ in 0..<cap { startNext() }
            while await group.next() != nil { startNext() }
        }
    }

    /// Revive THIS card's existing session: recreate the tmux session + relaunch `claude --resume`.
    /// Routes through the funnel — `transition(→.relaunching)` (bumps the generation, the atomic claim) →
    /// kill+ensure off-actor → inline readiness confirmation → `transition(→.live)`, epoch-fenced so a
    /// relaunch superseded by a newer one no-ops its finalize. On failure → `.dead` (resumeFailed) + throw.
    @discardableResult
    public func resume(_ id: UUID, graceSeconds: Int? = nil, seed: String? = nil,
                       source: ActivitySource = .daemon) async throws -> Task {
        let task = try await require(id)
        let adapter = try registry.get(task.agentId)
        let grace = graceSeconds ?? config.revivalGraceSeconds

        // Enter `.relaunching`: bumps `sessionEpoch` (the generation claim — a stale SessionEnd / liveness
        // signal from the torn-down session is fenced by epoch, and the reconcile skips `.relaunching`) and
        // clears dead metadata atomically. The `relaunching → relaunching` supersede self-edge is legal, so
        // a newer relaunch bumps again and this attempt's finalize is later dropped by the epoch fence.
        _ = await transition(id, to: .relaunching, mutate: { $0.deadReason = nil; $0.deadDetail = nil })
        guard let claimed = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        let epoch = claimed.sessionEpoch
        // Start clean: drop any confirmation left over from a prior attempt so only THIS relaunch's
        // readiness signal can confirm it.
        pendingReadiness.remove(id)

        // Pre-check: must have a tracked id whose transcript still exists.
        let trustDecision = await resolveTrust(origin: task.origin, cwd: task.cwd, repo: task.repo)
        let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: task.model.id,
                                 sessionId: task.agentSessionId, name: task.title, orchestraBin: orchestraBin,
                                 trustCwd: trustDecision == .trusted, seed: seed)
        guard let sid = task.agentSessionId,
              let info = adapter.sessionInfo(ctx, current: sid, prior: task.priorSessionIds),
              let tp = info.transcriptPath, FileManager.default.fileExists(atPath: tp),
              let argv = adapter.resume(ctx) else {
            return try await failResume(id, detail: "transcript gone", source: source)
        }

        // Recreate the session off the actor so a mass revival overlaps (and report() stays serviced).
        try? adapter.prepareToLaunch(ctx)
        let env = withEpoch(adapter.env, epoch)   // stamp the current generation into the session
        do {
            try await offActor { [sessions] in
                _ = try sessions.kill(sessions.sessionName(id))
                _ = try sessions.ensure(claimed, argv: argv, env: env)
            }
        } catch {
            return try await failResume(id, detail: "\(error)", source: source)
        }

        // Confirm the relaunch is alive (capability-gated). `.superseded` ⇒ a newer resume(id) took over
        // this card; exit quietly WITHOUT markDead or a phase write — the surviving relaunch owns the
        // outcome (its own transition(→.live) at the current epoch finalizes it).
        switch await confirmReadiness(id, adapter: adapter, graceSeconds: grace) {
        case .confirmed:  break
        case .timedOut:   return try await failResume(id, detail: "no SessionStart callback in \(grace)s", source: source)
        case .superseded: return task
        }

        // Reach live — epoch-fenced (`observedEpoch: epoch`) so a superseded attempt's finalize is a no-op.
        _ = await transition(id, to: .live(.waiting(.humanTurn)), observedEpoch: epoch)
        guard let updated = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        emitActivity(.recovered, updated, source, "resumed “\(updated.title)”")
        return updated
    }

    /// F1 (C3) — resume THIS card into a fresh process with CLEAN context, seeded with the handoff/fork
    /// context AND its pending inbox (folded into one seed delivered as the resumed session's opening
    /// turn). This is **resume, not a blank restart**: `agentSessionId` is KEPT, so the vendor transcript
    /// carries forward and the seed adds new context to a continued session. The inbox "folds into the
    /// seed" (design §8 F1) — drained BEFORE resume so the queued messages ride the opening turn, and are
    /// not double-delivered by a later Stop-drain. This is F1 (handoff) AND the idle-wake path for a
    /// `.relaunch` agent (`resumeSeedWake`). Backs D1's `handoff` Command.
    @discardableResult
    public func resumeInCard(_ id: UUID, seed: String? = nil, graceSeconds: Int? = nil,
                             source: ActivitySource = .daemon) async throws -> Task {
        let drained = (try? await inbox.drain(id)) ?? []
        let folded = HandoffSeed.fold(handoff: seed, inbox: drained)
        return try await resume(id, graceSeconds: graceSeconds, seed: folded, source: source)
    }

    /// Start a NEW blank session for a (dead or live) card in the SAME worktree. Fresh id, no prompt
    /// re-handed; status → waiting, titleProvisional → true. Never touches worktree contents. Routes
    /// through the funnel — `transition(→.relaunching, mutate:)` carries the real persist block (fresh id,
    /// rolled prior ids, provisional, cleared dead/desc) atomically with the phase write.
    @discardableResult
    public func restart(_ id: UUID, source: ActivitySource = .daemon) async throws -> Task {
        let task = try await require(id)
        let adapter = try registry.get(task.agentId)

        // Same capability gate as spawn: only a `.seeded` agent mints a fresh id on restart.
        let freshId: String?
        switch adapter.capabilities.sessionId {
        case .seeded:     freshId = adapter.newSessionId()
        case .discovered: freshId = nil
        }
        var priorIds = task.priorSessionIds
        if let old = task.agentSessionId, !old.isEmpty { priorIds.append(old) }
        let prior = priorIds

        // Enter `.relaunching` with the REAL persist block applied atomically (was a separate store.update):
        // the launch below uses the new id, and a stale signal is epoch-fenced by the bump.
        _ = await transition(id, to: .relaunching, mutate: {
            $0.agentSessionId = freshId
            $0.priorSessionIds = prior
            $0.titleProvisional = true
            $0.deadReason = nil
            $0.deadDetail = nil
            $0.desc = ""
        })
        guard let claimed = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        let epoch = claimed.sessionEpoch

        let trustDecision = await resolveTrust(origin: task.origin, cwd: task.cwd, repo: task.repo)
        let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: task.model.id,
                                 startIn: task.startIn, sessionId: freshId, prompt: nil,
                                 name: task.title, orchestraBin: orchestraBin,
                                 trustCwd: trustDecision == .trusted)
        try? adapter.prepareToLaunch(ctx)
        let env = withEpoch(adapter.env, epoch)   // stamp the current generation
        let startArgv = adapter.start(ctx)
        do {
            try await offActor { [sessions] in
                _ = try sessions.kill(sessions.sessionName(id))
                _ = try sessions.ensure(claimed, argv: startArgv, env: env)
            }
        } catch {
            return try await failResume(id, detail: "\(error)", source: source)
        }
        // Blank launch → readiness is the successful `ensure`. Reach live, epoch-fenced.
        _ = await transition(id, to: .live(.waiting(.humanTurn)), observedEpoch: epoch)
        guard let updated = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        emitActivity(.recovered, updated, source, "new session “\(updated.title)”")
        return updated
    }

    /// Reopen an archived (Done) card: recreate the run dir the archive reclaimed, put the card back on
    /// the board (keeps its column), and bring the agent back — `resume` its transcript when resumable,
    /// else a fresh blank launch in the recreated tree. Idempotent: a non-archived card is returned as-is.
    ///
    /// Legal phase path `archived → creatingWorktree → launching → live` (§P1). The archive verb is still
    /// Bool-bridged in Stage 2 (an archived card's `phase` is `.dead(.completed)`), so we first normalize
    /// it to `.archived(complete)` — the funnel's `dead → archivedComplete` edge — so the `archived →
    /// creatingWorktree` reopen edge applies. Does NOT call `resume()`/`restart()` (they enter via
    /// `.relaunching`, illegal from `.creatingWorktree`); the launch+confirm step is shared via
    /// `launchAndConfirm`.
    @discardableResult
    public func reopen(_ id: UUID, source: ActivitySource = .daemon) async throws -> Task {
        let t = try await require(id)
        guard t.archived else { return t }
        let adapter = try registry.get(t.agentId)
        let resumable = isResumable(t)

        // Normalize the Bool-bridged archived phase to a real `.archived(_)` so the reopen edge applies.
        if t.phase.kind != .archivedComplete, t.phase.kind != .archivedPending {
            _ = await transition(id, to: .archived(teardownComplete: true))
        }

        // Enter `.creatingWorktree` (bumps the generation), clearing the archived Bool + dead metadata.
        // The blank path also mints a fresh id / rolls prior ids / resets provisional+desc (restart
        // semantics); the resume path keeps the id so the transcript carries forward.
        if resumable {
            _ = await transition(id, to: .creatingWorktree, mutate: {
                $0.archived = false; $0.deadReason = nil; $0.deadDetail = nil
            })
        } else {
            let freshId: String?
            switch adapter.capabilities.sessionId {
            case .seeded:     freshId = adapter.newSessionId()
            case .discovered: freshId = nil
            }
            var priorIds = t.priorSessionIds
            if let old = t.agentSessionId, !old.isEmpty { priorIds.append(old) }
            let prior = priorIds
            _ = await transition(id, to: .creatingWorktree, mutate: {
                $0.archived = false
                $0.agentSessionId = freshId
                $0.priorSessionIds = prior
                $0.titleProvisional = true
                $0.desc = ""
                $0.deadReason = nil
                $0.deadDetail = nil
            })
        }
        if let reopening = await store.get(id) {
            emitActivity(.recovered, reopening, source, "Reopened “\(reopening.title)”")
        }

        // Give the resumed agent its cwd back — archive removed it (branch kept for .worktree cards).
        switch t.origin {
        case .worktree:
            _ = try await worktrees.ensure(repo: t.repo, branch: t.branch, cardId: t.id)
        case .scratch:
            try? FileManager.default.createDirectory(atPath: t.cwd, withIntermediateDirectories: true)
        case .borrowed:
            break   // never removed on archive
        }

        // cwd ready → launching → launch+confirm → live.
        let trustDecision = await resolveTrust(origin: t.origin, cwd: t.cwd, repo: t.repo)
        do {
            let flavor: LaunchFlavor = resumable ? .resume(seed: nil)
                                                 : .blank(landing: .waiting(.humanTurn), prompt: nil)
            try await launchAndConfirm(id, flavor: flavor, trustCwd: trustDecision == .trusted)
        } catch {
            await transition(id, to: .dead(.spawnFailed), mutate: { $0.deadDetail = "\(error)" })
            throw error
        }
        guard let live = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        return live
    }

    /// Shared launching→live step for spawn + reopen. The caller has the card in `.creatingWorktree`; this
    /// resolves the launch inputs (still `.creatingWorktree` — reconcile-safe), then enters `.launching`
    /// and brings the session up with NO `await` between the `.launching` write and the synchronous
    /// `ensure`, so a concurrent liveness poll can never observe a launching card whose session doesn't
    /// exist yet. Throws on a launch/confirm failure so the caller routes the card to `.dead(.spawnFailed)`.
    /// NOT used by resume/restart (they walk the `.relaunching` edge).
    func launchAndConfirm(_ id: UUID, flavor: LaunchFlavor, trustCwd: Bool,
                          graceSeconds: Int? = nil) async throws {
        let task = try await require(id)
        let adapter = try registry.get(task.agentId)
        let env = withEpoch(adapter.env, task.sessionEpoch)   // stamp the current generation

        switch flavor {
        case .blank(let landing, let prompt):
            let grace = graceSeconds ?? config.revivalGraceSeconds
            pendingReadiness.remove(id)   // start clean so only THIS launch's signal can confirm it
            let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: task.model.id, startIn: task.startIn,
                                     sessionId: task.agentSessionId, prompt: prompt, name: task.title,
                                     orchestraBin: orchestraBin, access: task.access, trustCwd: trustCwd)
            try? adapter.prepareToLaunch(ctx)
            let argv = adapter.start(ctx)
            // Enter launching, then ensure with NO intervening suspension (see the launching-window invariant).
            _ = await transition(id, to: .launching)
            try sessions.ensure(task, argv: argv, env: env)
            // Capability-gated launch readiness (2.6): `.relaunchLiveness` takes the successful `ensure` as
            // the confirmation and lands immediately; `.sessionStartHook`/`.rolloutMeta` inline-await the
            // agent's own ready signal (Claude SessionStart(startup) / Codex rollout `session_meta`), with
            // the N=3 liveness-tick fallback as the safety net — so the signal genuinely drives launching→
            // live rather than firing after the card is already live. Timeout fails the spawn (→ .dead);
            // superseded means a newer bring-up owns the card, so leave the phase to that survivor.
            switch await confirmReadiness(id, adapter: adapter, graceSeconds: grace) {
            case .confirmed:  _ = await transition(id, to: .live(landing))
            case .timedOut:   throw OrchestraError.spawnFailed("no launch-ready signal in \(grace)s")
            case .superseded: return
            }

        case .resume(let seed):
            let grace = graceSeconds ?? config.revivalGraceSeconds
            pendingReadiness.remove(id)
            let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: task.model.id,
                                     sessionId: task.agentSessionId, name: task.title, orchestraBin: orchestraBin,
                                     trustCwd: trustCwd, seed: seed)
            guard let sid = task.agentSessionId,
                  let info = adapter.sessionInfo(ctx, current: sid, prior: task.priorSessionIds),
                  let tp = info.transcriptPath, FileManager.default.fileExists(atPath: tp),
                  let argv = adapter.resume(ctx) else {
                throw OrchestraError.resumeFailed("transcript gone")
            }
            try? adapter.prepareToLaunch(ctx)
            _ = await transition(id, to: .launching)
            _ = try? sessions.kill(sessions.sessionName(id))
            try sessions.ensure(task, argv: argv, env: env)
            switch await confirmReadiness(id, adapter: adapter, graceSeconds: grace) {
            case .confirmed:  _ = await transition(id, to: .live(.waiting(.humanTurn)))
            case .timedOut:   throw OrchestraError.resumeFailed("no SessionStart callback in \(grace)s")
            case .superseded: return   // a newer relaunch owns the card
            }
        }
    }

    /// Confirm a being-born card (launch OR relaunch) is alive — HOW depends on the agent (capability, never
    /// identity). `.sessionStartHook` waits for the agent's own SessionStart telemetry (Claude), or times
    /// out. `.rolloutMeta` ALSO waits (Codex): a fresh launch's rollout `session_meta` line resolves the
    /// waiter via the tail observer; a `codex resume` writes no rollout, so the N=3 `launchReadyTicks`
    /// fallback resolves it within the grace — either way it stays ON the readiness gate (never immediate,
    /// which would leave no waiter and bypass the gate). `.relaunchLiveness` takes the successful `ensure`
    /// as the confirmation because the agent emits no marker at all, so it must NOT wait for one.
    func confirmReadiness(_ id: UUID, adapter: any Adapter, graceSeconds: Int) async -> ReadinessOutcome {
        switch adapter.capabilities.readinessConfirmation {
        case .sessionStartHook, .rolloutMeta: return await awaitReadiness(id, graceSeconds: graceSeconds)
        case .relaunchLiveness:                return .confirmed
        }
    }

    /// Background poll's continuous liveness reconcile (safety net when no SessionEnd fires). Phase-gated:
    /// the being-born phases (`.creatingWorktree`, `.relaunching`, `.launching`) are NEVER killed here — their
    /// session is legitimately absent mid-bring-up and each is owned by a SYNCHRONOUS launch/relaunch that
    /// handles its own readiness + spawnFailed timeout; killing them would race the owner's own
    /// `transition`→`ensure` window and false-kill a live spawn. Only a `.live` card whose session vanished is
    /// concluded (crashed → `.dead(.sessionVanished)`). Terminal cards are excluded outright. Deaths that DO
    /// fire route through the funnel (`markDead`) so they conclude.
    public func reconcileLiveness() async {
        let tasks = await store.all()
        // One `tmux list-sessions` per poll tick, not one `has-session` per card.
        let aliveNames = Set((try? sessions.list())?.map(\.name) ?? [])
        for t in tasks where !t.phase.isTerminal {
            let alive = aliveNames.contains(sessions.sessionName(t.id))
            switch t.phase.kind {
            case .creatingWorktree:
                launchReadyTicks[t.id] = nil   // not yet awaiting readiness — nothing to tick
                continue   // being born — the session is legitimately not up yet
            case .relaunching:
                // A relaunch's session IS up once `ensure` returned (resume/restart bring it up off-actor),
                // but the phase stays `.relaunching` until the inline waiter resolves. If the session is
                // live and a waiter is still pending, tick the N=3 fallback (covers Codex `codex resume`
                // with no rollout, a missed hook). Never markDead a relaunching card (its absence is legit).
                if alive { tickLaunchReady(t.id) } else { launchReadyTicks[t.id] = nil }
                continue
            case .launching:
                // Being born under a SYNCHRONOUS launch that owns readiness + the spawnFailed timeout (launchAndConfirm).
                // Mirror `.relaunching`: tick the N=3 fallback while a waiter is pending; NEVER markDead here — killing a
                // launching card races the launch's own `transition(.launching)`→`ensure` window and would false-kill a
                // live spawn. (Stage-4's reconciler will own launching timeouts via phaseChangedAt for the non-blocking path.)
                if alive { tickLaunchReady(t.id) } else { launchReadyTicks[t.id] = nil }
                continue
            case .live:
                launchReadyTicks[t.id] = nil   // reached live — reset the being-born counter
                if !alive {
                    await markDead(t.id, reason: .sessionVanished, detail: nil, source: .daemon)
                }
            case .dead, .archivedPending, .archivedComplete:
                launchReadyTicks[t.id] = nil
                continue   // terminal — excluded by `isTerminal`, but keep the switch exhaustive
            }
        }
    }

    /// N=3 readiness fallback tick (see `launchReadyTicks`). Only counts while an inline waiter is actually
    /// pending; at the threshold it resolves that waiter so the verb reaches `.live` before the await's grace
    /// timeout would fail it. No pending waiter → reset (e.g. a `.relaunchLiveness` restart that never awaits,
    /// or the instant after the waiter already resolved).
    private func tickLaunchReady(_ id: UUID) {
        guard readinessWaiters[id] != nil else { launchReadyTicks[id] = nil; return }
        let n = (launchReadyTicks[id] ?? 0) + 1
        if n >= launchReadyTickThreshold {
            launchReadyTicks[id] = nil
            resolveReadiness(id, true)
        } else {
            launchReadyTicks[id] = n
        }
    }

    // MARK: - helpers

    /// Whether a card can be resumed. Capability-gated (design §5): resumability is an adapter answer
    /// keyed on `capabilities.sessionId` + `sessionInfo`, NOT a hardcoded `~/.claude` transcript stat in
    /// core. Both current variants require a stored session id and the adapter's own state path to be
    /// present on disk; a discovered agent with no id short-circuits.
    func isResumable(_ t: Task) -> Bool {
        guard let adapter = try? registry.get(t.agentId) else { return false }
        switch adapter.capabilities.sessionId {
        case .seeded, .discovered:
            guard let sid = t.agentSessionId, !sid.isEmpty else { return false }
            let ctx = AdapterContext(cwd: t.cwd, sessionId: sid, name: t.title, orchestraBin: orchestraBin)
            guard let statePath = adapter.sessionInfo(ctx, current: sid, prior: t.priorSessionIds)?.transcriptPath
            else { return false }
            return FileManager.default.fileExists(atPath: statePath)
        }
    }

    @discardableResult
    private func failResume(_ id: UUID, detail: String, source: ActivitySource) async throws -> Task {
        await markDead(id, reason: .resumeFailed, detail: detail, source: source)
        throw OrchestraError.resumeFailed(detail)
    }

    /// Deliver an inbox that a `send`/inbox-add queued WHILE this card was mid-relaunch — its `wake` no-op'd
    /// (the `relaunchClaimed` gate / a non-`.live` phase) and, uniquely, nothing else retries it (a running
    /// card's Stop-drain, a not-yet-resumable card's next turn, and a watching parent's reinvoke all cover
    /// their own gates). Called once the relaunch settles (`clearRelaunchClaimed`). `wake` re-checks every
    /// gate, so this is a no-op unless there is a genuinely stranded message, and it self-terminates: the
    /// resumed turn drains the inbox.
    func wakeIfPending(_ id: UUID) async {
        guard let t = await store.get(id), case .live(.waiting) = t.phase, !t.archived,
              !(await inbox.peek(id)).isEmpty else { return }
        await wake(id)
    }

    /// The single terminal-death classifier. Routes through the funnel so a non-terminal → terminal death
    /// fires `concludeCard` (bug-#2 fix — a suspended `wait` resolves on a crash/reboot/resume-fail death,
    /// not just a clean exit). Callers pass a DELIBERATE classification (aliveNames miss / a fresh liveness
    /// probe / a definitive resume failure), so this transitions with `observedEpoch: nil` — exempt from
    /// the nil-epoch kill-probe gate (which lives at the inbound-SessionEnd signal site).
    func markDead(_ id: UUID, reason: DeadReason, detail: String?, source: ActivitySource) async {
        let result = await transition(id, to: .dead(reason), mutate: {
            $0.deadReason = reason; $0.deadDetail = detail
        })
        guard result == .applied, let updated = await store.get(id) else { return }
        emitActivity(.dead, updated, source, "session lost (\(reason.rawValue))")
    }

    private func awaitReadiness(_ id: UUID, graceSeconds: Int) async -> ReadinessOutcome {
        // The confirmation may already have landed while we were relaunching off-actor (see
        // `pendingReadiness`). Consume it synchronously — before registering a waiter — so an early callback
        // confirms instantly instead of waiting out (or timing out) the grace. This block and the
        // registration below run without an intervening `await`, so no callback can slip between the check
        // and the registration on this serialized actor.
        if pendingReadiness.remove(id) != nil { return .confirmed }
        readinessTokenSeq &+= 1
        let token = readinessTokenSeq
        return await withCheckedContinuation { (cont: CheckedContinuation<ReadinessOutcome, Never>) in
            // A second relaunch for this id must NEVER leak the earlier continuation: resolve the displaced
            // waiter `.superseded` (the newer relaunch now owns the session). Without this,
            // `readinessWaiters[id] = …` would drop the old continuation unresumed → that relaunch hangs
            // forever → the idle card can never be woken again.
            if let old = readinessWaiters[id] { old.cont.resume(returning: .superseded) }
            readinessWaiters[id] = (token, cont)
            let grace = max(0, graceSeconds)
            _Concurrency.Task { [weak self] in
                try? await _Concurrency.Task.sleep(for: .seconds(grace))
                await self?.timeoutReadiness(id, token: token)
            }
        }
    }

    func resolveReadiness(_ id: UUID, _ ok: Bool) {
        if let w = readinessWaiters.removeValue(forKey: id) {
            w.cont.resume(returning: ok ? .confirmed : .timedOut)
        } else if ok {
            // No waiter yet: `awaitReadiness` hasn't registered (the relaunch is still bringing the session
            // up off-actor). Remember this confirmation so the waiter picks it up rather than losing it.
            pendingReadiness.insert(id)
        }
    }

    /// Time out ONLY the waiter this timer was scheduled for. A newer relaunch that superseded it (or a
    /// confirmation that already resolved it) advanced the slot's token, so a stale timer is a no-op —
    /// it must never resolve an unrelated, still-pending waiter.
    private func timeoutReadiness(_ id: UUID, token: UInt64) {
        guard let w = readinessWaiters[id], w.token == token else { return }
        readinessWaiters.removeValue(forKey: id)
        w.cont.resume(returning: .timedOut)
    }

    /// Run a synchronous (possibly slow: git/tmux/process-launch) closure off the actor so the actor
    /// keeps servicing `report` and parallel revivals genuinely overlap.
    nonisolated func offActor<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { cont.resume(with: Result { try work() }) }
        }
    }
}
