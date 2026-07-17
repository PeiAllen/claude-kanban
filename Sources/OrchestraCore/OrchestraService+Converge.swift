import Foundation

/// Stage-4 convergence: the service-actor callbacks a `PhaseStepper` delegates to (so the duties that
/// touch actor-private state — `lineage`, `remoteParents`, `readinessWaiters`, `derivedCard`, `wake` —
/// stay on the actor while the steppers themselves stay thin, stateless, off-actor structs). These are
/// the extracted forms of spawn's inline materialization / `launchAndConfirm`'s readiness machinery /
/// `archive()`'s duty list, read from the PERSISTED card so crash recovery re-derives everything from disk.
extension OrchestraService {

    // MARK: - materialize (extracted spawn materialization; MaterializeStepper delegates here)

    /// Materialize a `.creatingWorktree` card's cwd: remote-base fetch (`remoteParents.fetch`) →
    /// `worktrees.ensure` → stale-child prune + lineage recording (`recordSpawnBase`/`recordSpawnRemoteBase`)
    /// → the S2-3(iii) rollback on a lineage failure → the resource epilogue (release the just-cut tree if a
    /// newer intent made the card terminal during the `ensure` await). Reads `spawnBase`/branch from the
    /// persisted card and re-derives the remote/local classification with `RemoteParentRef.parse` (so a
    /// remote base survives a restart). Mirrors today's inline spawn body (`OrchestraService.swift:329-401`).
    func materialize(_ id: UUID) async -> MaterializeOutcome {
        guard let card = await store.get(id) else { return .failed(detail: "unknown card \(id)") }
        // Scratch dirs are materialized synchronously (mkdir) — ensure the dir exists, then advance.
        if card.origin == .scratch {
            try? FileManager.default.createDirectory(atPath: card.cwd, withIntermediateDirectories: true)
        }
        // Only `.worktree` cards fetch/ensure/record; scratch + borrowed already have their cwd.
        guard card.origin == .worktree else { return .launching(parentBranch: card.parentBranch) }

        let realRepo: String
        do { realRepo = try resolver.resolveRepo(card.repo) }
        catch { return .failed(detail: "repo not resolvable: \(error)") }

        // Re-derive the base classification from the persisted carrier (identical to spawn's inline path).
        let trimmedBase = card.spawnBase?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBase: String? = (trimmedBase?.isEmpty == false) ? trimmedBase : nil
        let remotesForBase = (try? await offActor { self.gitRemotes(repo: realRepo) }) ?? []
        let remoteRef = normalizedBase.flatMap { RemoteParentRef.parse($0, remotes: remotesForBase) }
        var remoteFetchedOID: String? = nil
        var ensureBase = normalizedBase
        if let remoteRef {
            let b = normalizedBase ?? remoteRef.canonical
            do {
                remoteFetchedOID = try await remoteParents.fetch(
                    repo: realRepo, remoteRef, context: "spawn base \(b): could not fetch remote parent \(b)")
            } catch { return .failed(detail: "\(error)") }   // remote fetch failed → no worktree cut
            ensureBase = remoteRef.privateRef
        }

        // Cut (or adopt) the worktree.
        let ensured: Worktree
        do { ensured = try await worktrees.ensure(repo: realRepo, branch: card.branch, cardId: id, base: ensureBase) }
        catch { return .failed(detail: materializeFailureDetail(error)) }

        // Resource epilogue: re-read on-actor AFTER the ensure await — if a newer intent (archive / kill)
        // made the card terminal meanwhile, release what we just acquired and do NOT advance.
        if let now = await store.get(id), now.phase.isTerminal {
            _ = try? await worktrees.release(cardId: id, cards: await store.all(), force: false)
            return .terminalNoop
        }

        // Stale-child prune (S2-3(ii)) + lineage recording (S2-3(iii) rollback on failure).
        var derivedParentBranch: String? = card.parentBranch
        // A brand-new branch had no children before it existed, so record the base directly; a branch the
        // `ensure` found PRE-EXISTING is either a durable-lineage card (churn — derive from config, ignore
        // base) OR the crash-window case (a prior materialize run cut the branch but crashed BEFORE
        // `recordSpawnBase` ran — the branch exists yet has no link). Task-1 Minor #2: a re-run must then
        // RE-RECORD the carried base so the parent link is not lost. Distinguish the two by whether a durable
        // link is already present.
        let recordBase: Bool
        if !ensured.branchExisted {
            recordBase = true
        } else {
            recordBase = (await lineage.read(repo: realRepo, branch: card.branch)?.parent == nil)
        }
        do {
            if !ensured.branchExisted {
                for stale in await lineage.children(repo: realRepo, of: card.branch) {
                    try? await lineage.clear(repo: realRepo, branch: stale)
                }
            }
            if !recordBase {
                // Existing branch with a durable link: `base` is deliberately ignored (L2 contract).
                derivedParentBranch = await lineage.read(repo: realRepo, branch: card.branch)?.parent
            } else if let remoteRef, let oid = remoteFetchedOID {
                derivedParentBranch = try await recordSpawnRemoteBase(
                    repo: realRepo, branch: card.branch, ref: remoteRef, oid: oid)
            } else if let base = normalizedBase {
                derivedParentBranch = try await recordSpawnBase(repo: realRepo, branch: card.branch, base: base)
            } else {
                derivedParentBranch = nil   // no base → no lineage
            }
        } catch {
            // Roll back the cut worktree + brand-new branch (routes the tree through the SINGLE removal
            // policy so a shared/dirty tree is never force-dropped). The `git branch -D` hops off-actor
            // (Task-1 Minor #3) so the actor keeps servicing `report` during the rollback.
            _ = try? await worktrees.release(cardId: id, cards: await store.all(), force: false)
            if !ensured.branchExisted {
                let ctl = Duration.seconds(config.controlTimeout)
                _ = await offActorValue { [proc] in
                    try? await proc.run(["git", "-C", realRepo, "branch", "-D", card.branch],
                                        cwd: nil, env: [:], timeout: ctl)
                }
            }
            return .failed(detail: "spawn rolled back (worktree/branch removed): \(error)")
        }
        // BT6: a fresh remote-base spawn opts into merge-watch (moved off spawn's inline tail — spawn no
        // longer knows the derived parent). Start it now that the remote lineage is recorded.
        let remotesForWatch = (try? await offActor { self.gitRemotes(repo: realRepo) }) ?? []
        if RemoteParentRef.parse(derivedParentBranch ?? "", remotes: remotesForWatch) != nil,
           await lineage.read(repo: realRepo, branch: card.branch)?.watch == true {
            startRemoteWatch(cardId: id)
        }
        return .launching(parentBranch: derivedParentBranch)
    }

    /// Classify a `worktrees.ensure` failure — a timeout gets an explicit "timed out after Ns" detail
    /// (no generic passthrough) so the surfaced `deadDetail` names the wait, not a bare git error.
    private func materializeFailureDetail(_ error: Error) -> String {
        let s = String(describing: error)
        let low = s.lowercased()
        if low.contains("timed out") || low.contains("timeout") {
            return "worktree checkout timed out after \(config.worktreeAddTimeout)s"
        }
        return s
    }

    // MARK: - finishLaunch (extracted launchAndConfirm bring-up; Launch/Relaunch steppers delegate here)

    /// Bring the agent session up off-actor + confirm readiness (capability-gated), keeping the readiness
    /// machinery (`readinessWaiters`/`pendingReadiness`/`launchReadyTicks`) + the `ORCH_EPOCH` stamp
    /// actor-owned. Does NOT write `phase` — the caller stepper does (via `ctx.transition`) based on the
    /// returned `ReadinessOutcome`. Always kills the predecessor session before `ensure` (idempotent for a
    /// fresh launch), so the relaunch kill→ensure ordering holds. A `.resume` whose transcript vanished or
    /// an `ensure` throw yields `.timedOut` (the stepper's own pre-checks classify the real failure paths).
    ///
    /// FENCED on the phase + generation the step was DISPATCHED for (`expecting`/`epoch`). A step is
    /// dispatched off a snapshot and runs asynchronously, so the card can leave that phase before the step
    /// arrives here — the reconciler's adopt path lands a `.launching` card whose session came up, and
    /// `report()`'s SessionStart(clear/resume) writes `.live` directly. Since the bring-up is a `kill` +
    /// `ensure`, an unfenced stale step would tear a LIVE agent's session down and replace it with a fresh
    /// one. It stands down `.superseded` instead — the same single-winner discipline the funnel applies to
    /// phase writes, extended to the side effects.
    func finishLaunch(_ id: UUID, flavor: LaunchFlavor,
                      expecting: Phase.Kind, epoch expectedEpoch: Int) async -> ReadinessOutcome {
        guard let task = await store.get(id), let adapter = try? registry.get(task.agentId) else {
            return .timedOut
        }
        guard task.phase.kind == expecting, task.sessionEpoch == expectedEpoch else {
            return .superseded   // a newer landing/generation owns the card — never bring up under it
        }
        let epoch = task.sessionEpoch
        let grace = config.revivalGraceSeconds
        let env = withEpoch(adapter.env, epoch)   // stamp the current generation into the session env
        let trustDecision = await resolveTrust(origin: task.origin, cwd: task.cwd, repo: task.repo)
        pendingReadiness.remove(id)   // start clean so only THIS bring-up's signal can confirm it

        let argv: [String]
        // Startup-abort retry spec (folded from spawn-startup-abort-classification): captured only for a
        // fresh spawn's blank launch so a bounded retry can re-`ensure` the SAME session + cwd.
        var armCtx: AdapterContext? = nil
        // A staged `--model` re-seat (restart/handoff/resume) WINS over `model` for the launch. It has to:
        // restart/resume are intent-only, so the outgoing session stays alive and reporting for a reconcile
        // tick after the verb writes the card, and its statusline's model — applied through report()'s
        // field-delta half, which is NOT epoch-fenced — would otherwise revert `model` back to the old one
        // right here, and the re-seat would relaunch on the model it was trying to leave. `pendingModel` is
        // never touched by report() (it is absent from `applyReportFields`), so it survives that window.
        let launchModel = task.pendingModel ?? task.model.id
        switch flavor {
        case .blank(_, let prompt):
            let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: launchModel, startIn: task.startIn,
                                     sessionId: task.agentSessionId, prompt: prompt, name: task.title,
                                     orchestraBin: orchestraBin,
                                     access: task.access, trustCwd: trustDecision == .trusted,
                                     orchestraMCPBin: orchestraMCPBin,
                                     autoInstallMCPGlobally: config.autoInstallMCPGlobally)
            let a = adapter, c = ctx
            try? await offActor { try? a.prepareToLaunch(c) }
            argv = adapter.start(ctx)
            armCtx = ctx
        case .resume(let seed):
            // Every card-derived launch flag the `.blank` ctx carries must be carried HERE too. Both were
            // being dropped on resume, because this context is built field-by-field and simply omitted them:
            //  • `access` — `AdapterContext` defaults it to `.readWrite`, and both adapters emit their
            //    lockdown flags from `ctx.access` on resume as well as on start, so a READ-ONLY card came
            //    back writable.
            //  • `startIn` — not merely a board column: `.plan` becomes `--permission-mode auto`
            //    (ClaudeCodeAdapter.swift:204-206), so a resumed plan card silently lost it and began
            //    prompting for permissions mid-task.
            let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: launchModel, startIn: task.startIn,
                                     sessionId: task.agentSessionId, name: task.title, orchestraBin: orchestraBin,
                                     access: task.access,
                                     trustCwd: trustDecision == .trusted, seed: seed,
                                     orchestraMCPBin: orchestraMCPBin,
                                     autoInstallMCPGlobally: config.autoInstallMCPGlobally)
            guard let sid = task.agentSessionId else { return .timedOut }
            let a = adapter, c = ctx, priorIds = task.priorSessionIds
            // 5.1.3 pattern: hop the adapter's fs-touching sessionInfo() + the transcript existence check
            // off-actor before the `.timedOut` decision — same guard, same short-circuit order.
            let transcriptOK: Bool = (try? await offActor {
                guard let info = a.sessionInfo(c, current: sid, prior: priorIds),
                      let tp = info.transcriptPath else { return false }
                return FileManager.default.fileExists(atPath: tp)
            }) ?? false
            guard transcriptOK, let resumeArgv = adapter.resume(ctx) else {
                return .timedOut   // transcript vanished between the stepper's pre-check and here
            }
            try? await offActor { try? a.prepareToLaunch(c) }
            argv = resumeArgv
        }
        // RE-VERIFY OWNERSHIP IMMEDIATELY BEFORE THE DESTRUCTIVE HOP. The entry fence is a check, not a
        // lease: everything above suspends the actor (trust resolve, `prepareToLaunch`, the resume transcript
        // stat), and the launch-timeout `markDead` runs OUTSIDE the `bringingUp` gate — deliberately, since
        // it is what keeps a wedged bring-up converging. So the card really can go terminal under us here.
        guard await stillOwns(id, expecting: expecting, epoch: expectedEpoch) else { return .superseded }
        // HOST PREFLIGHT — before the DESTRUCTIVE hop, not after it. The bring-up is `kill` THEN `ensure`,
        // so on a host with no pseudo-terminals left a resume would reap the card's perfectly good session
        // and then be unable to recreate it: a live, working agent is destroyed and written down as dead by
        // a machine-wide condition it had nothing to do with. Asking the host for one pty first (a syscall,
        // ~microseconds, released immediately) turns that into a clean, honest, retryable refusal that
        // leaves the existing session ALONE. Fails open: an inconclusive probe launches as before.
        if let report = await diagnoseHost(evidence: nil) {
            return .launchFailed(LaunchFailure(
                detail: "preflight: the host could not provide a \(report.resource.rawValue) "
                      + "(session not started, existing session left intact)", resource: report))
        }
        do {
            try await offActor { [sessions] in
                _ = try? sessions.kill(sessions.sessionName(id))   // idempotent for a fresh launch
                _ = try sessions.ensure(task, argv: argv, env: env)
            }
        } catch {
            // The tmux stderr IS the diagnosis ("create window failed: fork failed: Device not configured")
            // — surface it instead of discarding it and letting the launch grace expire into a bogus
            // "launch timed out after 30s". That discard is precisely why an out-of-PTYs host looked like a
            // broken Orchestra. Unrecognised errors still land on the caller's existing reason, so nothing
            // is reclassified that we don't positively recognise. `.io`'s payload is unwrapped so the detail
            // reads as the raw tmux stderr rather than "io error: …".
            let detail: String
            if case .io(let stderr)? = error as? OrchestraError { detail = stderr } else { detail = "\(error)" }
            return .launchFailed(LaunchFailure(detail: detail,
                                               resource: await diagnoseHost(evidence: detail)))
        }
        // …AND AGAIN AFTER IT. The hop is a window the actor cannot be held across, so the card may have gone
        // terminal (or been superseded) while the session was coming up. Nothing else would ever reap that
        // session — the orphan sweep only touches archived/absent cards, and reconcile's `.dead` case is a
        // no-op — so a real tmux session + agent process would leak under a dead card, across daemon
        // restarts. Reap it ourselves. Only ever kill a session stamped with OUR generation: a newer relaunch
        // that already `ensure`d owns the same session NAME, and killing that one would be this very bug.
        //
        // The probe and the kill are two separate tmux calls, so they are not atomic — which is safe ONLY
        // because of the single-bring-up-per-card invariant: `stepIfEligible` takes the `inFlightSteps` claim
        // SYNCHRONOUSLY before dispatching, and `runStep` releases it only after the step (this function
        // included) has returned, so a newer generation's bring-up cannot `kill`+`ensure` between our probe
        // and our kill — it has not been dispatched yet. The other `ensure` sites can't race us either: the
        // startup-abort retry is gated on a `.live` card (ours is still being born), and `openShell`/`exec`
        // create an UNSTAMPED session, which the epoch check below declines to kill. If that invariant is ever
        // relaxed, this reap needs a real per-card session lock. (Pinned by `test_noSecondBringUpWhileInFlight`.)
        guard await stillOwns(id, expecting: expecting, epoch: expectedEpoch) else {
            // Fail-safe by direction: we only ever kill a session we can PROVE is ours, so a probe that
            // fails (a tmux hiccup, or a `SessionManaging` conformer that doesn't override `stampedEpoch` —
            // the protocol default returns nil) declines to kill rather than killing someone else's session.
            // But a decline means the leak this reap exists to prevent has silently recurred, so say so:
            // an unreapable session is an operator-visible warning, not a silent orphan.
            let probe: (alive: Bool, stamped: Int?) = (try? await offActor { [sessions] in
                let name = sessions.sessionName(id)
                let alive = (try? sessions.isAlive(name)) ?? false
                let stamped = (try? sessions.stampedEpoch(name: name)) ?? nil
                if stamped == expectedEpoch { _ = try? sessions.kill(name) }   // ours ⇒ reap it
                return (alive, stamped)
            }) ?? (false, nil)
            if probe.alive, probe.stamped == nil, let now = await store.get(id) {
                emitActivity(.warning, now, .daemon,
                             "superseded bring-up could not verify its session's generation — "
                             + "\(sessions.sessionName(id)) may be left behind")
            }
            return .superseded
        }
        // STARTUP-ABORT ARM (folded from spawn-startup-abort-classification): for a FRESH spawn (phase
        // `.launching` — the LaunchStepper, not a `.relaunching` restart/resume), keep the dying pane's
        // output for capture (remain-on-exit) and mark the card startup-pending so the reconcile/liveness
        // pass classifies an immediate exit as `.spawnExitedImmediately` (captured + bounded-retried)
        // instead of the generic `.sessionVanished`. Agent-agnostic — capability profiles differ, the arm
        // does not.
        if expecting == .launching, let ctx = armCtx {   // still-owned `.launching` (re-verified above)
            let name = sessions.sessionName(id)
            try? await offActor { [sessions] in try sessions.setRemainOnExit(name, window: "agent", on: true) }
            spawnPending[id] = Date().addingTimeInterval(Double(spawnGraceSeconds))
            spawnAttempts[id] = 0
            spawnRelaunch[id] = (adapter.id, ctx)
        }
        return await confirmReadiness(id, adapter: adapter, graceSeconds: grace)
    }

    /// Does this bring-up still own the card — is it still in the phase + generation its step was dispatched
    /// for? The single ownership predicate behind the fence (checked on entry, before the destructive hop,
    /// and again after it).
    private func stillOwns(_ id: UUID, expecting: Phase.Kind, epoch: Int) async -> Bool {
        guard let now = await store.get(id) else { return false }
        return now.phase.kind == expecting && now.sessionEpoch == epoch
    }

    // MARK: - teardownActorDuties (extracted archive() actor-bound duties; TeardownStepper delegates here)

    /// The archive duties that touch actor-private state: cancel this card's treeStat/child-fanout
    /// debounces + remote merge-watch + merge-request re-nudge, drop its seq cursor, AND find→nudge→wake
    /// its live children (needs `lineage.children`/`derivedCard`/`wake`). The child nudge carries a
    /// `dedupKey` so a crash-then-redrive of Teardown fires it AT MOST ONCE. Session-kill / releaseBorrow /
    /// run-dir reclaim stay in the stepper (reachable via `ctx`).
    func teardownActorDuties(_ id: UUID) async {
        guard let t = await store.get(id) else { return }
        stopRemoteWatch(id)          // BT6: tear down any remote merge-watch
        remoteWatchGen[id] = nil     // S4: drop its generation entry (bounds the map)
        stopMergeRequestNudge(id)    // O2: tear down any pending merge-request re-nudge loop
        mergeRequestNudgeGen[id] = nil   // drop its generation entry (bounds the map, as remoteWatchGen does)
        treeStatDebounce[id]?.cancel(); treeStatDebounce[id] = nil     // S3-5
        childFanoutDebounce[id]?.cancel(); childFanoutDebounce[id] = nil
        lastSeqStore[id] = nil       // the agent is gone; don't leak its seq cursor
        clearSpawnPending(id)        // an archived card is never startup-pending — don't let a retry resurrect it
        observedSessions[id] = nil   // PR5 actor-hygiene Task 5.2: drop the boardSnapshot session cache entry
        // S2-5: a worktree card's branch goes bare on archive — nudge its live children (deterministic,
        // oldest) so a stopped child re-evaluates its ship path instead of waiting on a dead inbox.
        guard t.origin == .worktree else { return }
        let childBranches = await lineage.children(repo: t.repo, of: t.branch)
        guard !childBranches.isEmpty else { return }
        let active = await store.all().filter { $0.id != id }
        for cb in childBranches {
            guard let card = derivedCard(repo: t.repo, branch: cb, among: active) else { continue }
            try? await inbox.enqueue(
                card.id,
                "parent card \(t.branch) archived — the parent branch is now bare; re-run your ship",
                dedupKey: "\(card.id.uuidString.lowercased())|parent-archived:\(t.branch)")
            await wake(card.id)
        }
    }
}
