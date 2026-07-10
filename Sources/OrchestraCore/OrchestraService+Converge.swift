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
        let remoteRef = normalizedBase.flatMap { RemoteParentRef.parse($0, remotes: gitRemotes(repo: realRepo)) }
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
                _ = try? await offActor { try? Proc.run(["git", "-C", realRepo, "branch", "-D", card.branch]) }
            }
            return .failed(detail: "spawn rolled back (worktree/branch removed): \(error)")
        }
        // BT6: a fresh remote-base spawn opts into merge-watch (moved off spawn's inline tail — spawn no
        // longer knows the derived parent). Start it now that the remote lineage is recorded.
        if RemoteParentRef.parse(derivedParentBranch ?? "", remotes: gitRemotes(repo: realRepo)) != nil,
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
    func finishLaunch(_ id: UUID, flavor: LaunchFlavor) async -> ReadinessOutcome {
        guard let task = await store.get(id), let adapter = try? registry.get(task.agentId) else {
            return .timedOut
        }
        let epoch = task.sessionEpoch
        let grace = config.revivalGraceSeconds
        let env = withEpoch(adapter.env, epoch)   // stamp the current generation into the session env
        let trustDecision = await resolveTrust(origin: task.origin, cwd: task.cwd, repo: task.repo)
        pendingReadiness.remove(id)   // start clean so only THIS bring-up's signal can confirm it

        let argv: [String]
        switch flavor {
        case .blank(_, let prompt):
            let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: task.model.id, startIn: task.startIn,
                                     sessionId: task.agentSessionId, prompt: prompt, name: task.title,
                                     orchestraBin: orchestraBin, access: task.access,
                                     trustCwd: trustDecision == .trusted)
            let a = adapter, c = ctx
            try? await offActor { try? a.prepareToLaunch(c) }
            argv = adapter.start(ctx)
        case .resume(let seed):
            let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: task.model.id,
                                     sessionId: task.agentSessionId, name: task.title, orchestraBin: orchestraBin,
                                     trustCwd: trustDecision == .trusted, seed: seed)
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
        do {
            try await offActor { [sessions] in
                _ = try? sessions.kill(sessions.sessionName(id))   // idempotent for a fresh launch
                _ = try sessions.ensure(task, argv: argv, env: env)
            }
        } catch {
            return .timedOut   // tmux ensure failed
        }
        return await confirmReadiness(id, adapter: adapter, graceSeconds: grace)
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
        treeStatDebounce[id]?.cancel(); treeStatDebounce[id] = nil     // S3-5
        childFanoutDebounce[id]?.cancel(); childFanoutDebounce[id] = nil
        lastSeqStore[id] = nil       // the agent is gone; don't leak its seq cursor
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
