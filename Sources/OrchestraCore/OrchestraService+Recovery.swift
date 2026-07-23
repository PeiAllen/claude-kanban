import Foundation

/// A bring-up that failed OUTRIGHT — the session could not be created, so there is nothing to wait for.
/// Distinct from `.timedOut` (a session that came up but never confirmed): here we hold the real reason in
/// hand, and waiting out the launch grace would only replace it with a misleading "launch timed out".
public struct LaunchFailure: Sendable, Equatable {
    /// Raw evidence — the tmux stderr / captured pane tail. Kept verbatim for debugging.
    public var detail: String
    /// Set when the failure was the HOST running out of a launch resource, not the card doing anything
    /// wrong. Carries the resource + its live numbers through to `deadResource` and the Recovery panel.
    public var resource: HostResourceReport?
    public init(detail: String, resource: HostResourceReport? = nil) {
        self.detail = detail; self.resource = resource
    }
}

/// HOW a bring-up's readiness was confirmed — the provenance B3's cold delivery turns on. `.signal` is a
/// positive session signal proving the NEW generation booted (a current-epoch SessionStart hook / a fresh
/// launch's rollout `session_meta`), so a `relaunchSeed` seed can be confirmed immediately. `.ticks` is the
/// N=3 liveness fallback (a `codex resume` emits no signal) or a signal we can't attribute to the current
/// generation — it proves only that SOMETHING is alive, so the stepper HOLDS the seed lease and lets
/// `report()`'s provenance-fenced held-confirm remove it on the first proven current-gen line/hook.
public enum ReadinessVia: Sendable, Equatable { case signal, ticks }

/// The outcome of awaiting a relaunch's inline readiness confirmation. `.superseded` is distinct from
/// `.timedOut` so a relaunch displaced by a newer relaunch for the same card exits quietly (the survivor
/// owns the card) instead of being treated as a failure and marked dead.
public enum ReadinessOutcome: Sendable, Equatable {
    case confirmed(via: ReadinessVia)
    case timedOut, superseded
    case launchFailed(LaunchFailure)
}

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

    /// Resolve a `--model` re-seat request against the CARD'S OWN adapter catalog, or throw.
    ///
    /// `agentId` never changes on a re-seat (the vendor transcript we are resuming is vendor-specific), so
    /// a Codex id handed to a claude-code card must be REJECTED here rather than becoming
    /// `claude --model gpt-5.6-terra` and dying at the process. `Adapter.model(for:)` cannot do this — it
    /// falls back to `AgentModel(id:)` for anything it doesn't know (Adapter.swift) — so this is the gate.
    ///
    /// A DATED variant of a catalog id is accepted: the offline table carries `claude-haiku-4-5` while the
    /// vendor's own resolved id (and the id people have written down) is `claude-haiku-4-5-20251001`.
    /// It resolves to the catalog entry, so the launch id stays canonical and `model` keeps its real
    /// `contextWindow` (the `ctxPct` denominator). Cross-adapter ids still fail — a Codex id is not a
    /// variant of any Claude entry. Case-sensitive: fails closed.
    ///
    /// Known limit: if the bundled catalog resource fails to load, `models()` is a hardcoded fallback list
    /// (ClaudeCodeAdapter.swift), so a genuinely valid id could be rejected. That fails closed, and the
    /// error names the ids we actually know about.
    func resolveModelOverride(_ requested: String?, for task: Task) throws -> AgentModel? {
        guard let requested else { return nil }   // absent ⇒ no override (every pre-existing caller)
        let want = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = try registry.get(task.agentId).models()
        // EXACT ids win across the WHOLE catalog before any variant matching, so a catalog that ever carried
        // both a floating and a dated id can't have an exact request captured by an earlier entry's variant.
        // An EXPLICIT empty/whitespace model is a mistake, not "no override": silently relaunching on the
        // old model and reporting success is exactly the quiet no-op this feature exists to prevent.
        if !want.isEmpty {
            if let m = catalog.first(where: { $0.id == want }) { return m }
            if let m = catalog.first(where: { Self.isModelVariant(want, of: $0.id) }) { return m }
        }
        throw OrchestraError.invalidParams(
            "unknown model '\(requested)' for agent '\(task.agentId)'. Valid: "
            + catalog.map(\.id).joined(separator: ", "))
    }

    /// Is `id` the vendor's DATED form of the catalog id `base` (`claude-haiku-4-5-20251001` of
    /// `claude-haiku-4-5`)? Used both to accept a dated id on the way in and to recognize the agent's own
    /// dated report as a match on the way out — never a raw `==`, which would false-reject and false-warn.
    ///
    /// The suffix must be all DIGITS. Accepting any suffix would silently downgrade a typo — `--model
    /// claude-haiku-4-5-oops` would prefix-match and quietly launch on `claude-haiku-4-5` — which is exactly
    /// the "fails closed" promise this validation makes. A mistyped id must be an error, not a substitution.
    static func isModelVariant(_ id: String, of base: String) -> Bool {
        guard id.hasPrefix(base + "-") else { return false }
        let suffix = id.dropFirst(base.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// Did the agent actually come up on the model we asked for? Compared through the catalog, never raw
    /// string equality. An id we cannot resolve at all is treated as a MATCH — this check exists to catch a
    /// vendor that ignores `--model`, and a false accusation is worse than a missed one.
    func modelHonored(reported: String, requested: String, agentId: String) -> Bool {
        if reported == requested { return true }
        let ids = ((try? registry.get(agentId))?.models() ?? []).map(\.id)
        guard let canon = ids.first(where: { reported == $0 || Self.isModelVariant(reported, of: $0) })
        else { return true }   // unknown id — cannot judge, so do not accuse
        return canon == requested
    }

    /// INTENT-ONLY (PR4b Task 4): record the relaunch intent (`transition(→ .relaunching)` — bumps the
    /// generation, the atomic single-winner claim + closes the ghost-SessionEnd window) and RETURN. The
    /// reconciler's `RelaunchStepper` drives the walk: re-materializes a missing worktree, kills+ensures the
    /// session off-actor, confirms readiness (capability-gated), and finalizes `→ .live` epoch-fenced (a
    /// relaunch superseded by a newer one no-ops its finalize; a genuine failure → `.dead(.resumeFailed)`).
    /// A `seed` (handoff / seeded-wake) is persisted as `pendingSeed` in the SAME patch (carried #1 write
    /// side); the RelaunchStepper consumes + clears it on readiness. No subprocess runs before the return.
    @discardableResult
    public func resume(_ id: UUID, graceSeconds: Int? = nil, seed: String? = nil,
                       model: String? = nil, source: ActivitySource = .daemon) async throws -> Task {
        let task = try await require(id)
        // Validate BEFORE the first mutation: a rejected model must leave the card completely untouched —
        // not merely un-relaunched, but with its startup-watch (below) and its durable inbox (drained by
        // `resumeInCard`, which validates for the same reason) still intact.
        let override = try resolveModelOverride(model, for: task)
        clearSpawnPending(id)   // a user-driven resume supersedes any in-flight spawn startup-watch
        modelOverrideWatch[id] = nil   // this relaunch supersedes any earlier re-seat: never warn about a stale one
        // The `relaunching → relaunching` supersede self-edge is legal, so a newer relaunch bumps the epoch
        // again and an earlier attempt's finalize is dropped by the epoch fence (single-winner discipline).
        _ = await transition(id, to: .relaunching, mutate: { t in
            t.deadReason = nil; t.deadDetail = nil; t.deadResource = nil
            if let seed { t.pendingSeed = seed }   // folded handoff/wake seed rides the relaunch (carried #1)
            if let override {
                // `pendingModel` is the launch intent and the ONLY thing `finishLaunch` trusts; `model` is
                // set purely so the board reflects the re-seat at once. If the dying session's last
                // statusline reverts `model` before the stepper runs (it can — that write is not
                // epoch-fenced), the launch is unaffected and the `.live` landing restores `model`.
                t.pendingModel = override.id
                t.model = override
            }
        })
        guard let updated = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        // Arm the tripwire from the PERSISTED card, not from our local `override`: two concurrent re-seats can
        // interleave across the `await transition` above, and arming from the loser would later accuse the
        // agent of running the wrong model when it faithfully came up on the winner's. `left` is the model we
        // are leaving — the one a vendor that ignored `--model` would keep reporting.
        if let want = updated.pendingModel { modelOverrideWatch[id] = (want, task.model.id, 0) }
        emitActivity(.recovered, updated, source, "resuming “\(updated.title)”")
        return updated
    }

    /// F1 (C3) — resume THIS card into a fresh process with CLEAN context, carrying the handoff/fork
    /// context as the resumed session's opening seed. This is **resume, not a blank restart**:
    /// `agentSessionId` is KEPT, so the vendor transcript carries forward. This is F1 (handoff) AND the
    /// cold idle-wake path the `wake` ladder records as its `.relaunching` intent. Backs D1's `handoff`.
    ///
    /// B3 — NO inbox drain. The pending inbox is no longer eaten here and folded into the seed; it stays
    /// DURABLE and is delivered by the RelaunchStepper's `relaunchSeed` claim (which composes this handoff
    /// with the still-queued messages at claim time under one budget). That closes the L1 drain→persist
    /// crash window — a crash between here and the launch loses nothing, because nothing was removed. This
    /// body is now exactly `resume(seed:)`; `resume` validates the model before its first mutation, so no
    /// pre-validation is needed (there is no destructive drain left to protect).
    @discardableResult
    public func resumeInCard(_ id: UUID, seed: String? = nil, graceSeconds: Int? = nil,
                             model: String? = nil, source: ActivitySource = .daemon) async throws -> Task {
        try await resume(id, graceSeconds: graceSeconds, seed: seed, model: model, source: source)
    }

    /// Start a NEW blank session for a (dead or live) card in the SAME worktree. Fresh id, no prompt
    /// re-handed; status → waiting, awaitingFirstPrompt → true. Never touches worktree contents.
    ///
    /// INTENT-ONLY (PR4b Task 4): `transition(→ .relaunching, mutate:)` carries the real persist block
    /// (fresh id, rolled prior ids, provisional, cleared dead/desc) atomically with the phase write, then
    /// RETURNS. The reconciler's `RelaunchStepper` blank-launches the fresh id (capability-gated — it goes
    /// through `confirmReadiness`, never an immediate `.live`). The `relaunching → relaunching` supersede
    /// self-edge + `inFlightSteps` give verb-vs-verb restart a single-winner (carried #5).
    @discardableResult
    public func restart(_ id: UUID, model: String? = nil, source: ActivitySource = .daemon) async throws -> Task {
        let task = try await require(id)
        let adapter = try registry.get(task.agentId)
        // Validate before the first mutation — a rejected model leaves the card exactly as it was.
        let override = try resolveModelOverride(model, for: task)
        clearSpawnPending(id)   // a user-driven restart supersedes any in-flight spawn startup-watch
        modelOverrideWatch[id] = nil   // this relaunch supersedes any earlier re-seat: never warn about a stale one

        // Same capability gate as spawn: only a `.seeded` agent mints a fresh id on restart.
        let freshId: String?
        switch adapter.capabilities.sessionId {
        case .seeded:     freshId = adapter.newSessionId()
        case .discovered: freshId = nil
        }
        var priorIds = task.priorSessionIds
        if let old = task.agentSessionId, !old.isEmpty { priorIds.append(old) }
        let prior = priorIds

        // Enter `.relaunching` with the REAL persist block applied atomically (bumps the generation — a stale
        // signal from the prior session is epoch-fenced; a provisional card blank-restarts under the stepper).
        _ = await transition(id, to: .relaunching, mutate: {
            $0.agentSessionId = freshId
            $0.priorSessionIds = prior
            $0.awaitingFirstPrompt = true
            $0.deadReason = nil
            $0.deadDetail = nil
            $0.deadResource = nil
            $0.desc = ""
            $0.pendingSeed = nil   // a blank restart carries no seed
            if let override {      // re-seat: the launch intent (see `resume`), not just the display model
                $0.pendingModel = override.id
                $0.model = override
            }
        })
        guard let updated = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        // Arm the tripwire from the PERSISTED card, not from our local `override`: two concurrent re-seats can
        // interleave across the `await transition` above, and arming from the loser would later accuse the
        // agent of running the wrong model when it faithfully came up on the winner's. `left` is the model we
        // are leaving — the one a vendor that ignored `--model` would keep reporting.
        if let want = updated.pendingModel { modelOverrideWatch[id] = (want, task.model.id, 0) }
        emitActivity(.recovered, updated, source, "new session “\(updated.title)”")
        return updated
    }

    /// Reopen an archived (Done) card: put the card back on the board (keeps its column) and bring the agent
    /// back — `resume` its transcript when resumable, else a fresh blank launch in the recreated tree.
    /// Idempotent: a non-archived card is returned as-is.
    ///
    /// INTENT-ONLY (PR4b Task 4): enter `.creatingWorktree` (bumps the generation — closes the ghost
    /// SessionEnd window), unarchiving, and RETURN. The reconciler's `MaterializeStepper` re-cuts the run dir
    /// the archive reclaimed → `LaunchStepper` brings the agent up (resume vs blank re-derived from the
    /// persisted fields by `deriveLaunchFlavor`), its `.live` finalize `observedEpoch`-fenced (carried #5:
    /// epoch-fence reopen resume-finalize). No `.dead→.archived` normalize is needed — the archive verb writes
    /// `.archived(_)` + the `archived` Bool together, so an archived card is ALWAYS `.archived(_)`, and the
    /// `archivedPending/archivedComplete → creatingWorktree` reopen edge applies directly. (`DeadReason.completed`
    /// is gone — a legacy stored `dead(.completed)` record no longer decodes at all; it self-drops on load.)
    @discardableResult
    public func reopen(_ id: UUID, source: ActivitySource = .daemon) async throws -> Task {
        let t = try await require(id)
        guard t.archived else { return t }
        let adapter = try registry.get(t.agentId)
        let resumable = await isResumable(t)

        // Enter `.creatingWorktree` (bumps the generation), clearing the archived Bool + dead metadata. The
        // resume path keeps the id so the transcript carries forward; the blank path mints a fresh id / rolls
        // prior ids / resets provisional+desc (restart semantics), so `deriveLaunchFlavor` derives a blank launch.
        if resumable {
            _ = await transition(id, to: .creatingWorktree, mutate: {
                $0.archived = false; $0.deadReason = nil; $0.deadDetail = nil; $0.deadResource = nil
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
                $0.awaitingFirstPrompt = true
                $0.desc = ""
                $0.deadReason = nil
                $0.deadDetail = nil
                $0.deadResource = nil
            })
        }
        guard let reopening = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        emitActivity(.recovered, reopening, source, "Reopened “\(reopening.title)”")
        return reopening
    }

    /// Confirm a being-born card (launch OR relaunch) is alive — HOW depends on the agent (capability, never
    /// identity). `.sessionStartHook` waits for the agent's own SessionStart telemetry (Claude), or times
    /// out. `.rolloutMeta` ALSO waits (Codex): a fresh launch's rollout `session_meta` line resolves the
    /// waiter via the tail observer; a `codex resume` writes no rollout, so the N=3 `launchReadyTicks`
    /// fallback resolves it within the grace — either way it stays ON the readiness gate (never immediate,
    /// which would leave no waiter and bypass the gate). `.relaunchLiveness` takes the successful `ensure`
    /// as the confirmation because the agent emits no marker at all, so it must NOT wait for one.
    func confirmReadiness(_ id: UUID, adapter: any Adapter, graceSeconds: Int,
                          expectedEpoch: Int) async -> ReadinessOutcome {
        switch adapter.capabilities.readinessConfirmation {
        case .sessionStartHook, .rolloutMeta:
            return await awaitReadiness(id, graceSeconds: graceSeconds, expectedEpoch: expectedEpoch)
        case .relaunchLiveness:
            // No marker at all — the successful `ensure` IS the confirmation, but it's a liveness proof,
            // not a signal that the seed booted, so it holds the seed lease like the tick fallback.
            return .confirmed(via: .ticks)
        }
    }

    /// The continuous liveness reconcile (safety net when no SessionEnd fires). **Test-only in production:**
    /// the daemon's 2s poll drives `reconcile()`, which FOLDS this liveness pass in (see `+Reconcile`'s
    /// `.live` case); `reconcileLiveness` has no production caller and is retained only so focused unit tests
    /// can exercise the liveness step in isolation. Do not re-wire it into the poll loop (double-ticking).
    /// Phase-gated:
    /// the being-born phases (`.creatingWorktree`, `.relaunching`, `.launching`) are NEVER killed here — their
    /// session is legitimately absent mid-bring-up and each is owned by a SYNCHRONOUS launch/relaunch that
    /// handles its own readiness + spawnFailed timeout; killing them would race the owner's own
    /// `transition`→`ensure` window and false-kill a live spawn. Only a `.live` card whose session vanished is
    /// concluded (crashed → `.dead(.sessionVanished)`). Terminal cards are excluded outright. Deaths that DO
    /// fire route through the funnel (`markDead`) so they conclude.
    public func reconcileLiveness() async {
        let tasks = await store.all()
        // One `tmux list-sessions` per poll tick, not one `has-session` per card. Hopped off-actor
        // (mirrors `reconcile()`'s hop exactly) so this slow tmux probe never freezes the actor. A second
        // hop yields the set of sessions whose `agent` pane process DIED but whose session persists
        // (remain-on-exit) — the observable signal of a startup abort / orphaned dead pane.
        let s = sessions
        let aliveNames = Set((try? await offActor { try? s.list() })??.map(\.name) ?? [])
        let deadPaneNames = ((try? await offActor { try? s.agentPaneDeadSessions() }) ?? nil) ?? []
        for t in tasks where !t.phase.isTerminal {
            let name = sessions.sessionName(t.id)
            let alive = aliveNames.contains(name)
            // STARTUP-ABORT WATCH (folded from spawn-startup-abort-classification): a freshly-launched card
            // (armed in `finishLaunch`, landed `.live`) is watched for an immediate exit BEFORE the generic
            // phase handling. Its session is still present (remain-on-exit kept the dead pane), so
            // `aliveNames` can't see the abort — only the pane state can. Also graduates a card that
            // survived its grace. GATED on `.live` ONLY (mirrors `reconcile()`): a still-being-born card is
            // owned by the readiness machinery + launch timeout and must NEVER be startup-classified here.
            if t.phase.kind == .live, let deadline = spawnPending[t.id] {
                await confirmSpawnStartup(t, deadline: deadline)
                continue
            }
            // CONVERGENCE: an ORPHANED dead agent pane (session present, agent process exited, no pending
            // record) — e.g. a startup abort whose `spawnPending` was lost on a daemon restart mid-grace.
            // `aliveNames` sees the session as present so the phase-vanish check below never fires; resolve
            // it here so the card ALWAYS converges instead of hanging "running" forever.
            if t.phase.kind == .live, deadPaneNames.contains(name) {
                await resolveOrphanedDeadPane(t)
                continue
            }
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
                // Being born under the reconciler-driven LaunchStepper, which owns readiness; the reconcile tick owns
                // the spawnFailed launch timeout via `phaseChangedAt`. Mirror `.relaunching`: tick the N=3 fallback while
                // a waiter is pending; NEVER markDead here — killing a launching card races the launch's own
                // `transition(.launching)`→`ensure` window and would false-kill a live spawn.
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

    /// Resolve a startup-pending card by inspecting its `agent` pane (remain-on-exit keeps a dead one
    /// visible):
    ///  • `.alive` past its deadline → GRADUATE: clear remain-on-exit + drop pending (normal monitoring
    ///    resumes, so a later exit vanishes the session and reads as `.sessionVanished` as before).
    ///  • `.alive` before its deadline → keep watching.
    ///  • `.dead` (session present, pane process exited) → STARTUP ABORT → capture evidence + bounded retry
    ///    / mark dead.
    ///  • `.gone` (session absent — a deliberate kill or a lost remain-on-exit race) → hand to the normal
    ///    `.sessionVanished` path (revivable), NOT a startup abort, and never re-spawned (don't fight a kill).
    ///
    /// Folded from `spawn-startup-abort-classification` into the lifecycle-convergence architecture: the
    /// helpers below are the startup-abort machinery, driven from `reconcileLiveness`/`reconcile` (the
    /// spawnPending + orphaned-dead-pane pre-checks) and `reconcilePhasesAtBoot` (the boot normalization).
    func confirmSpawnStartup(_ t: Task, deadline: Date) async {
        let id = t.id
        let name = sessions.sessionName(id)
        let state = (try? await offActor { [sessions] in try sessions.agentPaneState(name) }) ?? .gone
        switch state {
        case .alive:
            guard Date() >= deadline else { return }   // still within grace — keep watching
            // Graduate ONLY once remain-on-exit is confirmed OFF: otherwise a later mid-run crash would
            // leave a dead pane in a still-present session and never be seen as `.sessionVanished`. If the
            // toggle fails (tmux hiccup), stay pending and retry next tick — the card is alive, nothing lost.
            let toggledOff = (try? await offActor { [sessions] () -> Bool in
                try sessions.setRemainOnExit(name, window: "agent", on: false); return true
            }) ?? false
            if toggledOff { clearSpawnPending(id) }
        case .dead:
            await handleStartupAbort(t)
        case .gone:
            clearSpawnPending(id)
            await markDead(id, reason: .sessionVanished, detail: nil, source: .daemon)
        }
    }

    /// A startup abort: capture the dying pane's final output as evidence, then bounded-retry the launch
    /// (an immediate exit is usually a transient launch hiccup) or give up with `.spawnExitedImmediately`.
    /// The retry re-`ensure`s the SAME session + cwd (kill-then-ensure — no double-create, no worktree churn).
    private func handleStartupAbort(_ t: Task) async {
        let id = t.id
        let name = sessions.sessionName(id)

        // Capture the dying pane AND take the host's pulse in ONE hop, so this function keeps exactly the
        // single suspension point the race guard below was written against.
        let probe: (evidence: String?, resource: HostResourceReport?) = await offActorValue { [sessions] in
            let pane = (try? sessions.capture(name, window: "agent", maxChars: 4096))?.text
            let evidence = pane.flatMap { Self.startupEvidence(from: $0) }
            return (evidence, sessions.hostResourceFault(evidence: evidence))
        }
        let evidence = probe.evidence

        // The card may have been archived / killed / restarted / concluded during the capture await —
        // stand down rather than resurrect it or fight an intentional teardown (requirement D). A terminal
        // (`.dead(_)`/`.archived(_)`) phase covers a SessionEnd death. A fresh restart/resume already
        // cleared `spawnPending`, so a nil entry also means "superseded". The re-check after the capture
        // await is the race guard (orch drops the old `recovering` set; report()'s death path is
        // epoch-fenced, not `recovering`-gated).
        guard spawnPending[id] != nil,
              let live = await store.get(id),
              !live.archived, !live.phase.isTerminal else {
            clearSpawnPending(id)
            return
        }

        // Is the HOST what failed? Checked BEFORE the retry budget, because retrying is not just useless
        // when the machine has no pseudo-terminals left — it is actively harmful: three more launches, each
        // waiting out its grace, all doomed, and the card finally lands on `.spawnExitedImmediately` with
        // whatever unrelated noise the starved agent happened to print (the incident's `ENOENT: Bun could
        // not find a file`). Fail fast, name the real cause, stay resumable.
        if let resource = probe.resource {
            clearSpawnPending(id)
            try? await offActor { [sessions] in try? sessions.kill(name) }
            await markDead(id, reason: .resourceExhausted, detail: evidence,
                           resource: resource, source: .daemon)
            return
        }

        let attempt = spawnAttempts[id] ?? 0
        if attempt < maxStartupRetries,
           let spec = spawnRelaunch[id],
           let adapter = try? registry.get(spec.adapterId) {
            spawnAttempts[id] = attempt + 1
            // Re-name the stored context from the LIVE card: a `set-title` between the aborted launch and
            // this retry must reach the agent, and the same value has to arm the session-name mirror or the
            // retried session's first report reads as a rename. Every other field is deliberately reused —
            // the retry is the SAME launch, into the same session id and cwd.
            var ctx = spec.ctx
            ctx.name = live.title          // the freshly re-read card, not the reconcile-tick snapshot `t`
            // Arm the session-name mirror with what this retry is about to push, for the same reason
            // `bringUp` pre-arms: a `set-title` landing between the `ensure` below and the retried
            // session's first statusline would otherwise see the pushed name differ from both the
            // baseline and the new title, read as a rename, and clobber it.
            if !live.title.isEmpty { _ = try? await store.update(id) { $0.lastSessionName = live.title } }
            // …and that store hop is a SUSPENSION POINT inside the window the race guard above was written
            // to cover (this function is deliberately built around having exactly one). Re-assert the guard
            // so the destructive kill+ensure below still runs on a card that is ours: a restart landing in
            // the new window would otherwise be overwritten by a retry re-`ensure`ing the OLD argv (old
            // `--session-id`) under a generation that no longer exists.
            guard spawnPending[id] != nil, let stillOurs = await store.get(id),
                  !stillOurs.archived, !stillOurs.phase.isTerminal,
                  stillOurs.sessionEpoch == live.sessionEpoch else {
                clearSpawnPending(id)
                return
            }
            try? adapter.prepareToLaunch(ctx)
            // Stamp the card's generation, exactly as `finishLaunch` does. An UNSTAMPED retry session is a
            // session the epoch machinery cannot see: `stampedEpoch` reads nil for it, so adopt and
            // `reconcilePhasesAtBoot` can never epoch-match it (the next daemon boot tears a perfectly
            // healthy retried session down and relaunches it, losing the agent's context), and its hooks
            // report with `observedEpoch == nil`, which skips the funnel's generation fence entirely — a
            // stale report from it can then land `.live` on a card a newer relaunch already owns.
            let env = withEpoch(adapter.env, live.sessionEpoch)
            let argv = adapter.start(ctx)
            let launchTask = t
            do {
                try await offActor { [sessions] in
                    _ = try sessions.kill(name)                      // reap the dead-pane session first
                    _ = try sessions.ensure(launchTask, argv: argv, env: env)
                    try? sessions.setRemainOnExit(name, window: "agent", on: true)
                }
                spawnPending[id] = Date().addingTimeInterval(Double(spawnGraceSeconds))
                emitActivity(.recovered, t, .daemon,
                             "restarted “\(t.title)” after a startup abort (retry \(attempt + 1))")
                return
            } catch {
                clearSpawnPending(id)
                await markDead(id, reason: .spawnExitedImmediately,
                               detail: evidence ?? "\(error)", source: .daemon)
                return
            }
        }
        // Out of retries → give up. Reap the dead-pane session, then mark dead WITH the captured evidence.
        clearSpawnPending(id)
        try? await offActor { [sessions] in try? sessions.kill(name) }
        await markDead(id, reason: .spawnExitedImmediately, detail: evidence, source: .daemon)
    }

    /// Converge an ORPHANED dead agent pane — a still-present session whose agent process exited but whose
    /// `spawnPending` record is gone (the daemon restarted inside the startup grace and lost the in-memory
    /// state, or an armed pane was orphaned some other way). Unlike `handleStartupAbort` there is NO retry
    /// budget to consult (it was lost with the pending record), so per the convergence contract we simply
    /// capture the surviving stderr, clear remain-on-exit, reap the session, and mark it dead — never loop.
    /// This is the safety net that guarantees such a card ALWAYS resolves instead of hanging "running".
    func resolveOrphanedDeadPane(_ t: Task) async {
        let id = t.id
        let name = sessions.sessionName(id)

        // Capture + host pulse in one hop (see `handleStartupAbort`): an orphaned dead pane on an exhausted
        // host is the same machine-wide fault, and deserves the same honest reason.
        let probe: (evidence: String?, resource: HostResourceReport?) = await offActorValue { [sessions] in
            let pane = (try? sessions.capture(name, window: "agent", maxChars: 4096))?.text
            let evidence = pane.flatMap { Self.startupEvidence(from: $0) }
            return (evidence, sessions.hostResourceFault(evidence: evidence))
        }

        // Re-validate after the capture await — don't fight an intentional teardown / concurrent conclusion
        // (a terminal phase = SessionEnd death or task_complete). This re-check is the race guard.
        guard let live = await store.get(id),
              !live.archived, !live.phase.isTerminal else { return }

        clearSpawnPending(id)   // belt-and-suspenders: no record is expected, but never leave one behind
        try? await offActor { [sessions] in
            try? sessions.setRemainOnExit(name, window: "agent", on: false)
            try? sessions.kill(name)
        }
        await markDead(id, reason: probe.resource != nil ? .resourceExhausted : .spawnExitedImmediately,
                       detail: probe.evidence, resource: probe.resource, source: .daemon)
    }

    /// Drop a card's startup-pending bookkeeping (on graduation, give-up, or any death).
    /// Deliberately does NOT touch `modelOverrideWatch`: this fires when a healthy card GRADUATES its
    /// startup grace, which is exactly when the re-seat watch still has its job to do. The watch is cleared
    /// where it genuinely dies — on a fresh re-seat (which re-arms it), and on ANY conclusion, in
    /// `concludeCard` (the single terminal chokepoint — `markDead` alone would miss a failed launch, which
    /// concludes through the steppers).
    func clearSpawnPending(_ id: UUID) {
        spawnPending[id] = nil; spawnAttempts[id] = nil; spawnRelaunch[id] = nil
    }

    /// Test hook: tighten the startup-confirmation grace + retry budget (production uses the defaults).
    /// Also RE-STAMPS any already-armed `spawnPending` deadline to the new grace, so a test that drives a
    /// card to `.live` (armed with the default grace) can then tighten the window without re-spawning.
    /// Test hook: hold/release the reconciler's bring-up claim for `id` (`inFlightSteps`), so a test can
    /// drive the interleavings that ONLY occur while a step owns the card — a report racing the bring-up,
    /// the adopt path racing its own in-flight step. Production sets this in `stepIfEligible`.
    func setStepInFlight(_ id: UUID, _ inFlight: Bool) {
        if inFlight { inFlightSteps.insert(id) } else { inFlightSteps.remove(id) }
    }

    /// Test hook: is a bring-up step still in flight for `id`? A step lands `.live` and only THEN returns, so
    /// a test that drives a card to `.live` and immediately manipulates its session can otherwise race the
    /// tail of that step (its `ensure` clears the dead-pane mark) — under parallel-suite load, minutes later.
    func hasStepInFlight(_ id: UUID) -> Bool { inFlightSteps.contains(id) }

    func setStartupConfirmation(graceSeconds: Int, maxRetries: Int) {
        spawnGraceSeconds = graceSeconds; maxStartupRetries = maxRetries
        let newDeadline = Date().addingTimeInterval(Double(graceSeconds))
        for id in spawnPending.keys { spawnPending[id] = newDeadline }
    }

    /// Distil captured pane text to its meaningful tail (last few non-empty lines), trimmed + capped, so
    /// `deadDetail` surfaces the real error ("usage limit", "unauthorized", a config parse error) not noise.
    static func startupEvidence(from pane: String) -> String? {
        let lines = pane.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return String(lines.suffix(6).joined(separator: " | ").prefix(500))
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
            resolveReadiness(id, true, via: .ticks)   // liveness fallback → HOLD the seed lease (B3)
        } else {
            launchReadyTicks[id] = n
        }
    }

    // MARK: - helpers

    /// Whether a card can be resumed. Capability-gated (design §5): resumability is an adapter answer
    /// keyed on `capabilities.sessionId` + `sessionInfo`, NOT a hardcoded `~/.claude` transcript stat in
    /// core. Both current variants require a stored session id and the adapter's own state path to be
    /// present on disk; a discovered agent with no id short-circuits.
    func isResumable(_ t: Task) async -> Bool {
        guard let adapter = try? registry.get(t.agentId) else { return false }
        switch adapter.capabilities.sessionId {
        case .seeded, .discovered:
            guard let sid = t.agentSessionId, !sid.isEmpty else { return false }
            let ctx = AdapterContext(cwd: t.cwd, sessionId: sid, name: t.title, orchestraBin: orchestraBin)
            let a = adapter, priorIds = t.priorSessionIds
            return (try? await offActor {
                guard let statePath = a.sessionInfo(ctx, current: sid, prior: priorIds)?.transcriptPath
                else { return false }
                return FileManager.default.fileExists(atPath: statePath)
            }) ?? false
        }
    }

    /// The funnel's wake-on-live release point (+Lifecycle step 7): a `send`/inbox-add that queued
    /// WHILE the card was being born had its `wake` no-op'd on the being-born phase, and the arm
    /// covers a `.dead` card — but a card landing `.live` after provisioning needs one nudge to drain
    /// what accumulated. `wake` re-checks every gate, so this is a no-op unless a genuinely claimable
    /// message remains, and it self-terminates (the delivered turn drains the inbox). The
    /// `hasClaimable` gate (B3 D5) keeps a card holding a `.ticks` relaunchSeed lease from re-waking
    /// itself into a kill loop.
    func wakeIfPending(_ id: UUID) async {
        // B3 D5, kept: gate on `hasClaimable`, NOT `!peek.isEmpty`. The funnel fires this on EVERY
        // `.live` landing (+Lifecycle wake-on-live), and `peek` returns leased messages too — so a
        // card that just landed `.live(.waiting)` HOLDING a `.ticks`-readiness relaunchSeed lease has
        // a non-empty peek and would be re-woken → a fresh resume → epoch bump → the held lease
        // re-claimed → the just-live session killed and re-delivered, in a loop. A held same-epoch
        // lease is NOT claimable, so `hasClaimable` leaves it alone until its held-confirm (or the
        // lease expires). B4's `hasLiveLease` guard inside `wake` backs this up. Phase gate goes
        // through `deliverable` so this stays in step with the ladder's target set.
        guard let t = await store.get(id), deliverable(t),
              await inbox.hasClaimable(id, epoch: t.sessionEpoch, now: now()) else { return }
        await wake(id)
    }

    /// The single terminal-death classifier. Routes through the funnel so a non-terminal → terminal death
    /// fires `concludeCard` (bug-#2 fix — a suspended `wait` resolves on a crash/reboot/resume-fail death,
    /// not just a clean exit). Callers pass a DELIBERATE classification (aliveNames miss / a fresh liveness
    /// probe / a definitive resume failure), so this transitions with `observedEpoch: nil` — exempt from
    /// the nil-epoch kill-probe gate (which lives at the inbound-SessionEnd signal site).
    func markDead(_ id: UUID, reason: DeadReason, detail: String?,
                  resource: HostResourceReport? = nil, source: ActivitySource) async {
        let result = await transition(id, to: .dead(reason), mutate: {
            $0.deadReason = reason; $0.deadDetail = detail; $0.deadResource = resource
        })
        guard result == .applied, let updated = await store.get(id) else { return }
        clearSpawnPending(id)   // a dead card is never startup-pending (covers give-up + any other death)
        modelOverrideWatch[id] = nil   // nothing left to confirm — the card is gone
        emitActivity(.dead, updated, source, "session lost (\(reason.rawValue))")
        // An exhausted host is a MACHINE-wide fault — every card's spawn/resume is failing, not just this
        // one — so it also gets a board-level warning naming the resource and what to do about it.
        if let resource {
            emitActivity(.warning, updated, source, "\(resource.headline) \(resource.resource.remedy)")
        }
    }

    /// Was this death actually the HOST giving out? Asked of the SESSION BACKEND (the thing that consumes
    /// the resource), evidence first and then a live probe — hopped off-actor, since it is a syscall plus a
    /// `/dev` census.
    ///
    /// The probe is what makes this real rather than string-matching theatre: a PTY-starved agent usually
    /// dies saying something entirely unrelated (the incident's spawn died with `ENOENT: Bun could not find
    /// a file`), so the only way to learn the truth is to ask whether a terminal can still be had.
    /// Returns nil when the host is healthy ⇒ the caller keeps its own classification.
    func diagnoseHost(evidence: String?) async -> HostResourceReport? {
        await offActorValue { [sessions] in sessions.hostResourceFault(evidence: evidence) }
    }

    private func awaitReadiness(_ id: UUID, graceSeconds: Int, expectedEpoch: Int) async -> ReadinessOutcome {
        // The confirmation may already have landed while we were relaunching off-actor (see
        // `pendingReadiness`). Consume it synchronously — before registering a waiter — so an early callback
        // confirms instantly instead of waiting out (or timing out) the grace. This block and the
        // registration below run without an intervening `await`, so no callback can slip between the check
        // and the registration on this serialized actor. The early signal is EPOCH-CHECKED (B3 D6): a stale
        // predecessor signal that landed in the register window can't confirm the new generation.
        if let early = pendingReadiness.removeValue(forKey: id) {
            if early == expectedEpoch { return .confirmed(via: .signal) }   // proven current-gen signal
            if early == nil { return .confirmed(via: .ticks) }              // unattributable → hold
            // else: a stale mismatched-epoch signal — dropped; register a fresh waiter below.
        }
        readinessTokenSeq &+= 1
        let token = readinessTokenSeq
        return await withCheckedContinuation { (cont: CheckedContinuation<ReadinessOutcome, Never>) in
            // A second relaunch for this id must NEVER leak the earlier continuation: resolve the displaced
            // waiter `.superseded` (the newer relaunch now owns the session). Without this,
            // `readinessWaiters[id] = …` would drop the old continuation unresumed → that relaunch hangs
            // forever → the idle card can never be woken again.
            if let old = readinessWaiters[id] { old.cont.resume(returning: .superseded) }
            readinessWaiters[id] = (token, expectedEpoch, cont)
            let grace = max(0, graceSeconds)
            _Concurrency.Task { [weak self, clock] in
                try? await clock.sleep(for: .seconds(grace))
                await self?.timeoutReadiness(id, token: token)
            }
        }
    }

    /// Resolve a being-born card's readiness waiter. A `.signal` (positive session signal) confirms the
    /// waiter ONLY when `observedEpoch` matches the generation the waiter was armed for — a stale predecessor
    /// signal (or one from a superseded relaunch) is IGNORED, leaving the waiter for a genuine current-gen
    /// signal / the tick fallback / the grace timeout (B3 D6). A `.ticks` resolution (the N=3 liveness
    /// fallback) and an unattributable nil-epoch signal resolve as `.ticks` (hold the seed). `ok == false`
    /// times the waiter out as before.
    func resolveReadiness(_ id: UUID, _ ok: Bool, observedEpoch: Int? = nil, via: ReadinessVia = .signal) {
        if let w = readinessWaiters[id] {
            guard ok else {
                readinessWaiters.removeValue(forKey: id)
                w.cont.resume(returning: .timedOut)
                return
            }
            let resolvedVia: ReadinessVia
            if via == .ticks {
                resolvedVia = .ticks
            } else if let observedEpoch {
                guard observedEpoch == w.expectedEpoch else { return }   // stale-gen signal → ignore, keep waiting
                resolvedVia = .signal
            } else {
                resolvedVia = .ticks   // a signal we can't attribute to the current generation → hold, fail-safe
            }
            readinessWaiters.removeValue(forKey: id)
            w.cont.resume(returning: .confirmed(via: resolvedVia))
        } else if ok {
            // No waiter yet: `awaitReadiness` hasn't registered (the relaunch is still bringing the session
            // up off-actor). Remember this confirmation — WITH its epoch — so the waiter epoch-checks it on
            // consume. Ticks never reach here (the tick resolvers only fire while a waiter is registered).
            pendingReadiness[id] = observedEpoch
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

    /// Non-throwing twin of `offActor` for pure, read-only work that returns a value and never throws
    /// (e.g. the git-only `TreeStat`/`DiffStat` recomputes fired from the hot report funnel). Offloading
    /// the blocking `git` subprocess off the actor lets the actor keep servicing other cards' reports and
    /// events instead of serializing behind one card's `git diff`/`rev-list` — the branch-tree contention.
    /// Only the read-only compute moves off-actor; the caller keeps every state read/write/emit on-actor.
    nonisolated func offActorValue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async { cont.resume(returning: work()) }
        }
    }

    /// Async-closure twin of `offActor` (Task 5, proc threading): git probes that now route through the
    /// async `ProcRunning` seam can no longer live in a sync closure. `Task.detached` keeps the body off
    /// the caller's actor exactly like the DispatchQueue hop — `RealProc` still blocks only the detached
    /// task's thread, and a `FakeProc` gate SUSPENDS there instead of wedging a dispatch thread.
    nonisolated func offActor<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await _Concurrency.Task.detached { try await work() }.value
    }

    /// Async-closure twin of `offActorValue` — see the async `offActor` overload above.
    nonisolated func offActorValue<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        await _Concurrency.Task.detached { await work() }.value
    }
}
