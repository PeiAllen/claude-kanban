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
    /// remote base survives a restart). Mirrors today's inline spawn body (`OrchestraService.swift`).
    func materialize(_ id: UUID) async -> MaterializeOutcome {
        guard let card = await store.get(id) else { return .failed(detail: "unknown card \(id)") }
        ensureRuntime(for: card)   // the spawn-path create site (A1): a being-born card gets its entry here
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

    /// Mark (or clear) the generation that owes a MACHINE opening turn — a launch whose flavor delivers a
    /// daemon-supplied positional (a spawn/handoff seed, or a wake-delivered inbox batch). That positional
    /// reaches the report path as a `promptText` just like a typed prompt, and a resume lands
    /// `.waiting(.humanTurn)`, so the human-paced setter consumes this marker on the generation's first
    /// prompt rather than reading the seed as a human turn (see `CardRuntime.seedTurnEpoch`). Called by
    /// EVERY path that lands a seeded session `.live`: `finishLaunch` (the steppers) AND the reconciler's
    /// epoch-identity adopt, which jumps `.launching→.live` WITHOUT a stepper. A promptless blank launch
    /// delivers no positional, so its first prompt IS a human turn — the marker is cleared.
    func markSeedTurn(_ id: UUID, flavor: LaunchFlavor, epoch: Int) {
        let deliversMachineTurn: Bool
        switch flavor {
        case .blank(_, let p): deliversMachineTurn = !(p ?? "").isEmpty
        case .resume(let s):   deliversMachineTurn = !(s ?? "").isEmpty
        }
        runtime[id]?.seedTurnEpoch = deliversMachineTurn ? epoch : nil
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
        runtime[id]?.pendingReadiness = nil   // start clean so only THIS bring-up's signal can confirm it
        markSeedTurn(id, flavor: flavor, epoch: epoch)   // this generation may owe a machine opening turn

        let argv: [String]
        // Startup-abort retry spec (folded from spawn-startup-abort-classification): captured only for a
        // fresh spawn's blank launch so a bounded retry can re-`ensure` the SAME session + cwd.
        var armCtx: AdapterContext? = nil
        // B3 tail watermark: for a fileTail RESUME (Codex — same rollout carries forward), the rollout path
        // whose post-kill EOF fences a held relaunchSeed lease's confirm. nil for a blank launch, a
        // non-fileTail agent (Claude confirms via the epoch-matched hook, not the tail), or no rollout.
        var tailWatermarkPath: String? = nil
        // A staged `--model` re-seat (restart/handoff/resume) WINS over `model` for the launch. It has to:
        // restart/resume are intent-only, so the outgoing session stays alive and reporting for a reconcile
        // tick after the verb writes the card, and its statusline's model — applied through report()'s
        // field-delta half, which is NOT epoch-fenced — would otherwise revert `model` back to the old one
        // right here, and the re-seat would relaunch on the model it was trying to leave. `pendingModel` is
        // never touched by report() (it is absent from `applyReportFields`), so it survives that window.
        let launchModel = task.pendingModel ?? task.model.id
        let observationEndpoint = adapter.observationEndpoint(
            cardRef: task.shortId,
            runtimeStateDir: config.runtimeStateDir
        )
        switch flavor {
        case .blank(_, let prompt):
            let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: launchModel, startIn: task.startIn,
                                     sessionId: task.agentSessionId, prompt: prompt, name: task.title,
                                     orchestraBin: orchestraBin,
                                     access: task.access, trustCwd: trustDecision == .trusted,
                                     orchestraMCPBin: orchestraMCPBin,
                                     autoInstallMCPGlobally: config.autoInstallMCPGlobally,
                                     observationEndpoint: observationEndpoint)
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
            //    (ClaudeCodeAdapter.swift), so a resumed plan card silently lost it and began
            //    prompting for permissions mid-task.
            let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: launchModel, startIn: task.startIn,
                                     sessionId: task.agentSessionId, name: task.title, orchestraBin: orchestraBin,
                                     access: task.access,
                                     trustCwd: trustDecision == .trusted, seed: seed,
                                     orchestraMCPBin: orchestraMCPBin,
                                     autoInstallMCPGlobally: config.autoInstallMCPGlobally,
                                     observationEndpoint: observationEndpoint)
            guard let sid = task.agentSessionId else { return .timedOut }
            let a = adapter, c = ctx, priorIds = task.priorSessionIds
            // 5.1.3 pattern: hop the adapter's fs-touching sessionInfo() + the transcript existence check
            // off-actor before the `.timedOut` decision — same guard, same short-circuit order. B3: also
            // yield the resolved transcript/rollout PATH (nil unless it exists) so a fileTail resume can
            // fence its held lease on that exact path.
            let resolvedTranscript: String? = (try? await offActor { () -> String? in
                guard let info = a.sessionInfo(c, current: sid, prior: priorIds),
                      let tp = info.transcriptPath, FileManager.default.fileExists(atPath: tp) else { return nil }
                return tp
            }) ?? nil
            guard let resolvedTranscript, let resumeArgv = adapter.resume(ctx) else {
                return .timedOut   // transcript vanished between the stepper's pre-check and here
            }
            // Only a fileTail agent confirms its held lease by rollout provenance; a hooksPush agent (Claude)
            // uses the epoch-matched hook, so it needs no watermark (and its transcript is not a tailed rollout).
            if adapter.capabilities.telemetry == .fileTail { tailWatermarkPath = resolvedTranscript }
            try? await offActor { try? a.prepareToLaunch(c) }
            argv = resumeArgv
        }
        // PRE-ARM THE SESSION-NAME MIRROR with the `--name` this argv just captured. It has to happen HERE,
        // before the session can exist: `ensure` returns the moment tmux has the session, so the new agent
        // can emit its first statusline before any later write lands — and if a `set-title` arrived while
        // this launch was in flight (it changes neither phase nor epoch), that first report would compare the
        // LAUNCHED name against a stale baseline and the NEW title, look exactly like a rename, and overwrite
        // the name the human just set. Arming first makes the new generation's opening report provably an
        // echo. The predecessor cannot exploit the early write: report()'s mirror admits only
        // current-generation reports, and the outgoing session reports under the old epoch.
        // Guarded on the epoch we are launching, because `store.update` suspends: a newer relaunch that won
        // the race owns the baseline, and ours would be stale.
        if !task.title.isEmpty,
           let (named, namedRev) = try? await store.update(id, { t in
               guard t.sessionEpoch == expectedEpoch else { return }   // superseded under us — drop the write
               t.lastSessionName = task.title
           }) {
            emit(.taskUpserted(named), rev: namedRev)
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
        let capturedWatermark: Int64?
        let watermarkPath = tailWatermarkPath   // immutable copy for the @Sendable hop
        do {
            // B3 watermark capture: kill → eofOffset → ensure, ALL in this one off-actor hop. The EOF is read
            // AFTER the predecessor is killed (so it cannot append past the fence) and BEFORE the new session
            // is launched (so the new session hasn't written yet). `eofOffset` is a stateless stat, so it runs
            // inside this hop with no extra actor suspension — tightening the fence. A blank/non-fileTail
            // launch has `watermarkPath == nil` and captures nothing.
            capturedWatermark = try await offActor { [sessions] () -> Int64? in
                _ = try? sessions.kill(sessions.sessionName(id))   // idempotent for a fresh launch
                let wm = watermarkPath.map { RolloutTailer.eofOffset(path: $0) }
                _ = try sessions.ensure(task, argv: argv, env: env)
                return wm
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
            runtime[id]?.spawnPending = Date().addingTimeInterval(Double(spawnGraceSeconds))
            runtime[id]?.spawnAttempts = 0
            runtime[id]?.spawnRelaunch = (adapter.id, ctx)
        }
        // B3: stamp the post-kill watermark + rollout path on the held relaunchSeed lease (fileTail resume
        // only). Done AFTER the ensure + the ownership re-check (a superseded bring-up returned above, so its
        // watermark never lands), and BEFORE readiness — so a rollout line tailed during the readiness wait is
        // fenced. A no-op when there is no held lease (a handoff-only or seedless relaunch).
        if let watermarkPath, let capturedWatermark {
            // Seed the tail cursor at the same watermark: teardown `forget`s the cursor, and without a
            // seed the next tail would re-read the rollout from byte 0 — replaying historic lines into
            // the seq-gated status funnel (whose lastSeq the detach also reset).
            await tailer.seedCursor(id, at: UInt64(max(0, capturedWatermark)))
            try? await inbox.setTailWatermark(cardId: id, epoch: expectedEpoch,
                                              watermark: capturedWatermark, path: watermarkPath)
        }
        return await confirmReadiness(id, adapter: adapter, graceSeconds: grace, expectedEpoch: expectedEpoch)
    }

    /// Does this bring-up still own the card — is it still in the phase + generation its step was dispatched
    /// for? The single ownership predicate behind the fence (checked on entry, before the destructive hop,
    /// and again after it).
    private func stillOwns(_ id: UUID, expecting: Phase.Kind, epoch: Int) async -> Bool {
        guard let now = await store.get(id) else { return false }
        return now.phase.kind == expecting && now.sessionEpoch == epoch
    }

    // MARK: - teardownActorDuties (extracted archive() actor-bound duties; TeardownStepper delegates here)

    /// Step 4 of teardown, in two halves with different redrive contracts, authorized by the LEASE —
    /// the card's persisted `.archivedPending` phase + the `sessionEpoch` the step was dispatched with.
    /// A reopen bumps the epoch at `.creatingWorktree`, so a stale teardown that lost the race stands
    /// down without mutating anything; a crash-redrive re-dispatches with the CURRENT epoch and
    /// proceeds (the lease is persisted state — an in-memory fence could not authorize it).
    ///
    /// 1. `detachCardRuntime` — the in-memory half: cancel the armed-task bag, resume any readiness
    ///    waiter `.superseded`, tombstone terminal ownership, drop `runtime[id]`. No-op-safe when absent.
    /// 2. Durable duties — idempotent, re-run on every redrive, gated on the lease and NEVER on runtime
    ///    presence: the card-file sweep, the watcher-side watch-registry removal (persisted), and the
    ///    child find→nudge→wake (dedup-keyed, so a redrive fires it AT MOST ONCE).
    /// Session-kill / releaseBorrow / run-dir reclaim stay in the stepper (reachable via `ctx`).
    func teardownActorDuties(_ id: UUID, expectedEpoch: Int) async {
        guard await stillOwns(id, expecting: .archivedPending, epoch: expectedEpoch) else { return }
        // Tailer cursor drop is a cross-actor await, so it runs BEFORE the synchronous detach and the
        // lease is re-checked after it. (Bring-up seeds a fresh cursor at the session's rollout EOF, so
        // even a forget that races a reopen cannot cause a history replay — see the seed in
        // `pollTelemetry`/`finishLaunch`.)
        await tailer.forget(id)
        guard await stillOwns(id, expecting: .archivedPending, epoch: expectedEpoch) else { return }
        detachCardRuntime(id)   // in-memory half — synchronous on the actor
        // Durable: the archived card's launch-config file is now orphaned (step 1 killed its session).
        // A full keep-set sweep reclaims it and is shared-cwd-safe for free; mtime grace errs to keeping.
        await sweepCardFiles()
        // Re-fence after the sweep's suspension: the PERSISTED watcher-key removal below must never
        // run for a card a reopen just took back (it would silently drop the reopened card's watches).
        guard await stillOwns(id, expecting: .archivedPending, epoch: expectedEpoch) else { return }
        // Durable: the watcher side of the PERSISTED watch registry — the child side is removed at
        // `concludeCard`, but nothing else ever removes an archived watcher's own key from disk.
        // Load-before-mutate + conditional save is the same protocol as every registry mutation (the
        // control server accepts RPCs before boot's reload; a bare save would clobber the file).
        ensureWatchRegistryLoaded()
        if watchRegistry.removeValue(forKey: id) != nil, !watchRegistryLoadFailed {
            watchStore.save(watchRegistry)
        }
        // Re-fence after the suspensions above before the store-derived child nudge below.
        guard await stillOwns(id, expecting: .archivedPending, epoch: expectedEpoch),
              let t = await store.get(id) else { return }
        // S2-5: a worktree card's branch goes bare on archive — nudge its live children (deterministic,
        // oldest) so a stopped child re-evaluates its ship path instead of waiting on a dead inbox.
        guard t.origin == .worktree else { return }
        let childBranches = await lineage.children(repo: t.repo, of: t.branch)
        guard !childBranches.isEmpty else { return }
        let active = await store.all().filter { $0.id != id }
        for cb in childBranches {
            guard let card = derivedCard(repo: t.repo, branch: cb, among: active) else { continue }
            // Per-iteration lease check: each pass suspends (enqueue + wake), and a reopen mid-loop
            // must stop the remaining "parent archived" nudges — the parent is coming back.
            guard await stillOwns(id, expecting: .archivedPending, epoch: expectedEpoch) else { return }
            try? await inbox.enqueue(
                card.id,
                "parent card \(t.branch) archived — the parent branch is now bare; re-run your ship",
                dedupKey: "\(card.id.uuidString.lowercased())|parent-archived:\(t.branch)")
            await wake(card.id)
            // Archiving this card CHANGES OWNERSHIP of the parent branch for each of these children, and in
            // one direction the `.live`-landing hook cannot see: co-located siblings are permitted and
            // `derivedCard` picks the oldest, so archiving the owner promotes an already-live sibling with
            // no transition to fan out from.
            //
            // The child's re-nudge loop is INVALIDATED first. Ownership is derived, never stored, so an
            // armed loop carries no record of whom it is arming against — and the reconcile treats "armed"
            // as "already an agent's problem" and returns. Left armed, the request would keep re-nudging a
            // card that is gone and never reach the sibling that now owns the branch (the re-nudge tick
            // would notice, but only after a backoff measured in minutes). Stopping it here applies the
            // same rule that tick applies, immediately.
            //
            // Then schedule the CHILD's own recompute — not this card's fan-out debounce, which the
            // teardown above just cancelled — so the request re-routes to whoever owns the branch now, or
            // becomes an unowned request the human sees when nobody does.
            await teardownNudgePause?()   // test seam: land a reopen inside the enqueue/wake window
            // Re-fence AFTER the enqueue/wake suspensions: the trio below mutates the CHILD on the
            // premise that the parent is gone — a reopen that landed during those awaits makes the
            // premise false, and a stale teardown must not stop a live child's nudge loop over it.
            guard await stillOwns(id, expecting: .archivedPending, epoch: expectedEpoch) else { return }
            stopMergeRequestNudge(card.id)
            ensureRuntime(for: card)   // the child may be untouched since a daemon restart
            scheduleTreeStat(card.id)
        }
    }
}
