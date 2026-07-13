import Foundation

/// Stage-4 reconciler (PR4b Task 2): the per-tick driving discipline that STEPS transitional cards toward
/// their target phase, enforces `phaseChangedAt` launch timeouts, sweeps orphan sessions (after a fresh
/// epoch-stamped probe), adopts sessions only on epoch-identity match, and backs off a failing step — plus
/// the boot phase-reconciliation pass (`reconcilePhasesAtBoot`, which folds the old `recoverSessions`).
///
/// Verbs are still SYNCHRONOUS this stage (spawn/archive walk their phases inline), so for a normally
/// spawned live card the stepping arm is a no-op; the reconciler earns its keep on cards a crash stranded
/// mid-transition and on the non-blocking verbs of Task 3.
extension OrchestraService {

    /// Test seam: override the stepper for a `Phase.Kind` (e.g. a throwing stepper for the backoff test).
    func setStepper(_ stepper: any PhaseStepper, for kind: Phase.Kind) { steppers[kind] = stepper }

    /// Test seam: pin the step-backoff delay so the backoff test's window is load-proof (see the field's doc).
    func setStepBackoff(_ seconds: Double) { stepBackoffOverrideSeconds = seconds }

    /// Test/introspection: the worktree registry's conservative-mode flag (post-corrupt-boot).
    func worktreeConservativeMode() async -> Bool { await worktrees.conservativeMode }

    /// Test seam: has a card's inline readiness waiter been registered yet? A test that hand-delivers a
    /// readiness signal to a launching/relaunching stepper must wait for the waiter to exist FIRST — a
    /// signal delivered before the step reaches `awaitReadiness` is dropped by `finishLaunch`'s
    /// "start clean" `pendingReadiness.remove`. Polling this (not a fixed sleep) makes the handoff
    /// deterministic and contention-proof (the flake the orchestrator reproduced under parallel load).
    func hasReadinessWaiter(_ id: UUID) -> Bool { readinessWaiters[id] != nil }

    /// Test seam: force a card's persisted phase (bypassing the funnel's legal-edge gate) so a test can
    /// SEED a transitional card the reconciler then drives — the crash-recovery premise that phase +
    /// persisted fields re-derive everything from disk. Mirrors a raw `store.update { $0.phase = … }`;
    /// optionally back-dates `phaseChangedAt` (launch-timeout tests) or sets `sessionEpoch`.
    func seedPhase(_ id: UUID, _ phase: Phase, sessionEpoch: Int? = nil, phaseChangedAt: Date? = nil) async {
        _ = try? await store.update(id) { t in
            t.phase = phase
            if let at = phaseChangedAt { t.phaseChangedAt = at } else { t.phaseChangedAt = Date() }
            if let e = sessionEpoch { t.sessionEpoch = e }
        }
    }

    // MARK: - per-tick reconcile

    /// The continuous reconcile tick (main.swift's 2s poll calls this + `pollTelemetry`). One batched
    /// `sessions.list()` snapshot per tick (hopped off-actor), then per card: `.live` liveness, launch-
    /// readiness ticking, epoch-identity adoption, stepping the transitional set, and launch timeouts;
    /// finally the orphan-session sweep. Never freezes the actor — every slow probe hops off it.
    public func reconcile() async {
        // ORDER IS LOAD-BEARING: read the CARD PHASES **first**, then sample the sessions.
        //
        // These two reads are a snapshot pair, and the session data must never be OLDER than the phase data.
        // It used to be: `list()` was sampled first, then `agentPaneDeadSessions()` — two off-actor tmux hops,
        // each of which RELEASES the actor — and only then were the phases read. A card that was
        // `.relaunching` (session not yet created) at the session snapshot, but whose bring-up step landed
        // during those suspensions, was then read as `.live` and tested against a session set that predated
        // its session: the `.live` case saw `!alive` and killed a healthy, freshly-launched agent with
        // `.sessionVanished`. Bug #2 was a stale bring-up RESURRECTING a live session; this is the same
        // stale-snapshot hazard pointing the other way — a stale snapshot KILLING a live one.
        //
        // Reading phases first makes the pair fail-safe by direction: a card observed `.live` at T0 must have
        // `ensure`d its session before T0, so the session sample at T1 > T0 necessarily sees it. A card that
        // goes live after T0 is still read as being-born and is simply skipped this tick — the next tick,
        // whose snapshot pair is consistent, lands it. We can be late to notice a death; we must never
        // invent one. (Pinned by `freshlyLiveCardNotKilledByStaleSnapshot`.)
        let tasks = await store.all()
        let aliveNames = Set((try? await offActor { [sessions] in try? sessions.list() })??.map(\.name) ?? [])
        // Sessions whose `agent` pane process DIED but whose session persists (remain-on-exit) — the
        // observable startup-abort / orphaned-dead-pane signal (folded from spawn-startup-abort).
        let deadPaneNames = ((try? await offActor { [sessions] in try? sessions.agentPaneDeadSessions() }) ?? nil) ?? []
        let now = Date()

        // Populate the `boardSnapshot` observed-session cache (PR5 actor-hygiene, Task 5.2) — non-archived
        // cards only. A session-alive card gets ONE off-actor `windows()` call (batched below, all in one
        // hop); a dead card's entry is the empty/not-running placeholder WITHOUT a `windows()` call, so this
        // bounds idle-daemon tmux cost to the live-card count, not the whole board.
        let toObserve = tasks.filter { !$0.archived && aliveNames.contains(sessions.sessionName($0.id)) }
                             .map { ($0.id, sessions.sessionName($0.id)) }
        let deadIds = tasks.filter { !$0.archived && !aliveNames.contains(sessions.sessionName($0.id)) }.map(\.id)
        let s = sessions
        let observedAlive: [UUID: [TmuxTarget]] = (try? await offActor {
            var out: [UUID: [TmuxTarget]] = [:]
            for (id, name) in toObserve { out[id] = (try? s.windows(name)) ?? [] }
            return out
        }) ?? [:]
        for (id, ts) in observedAlive {
            observedSessions[id] = ObservedSession(targets: ts, running: !ts.isEmpty, observedAt: now)
        }
        for id in deadIds { observedSessions[id] = ObservedSession(targets: [], running: false, observedAt: now) }

        for t in tasks {
            let name = sessions.sessionName(t.id)
            let alive = aliveNames.contains(name)
            // STARTUP-ABORT WATCH (folded from spawn-startup-abort-classification), BEFORE the phase switch:
            // a freshly-launched card armed by `finishLaunch` (which lands `.live` once readiness confirms)
            // is watched for an immediate exit. Its session is still present (remain-on-exit kept the dead
            // pane), so `aliveNames` reads it alive — only the pane state reveals the abort. This also
            // graduates a card that survived its grace. GATED on `.live` ONLY: a still-being-born card
            // (`.creatingWorktree`/`.launching`/`.relaunching`) is owned by the readiness machinery + launch
            // timeout and must NEVER be startup-classified here — its session is legitimately absent
            // mid-bring-up, and a lingering `spawnPending` from an earlier spawn must not kill it.
            if t.phase.kind == .live, let deadline = spawnPending[t.id] {
                await confirmSpawnStartup(t, deadline: deadline)
                continue
            }
            // CONVERGENCE: an ORPHANED dead agent pane (session present, agent process exited, no pending
            // record — e.g. a daemon restart lost `spawnPending` mid-grace). The `.live`-vanish check below
            // never fires (session present), so resolve it here so the card ALWAYS converges to dead.
            if t.phase.kind == .live, deadPaneNames.contains(name) {
                await resolveOrphanedDeadPane(t)
                continue
            }
            switch t.phase.kind {

            case .live:
                launchReadyTicks[t.id] = nil            // reached live — reset the being-born counter
                if !alive {
                    // NEVER kill off a stale snapshot (the fail-safe `sweepOrphanSessions` already applies —
                    // bug #7). The ordering above closes the race that produced a stale `aliveNames`; this
                    // re-probe is the belt to that braces, and also covers a transient `list()` hiccup. The
                    // loop suspends on every `await`, so by the time we reach this card the snapshot can be
                    // arbitrarily old — confirm the session is REALLY gone before concluding the agent died.
                    let reallyGone = !((try? await offActor { [sessions] in try sessions.isAlive(name) }) ?? false)
                    if reallyGone {
                        await markDead(t.id, reason: .sessionVanished, detail: nil, source: .daemon)
                    }
                }

            case .launching, .relaunching:
                // A bring-up is ACTIVELY in progress (a synchronous verb, or our own in-flight step) that will
                // land the card — so neither adopt nor re-step; only tick the N=3 fallback (below), which is
                // the mechanism that resolves that bring-up's waiter.
                //
                // `inFlightSteps` is part of the test, not just `readinessWaiters`: a step registers its
                // waiter only AFTER its off-actor `kill`+`ensure` returns, so between those two points a
                // waiter-only check reads "nobody is bringing this up" while the session is already up — and
                // the adopt below would land the card `.live` out from under its own in-flight step. The step
                // then stands down (`finishLaunch` is fenced on the dispatched phase), but the adopt is still
                // a double-drive of a card that was already being brought up. Take the step's own claim.
                let bringingUp = readinessWaiters[t.id] != nil || inFlightSteps.contains(t.id)
                // (adopt) a stranded being-born card whose session is ALREADY up at the SAME epoch → adopt to
                // live rather than re-launching it (the session came up before a crash cut the phase write).
                // An OLDER-epoch session is NEVER adopted — the stepper completes the relaunch (kill+launch).
                // The epoch read hops off-actor (real `stampedEpoch` is a tmux subprocess — keep the tick free).
                if !bringingUp, alive {
                    // The probe SUSPENDS the actor; a concurrent restart/resume can bump the card to a newer
                    // `.relaunching` epoch meanwhile. Pass the PROBED epoch as `observedEpoch` so the funnel
                    // re-reads the current card and no-ops if the generation moved — the newer relaunch wins
                    // (single-winner fence). `launching→live`/`relaunching→live` are legal for viaSignal too.
                    let probedEpoch = try? await offActor { [sessions] in try? sessions.stampedEpoch(name: name) }
                    if let probed = probedEpoch ?? nil, probed == t.sessionEpoch {
                        launchReadyTicks[t.id] = nil
                        // Land in the flavor the LaunchStepper WOULD have used (mirror its rule) rather than a
                        // hardcoded `.humanTurn`: a prompted first launch lands `.running`, a provisional/resumed
                        // card `.waiting`. Adopt jumps `.launching→.live` WITHOUT the LaunchStepper, so nothing
                        // downstream corrects it — it must derive the landing here. Falls back to `.waiting` if
                        // the adapter is momentarily unavailable (never worse than the old hardcode).
                        let land = (try? registry.get(t.agentId)).map { landing(of: deriveLaunchFlavor(t, $0)) }
                            ?? .waiting(.humanTurn)
                        // Mirror the Launch/RelaunchStepper's COMPANION cleanup, not just its landing: both
                        // clear `pendingSeed` on the successful `→ live` transition. Adopt jumps straight to
                        // live WITHOUT the stepper, so a crash between "session consumed the seed + came up"
                        // and the stepper's transition would otherwise leave `pendingSeed` set — and a later
                        // `resume(seed: nil)` preserves it, so `deriveLaunchFlavor` would REPLAY the seed.
                        _ = await transition(t.id, to: .live(land), observedEpoch: probed) { $0.pendingSeed = nil }
                        continue
                    }
                }
                // (3) tick the N=3 launch-readiness fallback — gated ONLY on phase + session-alive, NEVER on
                //     `inFlightSteps` (else a Codex `codex resume` / missed hook never confirms). Independent
                //     of stepping so a card holding an in-flight step still gets ticked to `.live`.
                if alive { tickLaunchReadyPublic(t.id) } else { launchReadyTicks[t.id] = nil }
                // (6) `phaseChangedAt` timeout (carry #2, first consumer of `sessionLaunchTimeout`). A launch
                //     that never confirmed within the timeout is dead. Checked BEFORE stepping so a doomed
                //     launch is never re-driven past its deadline. The re-step invariant keeps the anchor:
                //     a same-phase `transition(.launching)` is a funnel noop (no `phaseChangedAt` re-stamp),
                //     so the bound stays fixed to the ORIGINAL entry across re-steps.
                if now.timeIntervalSince(t.phaseChangedAt) > TimeInterval(config.sessionLaunchTimeout) {
                    let reason: DeadReason = (t.phase.kind == .launching) ? .spawnFailed : .resumeFailed
                    await markDead(t.id, reason: reason,
                                   detail: "launch timed out after \(config.sessionLaunchTimeout)s",
                                   source: .daemon)
                    continue
                }
                // (4) step it — unless a bring-up is already in progress (don't double-drive).
                if !bringingUp { stepIfEligible(t, now: now) }

            case .creatingWorktree, .archivedPending:
                // (4) step the transitional set by kind — `.archivedPending` IS `isTerminal==true` yet MUST
                //     be stepped by Teardown, so this iterates EXPLICITLY by kind, never via `!isTerminal`.
                launchReadyTicks[t.id] = nil
                stepIfEligible(t, now: now)

            case .dead, .archivedComplete:
                launchReadyTicks[t.id] = nil          // terminal — nothing to step; keep the switch exhaustive
            }
        }

        // (5) orphan-session sweep — after the per-card pass so a just-transitioned card isn't misread.
        await sweepOrphanSessions(aliveNames: aliveNames, tasks: tasks)
    }

    /// Dispatch one phase-step for `card` off-actor if eligible: no step already in flight AND past the
    /// backoff deadline. Sets `inFlightSteps` SYNCHRONOUSLY (before the detached hop) so the next tick / a
    /// concurrent verb never double-drives; the completion clears it and updates the backoff.
    private func stepIfEligible(_ card: Task, now: Date) {
        guard !inFlightSteps.contains(card.id) else { return }
        if let attempt = stepAttempts[card.id], now < attempt.nextEligible { return }   // backing off
        guard let stepper = steppers[card.phase.kind] else { return }
        inFlightSteps.insert(card.id)
        let ctx = convergeContext()
        _Concurrency.Task { [weak self] in await self?.runStep(stepper, card, ctx) }
    }

    /// Run one step to completion, then reconcile the per-card reconciler state: a throw bumps the capped
    /// backoff + emits an activity; success resets it. Always clears `inFlightSteps` last so the next tick
    /// can re-drive. Actor-isolated but every internal `await` suspends (off-actor session/git work inside
    /// the stepper), so the tick that dispatched it isn't frozen.
    private func runStep(_ stepper: any PhaseStepper, _ card: Task, _ ctx: ConvergeContext) async {
        do {
            try await stepper.step(card, ctx)
            stepAttempts[card.id] = nil                 // success resets the counter
        } catch {
            bumpStepBackoff(card.id, now: Date())
            let n = stepAttempts[card.id]?.count ?? 1
            let latest = await store.get(card.id)
            emitActivity(.warning, latest, .daemon,
                         "step \(card.phase.kind) failed (attempt \(n)): \(error)")
        }
        inFlightSteps.remove(card.id)
    }

    /// Capped-exponential backoff: `nextEligible = now + min(2^count, cap)` seconds. Capped so a
    /// persistently-failing step never hot-loops but still retries at a bounded cadence.
    private func bumpStepBackoff(_ id: UUID, now: Date) {
        let count = (stepAttempts[id]?.count ?? 0) + 1
        let delay = stepBackoffOverrideSeconds
            ?? min(pow(2.0, Double(min(count, 6))), stepBackoffCapSeconds)   // 2,4,8,…,64 capped
        stepAttempts[id] = (count, now.addingTimeInterval(delay))
    }
    private var stepBackoffCapSeconds: Double { 64 }

    /// `tickLaunchReady` is `private` in +Recovery; expose the same behavior to the reconciler.
    private func tickLaunchReadyPublic(_ id: UUID) {
        guard readinessWaiters[id] != nil else { launchReadyTicks[id] = nil; return }
        let n = (launchReadyTicks[id] ?? 0) + 1
        if n >= launchReadyTickThreshold { launchReadyTicks[id] = nil; resolveReadiness(id, true) }
        else { launchReadyTicks[id] = n }
    }

    // MARK: - orphan-session sweep (fresh off-actor probe, fail-safe)

    /// Kill a live `orchestra-<uuid>` session whose card is ARCHIVED or NONEXISTENT — but only AFTER a
    /// fresh off-actor `stampedEpoch`/`isAlive` probe (never off a stale snapshot; bug #7). A
    /// `dead(.completed)` card's surviving session is left alone (revival stays possible), as is any
    /// non-terminal card's session. Fail-safe: no kill without a fresh probe that still sees it alive.
    private func sweepOrphanSessions(aliveNames: Set<String>, tasks: [Task]) async {
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for name in aliveNames {
            guard let id = Self.cardId(fromSessionName: name) else { continue }   // not an orchestra session
            let card = byId[id]
            guard Self.isOrphanSession(card) else { continue }
            // Fresh, off-actor probe (bug #7 + non-blocking): re-confirm liveness before killing. A session
            // that vanished between the snapshot and now is skipped; a still-alive one is killed.
            let stillAlive = (try? await offActor { [sessions] in
                _ = try? sessions.stampedEpoch(name: name)          // fresh epoch-stamped probe
                return try sessions.isAlive(name)
            }) ?? false
            guard stillAlive else { continue }
            try? await offActor { [sessions] in _ = try sessions.kill(name) }
        }
    }

    /// A session is an orphan (sweepable) when its card is ABSENT or ARCHIVED. Fail-safe carve-out: a
    /// `.dead(.completed)` (or any `.dead`) card is NEVER swept — revival/reopen stays possible.
    static func isOrphanSession(_ card: Task?) -> Bool {
        guard let card else { return true }                                    // no card ⇒ orphan
        if card.archived { return true }                                       // archived ⇒ orphan
        if case .archived = card.phase { return true }                         // real archived phase ⇒ orphan
        return false                                                           // live/being-born/dead ⇒ keep
    }

    /// Parse a card id out of an `orchestra-<lowercased-uuid>` session name; nil for any other name.
    static func cardId(fromSessionName name: String) -> UUID? {
        guard name.hasPrefix("orchestra-") else { return nil }
        return UUID(uuidString: String(name.dropFirst("orchestra-".count)))
    }

    // MARK: - boot phase reconciliation (folds recoverSessions)

    /// One reconciliation pass over every card from its PERSISTED phase, run once at boot BEFORE the poll
    /// loop starts. Folds the old `recoverSessions` (single owner): a `.live`-persisted card whose session
    /// died (or is alive at a stale epoch) while the daemon was down is routed through the funnel to
    /// `.relaunching` (RelaunchStepper drives it) — or `.creatingWorktree` (blank restart for a
    /// never-prompted card) — or `dead(.rebootUnrevived)` when unrecoverable. A `.live` card whose session
    /// is alive at the MATCHING epoch is adopted (left live). Transitional cards are left for the steady-
    /// state reconcile tick (which steps them, `inFlightSteps`-guarded so nothing double-drives). Also
    /// wires corrupt-store conservative mode (carry #3).
    public func reconcilePhasesAtBoot() async {
        // Corrupt board → conservative worktree mode for this daemon's WHOLE lifetime (cleared only by a
        // later clean restart, which is a fresh registry). `wasCorrupt()` forces the load.
        if await store.wasCorrupt() {
            await worktrees.setConservativeMode(true)
        }
        let tasks = await store.all()
        let aliveNames = Set((try? await offActor { [sessions] in try? sessions.list() })??.map(\.name) ?? [])
        // Sessions whose `agent` pane died but whose session persists (remain-on-exit) — the startup-abort /
        // orphaned-dead-pane signal (folded from spawn-startup-abort-classification). `spawnPending` is
        // in-memory and empty at boot, so it can no longer own graduation: normalize every survivor here.
        let deadPaneNames = ((try? await offActor { [sessions] in try? sessions.agentPaneDeadSessions() }) ?? nil) ?? []

        for t in tasks {
            guard case .live = t.phase else { continue }   // transitional/terminal handled by the tick / are done
            let name = sessions.sessionName(t.id)
            // INVARIANT RESTORATION (boot): a restart is the ONE thing that decouples the durable tmux
            // `remain-on-exit` flag from the ephemeral `spawnPending` record. Normalize every survivor so no
            // card leaves boot with a leaked arm: a dead armed pane converges (capture stderr → dead, reap),
            // an alive survivor's flag is cleared so a LATER exit reads `.sessionVanished`, not a mis-abort.
            if deadPaneNames.contains(name) {
                await resolveOrphanedDeadPane(t)   // orphaned startup abort — converge, evidence preserved
                continue
            }
            if aliveNames.contains(name) {
                // Alive survivor → clear any leaked `remain-on-exit` (best-effort; never kill a healthy agent
                // over a transient tmux hiccup). Then adopt/relaunch by epoch identity as before.
                try? await offActor { [sessions] in try sessions.setRemainOnExit(name, window: "agent", on: false) }
                clearSpawnPending(t.id)
                // Session survived the daemon (daemon-only crash). Adopt ONLY on epoch identity; a stale
                // (older/mismatched) epoch means the session isn't ours → relaunch to reclaim identity.
                let e = try? await offActor { [sessions] in try? sessions.stampedEpoch(name: name) }
                if (e ?? nil) == t.sessionEpoch {
                    continue                                // adopt — leave `.live`
                }
                _ = await transition(t.id, to: .relaunching,
                                     mutate: { $0.deadReason = nil; $0.deadDetail = nil })
                continue
            }
            // Session gone (reboot). Route the recoverable ones to `.relaunching` — the ONE legal restart
            // edge from `.live` — and let the RelaunchStepper distinguish: a resumable card resumes its
            // transcript; a never-prompted (provisional) card blank-restarts (its own designed behavior).
            // Only a genuinely unrecoverable card (no transcript AND already prompted) is `rebootUnrevived`.
            // NOTE: the brief's literal "provisional → .creatingWorktree" is unreachable (`.live →
            // .creatingWorktree` is not a legal funnel edge); `.relaunching` is the sanctioned restart intent
            // and the RelaunchStepper already blank-restarts a provisional card — same outcome, legal edge.
            if await isResumable(t) || t.titleProvisional {
                _ = await transition(t.id, to: .relaunching,
                                     mutate: { $0.deadReason = nil; $0.deadDetail = nil })
            } else {
                await markDead(t.id, reason: .rebootUnrevived, detail: nil, source: .daemon)
            }
        }
    }
}
