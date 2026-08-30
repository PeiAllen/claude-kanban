import Foundation

extension OrchestraService {

    /// The metadata/lifecycle callback behind the agent's status line and hooks (`orchestra _report`).
    /// `AgentSignal` owns live agent state; this path merges session identity, presentation metadata,
    /// and terminal session events. Snapshot fields are applied as a unit behind the per-card monotonic
    /// `seq` guard. Persists and emits only when something changed.
    public func report(_ id: UUID, _ patch: StatusReport, observedEpoch: Int? = nil,
                       tail: (path: String, startOffset: Int64)? = nil) async throws {
        guard var task = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        // The funnel is the one high-frequency path with no archived gate of its own: `ensureRuntime`'s
        // `!archived` gate is what keeps a late report for an archived card from resurrecting its entry
        // (A1), while a live card's first post-restart report creates it here.
        ensureRuntime(for: task)
        let before = task
        // Set when a re-seat is judged to have been IGNORED by the vendor; emitted after the write below, so
        // the warning rides a card whose `model` already shows what is really running.
        var modelReseatIgnored: (requested: String, actual: String)? = nil

        let beingBorn = task.phase.kind == .launching || task.phase.kind == .relaunching
        // An unstamped report cannot be attributed to the current generation while a replacement session
        // is being born. It may still carry harmless metadata, but it cannot clear session-scoped fields.
        let staleGeneration = beingBorn && observedEpoch != task.sessionEpoch
        // A stamped report from another generation is stale in every lifecycle phase. Unstamped reports on
        // an already-live card remain compatible with sessions launched before epoch propagation existed.
        let provablyOtherGeneration = observedEpoch != nil && observedEpoch != task.sessionEpoch
        let attributable = !staleGeneration && !provablyOtherGeneration

        // --- Event-ordered half (never seq-gated) ---
        if let ev = patch.event {
            let staleSessionEnd = ev.endReason != nil
                && ev.sessionId != nil
                && task.agentSessionId != nil
                && ev.sessionId != task.agentSessionId

            // SessionEnd genuine termination → mid-life death (no auto-resume).
            if !staleSessionEnd,
               let reason = ev.endReason, ["exit", "logout", "other"].contains(reason) {
                // Nil-epoch kill-class discipline: a pre-upgrade SessionEnd (no `observedEpoch`) can't be
                // epoch-fenced by the funnel, so before we treat it as a death we PROBE real liveness — a
                // stale SessionEnd for a session that is actually still alive must not kill the card. An
                // epoch-stamped signal skips the probe (the funnel's generation fence already covers it,
                // dropping a superseded one and applying a current one).
                let sessionGone = observedEpoch != nil
                    || !((try? sessions.isAlive(sessions.sessionName(id))) ?? false)
                if task.phase.kind != .dead && !task.archived && sessionGone {
                    task.phase = .dead(.agentExited)
                    task.deadReason = .agentExited
                    task.deadDetail = "agent exited (\(reason))"
                    clearSpawnPending(id)   // a card that died via SessionEnd is no longer startup-pending
                }
            }

            // Session id rollover (e.g. after /clear): roll the old current onto priorSessionIds.
            if !staleSessionEnd,
               let newId = ev.sessionId, !newId.isEmpty, newId != task.agentSessionId {
                if let old = task.agentSessionId, !old.isEmpty { task.priorSessionIds.append(old) }
                task.agentSessionId = newId
                task.sessionDiscoverySince = nil
                // Codex `.rolloutMeta` readiness: binding a discovered id while the card is still LAUNCHING
                // means the rollout tail just observed the fresh session's `session_meta` line — that IS the
                // launch's readiness signal, so resolve the spawn/reopen's inline waiter. Capability-neutral:
                // only a `.discovered` agent binds a new id mid-launch (a `.seeded` agent's id never rolls
                // while launching), so this never fires for Claude.
                if before.phase.kind == .launching { resolveReadiness(id, true, observedEpoch: observedEpoch) }
                // The session that declared the question has been replaced, so the question is moot.
                // Generation-fenced, unlike the id write above: a late rollover from a session we have
                // already torn down would otherwise erase a question the INCOMING generation declared
                // after the fact — and `applyReportFields` carries `pendingQuestion`, so that nil would
                // really land.
                if attributable { task.pendingQuestion = nil }
            }

            // SessionStart source semantics.
            if let src = ev.sessionSource {
                switch src {
                case "clear":
                    task.desc = ""
                    task.awaitingFirstPrompt = true
                    // `/clear` wipes the context and returns the card to awaiting a first prompt — the
                    // human's move again, so it is human-paced (its quiet is legitimate). See `Task.humanPaced`.
                    if attributable { task.humanPaced = true }
                case "resume":
                    task.desc = ""
                    resolveReadiness(id, true, observedEpoch: observedEpoch)   // confirm a pending RELAUNCH's inline readiness wait (epoch-fenced)
                case "startup":
                    // Claude `.sessionStartHook` readiness for a fresh LAUNCH: the agent's own
                    // SessionStart(startup) is the launch's ready marker, so resolve the spawn/reopen's
                    // inline waiter for a still-launching card. No phase write here — the launch verb owns
                    // the live/unavailable landing once its await unblocks.
                    if before.phase.kind == .launching { resolveReadiness(id, true, observedEpoch: observedEpoch) }
                default:
                    break   // compact: no status change
                }
            }

            // First prompt after restart/clear re-titles the card.
            if let prompt = ev.promptText, !prompt.isEmpty {
                // A system-supplied launch seed also arrives as prompt text. `seedTurnEpoch` keeps that
                // one opening prompt from being classified as a direct human turn.
                let machineSeedTurn: Bool
                if let se = runtime[id]?.seedTurnEpoch, se == observedEpoch { machineSeedTurn = true }
                else { machineSeedTurn = false }
                if machineSeedTurn { runtime[id]?.seedTurnEpoch = nil }
                else if before.agentState?.workInFlight == false, attributable { task.humanPaced = true }
                // A delayed prompt from the replaced generation must not clear the incoming generation's
                // first-prompt marker or rename the card from stale context.
                if task.awaitingFirstPrompt, attributable {
                    task.awaitingFirstPrompt = false     // lifecycle: this session has now been prompted
                    // Naming: only a card whose title came FROM a prompt may be re-titled by one. A branch,
                    // a 👁 target, or an explicit name all outrank the prompt cutoff that used to win here.
                    if task.titleSource == .prompt { task.title = titleSeed(from: prompt) }
                }
            }
            // (`ev.transcriptPath` is carried for completeness but not persisted — the path is
            // re-derived from the live session id in `Adapter.sessionInfo` whenever it's needed.)
        }

        // --- Snapshot half (seq-gated as a unit) ---
        // Stamped status-line reports (seq > 0) are coalesced when stale; hook snapshots (seq == 0)
        // are naturally ordered and always apply. The cursor is monotonic.
        if let snap = patch.snapshot {
            let lastSeq = runtime[id]?.lastSeq ?? 0
            let effectiveSeq = snap.seq
            let allowed = effectiveSeq == 0 || effectiveSeq > lastSeq
            if effectiveSeq > lastSeq { runtime[id]?.lastSeq = effectiveSeq }
            if allowed {
                if let c = snap.ctxPct { task.ctxPct = max(0, min(100, c)) }
                if let d = snap.desc { task.desc = d }
                // Model: a reported launch *id* updates the model (and tracks in-session /model
                // switches), resolved to a full handle via the adapter; the display label is UI-only
                // and never becomes the launch id. (Storing the label as the id broke resume/restart.)
                if let mid = snap.modelId, !mid.isEmpty, mid != task.model.id {
                    // Canonicalize through the catalog: the vendor answers with its DATED id
                    // (`claude-haiku-4-5-20251001`) where the offline table carries the floating one
                    // (`claude-haiku-4-5`). `model(for:)` doesn't know the dated form, so it fell back to a
                    // bare `AgentModel(id:)` with NO contextWindow — and that is the denominator `ctxPct`
                    // divides by, so the card's context gauge went blank and every later launch used the
                    // dated id. Resolve the dated form back to its catalog entry and keep the real metadata.
                    let catalog = (try? registry.get(task.agentId))?.models() ?? []
                    var m = catalog.first { $0.id == mid }
                        ?? catalog.first { Self.isModelVariant(mid, of: $0.id) }
                        ?? AgentModel(id: mid)
                    if let label = snap.modelDisplay, !label.isEmpty { m.displayName = label }
                    task.model = m
                } else if let label = snap.modelDisplay, !label.isEmpty, label != task.model.displayName {
                    task.model.displayName = label
                }
                // Did a `--model` re-seat (restart/handoff/resume) actually take? Fenced on
                // `pendingModel == nil`, i.e. the relaunch has LANDED and the old process is dead: reports
                // arriving before that are the DYING session's, and judging them would accuse the vendor of
                // ignoring a flag it was never passed. That fence needs no epoch, which matters — Codex's
                // file-tail reports carry none (OrchestraService.swift). Compared through the catalog,
                // never raw `==`: the vendor answers `claude-haiku-4-5-20251001` where the table says
                // `claude-haiku-4-5`. One warning, then the watch is dropped — never a per-tick drumbeat.
                if let mid = snap.modelId, !mid.isEmpty,
                   task.pendingModel == nil, let watch = runtime[id]?.modelOverrideWatch {
                    if modelHonored(reported: mid, requested: watch.requested, agentId: task.agentId) {
                        runtime[id]?.modelOverrideWatch = nil // re-seat confirmed by the agent itself
                    } else if !modelHonored(reported: mid, requested: watch.left, agentId: task.agentId) {
                        // Neither the model we asked for NOR the one we left — the session deliberately
                        // switched to a third model (`/model`). Not a vendor fault; stop watching.
                        runtime[id]?.modelOverrideWatch = nil
                    } else if watch.strikes >= 1 {
                        runtime[id]?.modelOverrideWatch = nil
                        modelReseatIgnored = (watch.requested, mid)   // emitted below, once the write lands
                    } else {
                        runtime[id]?.modelOverrideWatch = (watch.requested, watch.left, watch.strikes + 1)
                    }
                }
                // session_name (a /rename mirror) — DELTA-based and generation-fenced.
                //
                // Delta, not `name != task.title`: nothing can rename a LIVE Claude session from outside, so
                // it keeps echoing the `--name` it launched with forever. Comparing against the TITLE meant
                // that after a `set-title` every subsequent statusline tick looked like a rename back to the
                // old name — silently undoing it. Comparing against the last name we SAW makes an echo inert
                // and a genuine `/rename` a one-time event. `lastSessionName` is pre-armed at launch with the
                // name we pushed, so even the new session's very first report is provably an echo; a nil
                // baseline (a pre-upgrade card) records without adopting, and heals at the next relaunch.
                //
                // Fenced, because `restart` bumps the epoch while the outgoing session stays alive and
                // reporting: its statusline still carries the OLD name and would otherwise read as a rename
                // on the incoming generation. Every hook echoes `ORCH_EPOCH` from its session env, so the
                // predecessor is identifiable. A pre-epoch session reports nil and its mirror stays inert
                // until it next relaunches — the fail-safe direction, and self-healing.
                if let name = snap.sessionName, !name.isEmpty, name != task.lastSessionName,
                   observedEpoch == task.sessionEpoch {
                    if task.lastSessionName != nil, name != task.title {
                        // Normalized like every other write to `title`: this value is a session name we did
                        // not author, it PINS as `.explicit`, and it becomes the next launch's `--name` argv.
                        task.title = CardNaming.normalize(name)
                        task.titleSource = .explicit   // a human's in-session rename PINS, exactly like set-title
                    }
                    task.lastSessionName = name
                }
            }
        }

        // Split the net phase change out of the field-delta write and route it through the `transition()`
        // funnel — the SOLE writer of `phase` and the SOLE concluder (so report no longer double-concludes).
        // The remaining report-owned fields (ctx/desc/model/title/sessionId) still land via the field-delta
        // patch; `phase`/`deadReason`/`deadDetail` are reverted here so that patch leaves them untouched.
        let targetPhase = task.phase
        let targetDeadReason = task.deadReason
        let targetDeadDetail = task.deadDetail
        task.phase = before.phase
        task.deadReason = before.deadReason
        task.deadDetail = before.deadDetail

        var didChange = false

        // Field-delta write (non-phase). Idempotent: no delta -> no persist, no event.
        if task != before {
            // Telemetry-origin: bump rev + memory + emit SYNCHRONOUSLY, but COALESCE the tasks.json write
            // (bug #13). The phase write via `transition()` below stays IMMEDIATE and force-flushes this.
            let (saved, rev) = try await store.update(id, debounceFlush: true) {
                $0.applyReportFields(from: task, changedFrom: before)
            }
            emit(.taskUpserted(saved), rev: rev)
            if saved.agentSessionId != before.agentSessionId {
                // `/clear` can replace the provider session without leaving the live lifecycle phase.
                // The old snapshot cannot describe the replacement session. Mark it unavailable before
                // replacing the subscription; the same hook's raw observation (or Codex's attach response)
                // then supplies the first current-session state.
                await invalidateAgentObservation(saved)
                // `observationLost` may be a durable no-op when the old state is already unavailable.
                // Session binding is still a subscription-identity change, so converge it directly instead
                // of relying on a status transition's lifecycle callback to happen as a side effect.
                if saved.phase.kind == .live {
                    await reconcileAgentObservation(saved)
                    reconcileAgentMessageHandle(saved)
                }
            }
            didChange = true
        }

        // The re-seat did not take: the card is running a model the user did not ask for, and now that
        // `pendingModel` owns the launch argv the only way that happens is the vendor CLI ignoring `--model`
        // on resume. Say it out loud rather than let the board quietly show the old model as if nothing had
        // been asked for. Emitted OUTSIDE the field-delta write above — deliberately: the report that strikes
        // the vendor out is the SECOND one naming the wrong model, which by definition changes no field
        // (`model` already holds that wrong value), so a warning gated on `task != before` would never fire.
        if let ignored = modelReseatIgnored {
            emitActivity(.warning, task, .daemon,
                         "re-seat did not take: asked for \(ignored.requested), "
                         + "but the agent is running \(ignored.actual)")
        }

        // SessionEnd is the only phase transition owned by this metadata path. All live-to-live status
        // transitions enter through `applyAgentSignals` instead.
        if targetPhase != before.phase {
            let result = await transition(id, to: targetPhase, observedEpoch: observedEpoch) { t in
                t.deadReason = targetDeadReason
                t.deadDetail = targetDeadDetail
            }
            if result == .applied {
                didChange = true
                let card = await store.get(id) ?? before
                emitActivity(.dead, card, .agent, "agent died")
            }
        }

        // Code review on the board (axis 7): any per-card activity that lands here (a normalized
        // StatusReport — no tool_name) coalesces into a re-stat of the footer diffstat. Adapter-
        // agnostic by construction; the debounce + idempotent recompute bound the cost.
        if didChange, before.origin == .worktree {
            scheduleDiffStat(id)
            scheduleTreeStat(id)                                    // this card's own parent may have moved
            scheduleChildFanout(id)                                 // a moved parent stales children (debounced)
        }

    }

}
