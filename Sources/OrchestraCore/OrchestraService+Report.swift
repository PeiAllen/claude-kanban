import Foundation

extension OrchestraService {

    /// The live status callback behind the agent's statusLine + hooks (`orchestra _report`). Merges
    /// present fields onto the Task. The patch is two typed halves: `event` (ordered transitions —
    /// sessionId rollover, prompt re-title, session source, end reason) applied unconditionally, and
    /// `snapshot` (ctxPct/desc/status/model/title) applied as a unit behind the per-card monotonic
    /// `seq` guard. Persists + emits only when something changed.
    public func report(_ id: UUID, _ patch: StatusReport, observedEpoch: Int? = nil) async throws {
        guard var task = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        let before = task

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
                // Codex `.rolloutMeta` readiness: binding a discovered id while the card is still LAUNCHING
                // means the rollout tail just observed the fresh session's `session_meta` line — that IS the
                // launch's readiness signal, so resolve the spawn/reopen's inline waiter. Capability-neutral:
                // only a `.discovered` agent binds a new id mid-launch (a `.seeded` agent's id never rolls
                // while launching), so this never fires for Claude.
                if before.phase.kind == .launching { resolveReadiness(id, true) }
            }

            // SessionStart source semantics.
            if let src = ev.sessionSource {
                switch src {
                case "clear":
                    if task.phase.kind != .dead { task.phase = .live(.waiting(.humanTurn)) }
                    task.desc = ""
                    task.titleProvisional = true
                case "resume":
                    if task.phase.kind != .dead { task.phase = .live(.waiting(.humanTurn)) }
                    task.desc = ""
                    resolveReadiness(id, true)   // confirm a pending RELAUNCH's inline readiness wait
                case "startup":
                    // Claude `.sessionStartHook` readiness for a fresh LAUNCH: the agent's own
                    // SessionStart(startup) is the launch's ready marker, so resolve the spawn/reopen's
                    // inline waiter for a still-launching card. No phase write here — the launch verb owns
                    // the landing (prompt-in-flight → running, else waiting) once its await unblocks.
                    if before.phase.kind == .launching { resolveReadiness(id, true) }
                default:
                    break   // compact: no status change
                }
            }

            // First prompt after restart/clear re-titles the card.
            if let prompt = ev.promptText, !prompt.isEmpty {
                resetInjectCount(id)   // a genuine user turn ends any F3 auto-inject loop (loop guard reset)
                if task.titleProvisional {
                    task.title = titleSeed(from: prompt)
                    task.titleProvisional = false
                }
                if task.phase.kind != .dead { task.phase = .live(.running) }
            }
            // (`ev.transcriptPath` is carried for completeness but not persisted — the path is
            // re-derived from the live session id in `Adapter.sessionInfo` whenever it's needed.)
        }

        // --- Snapshot half (seq-gated as a unit) ---
        // Stamped statusLine reports (seq>0) are coalesced/dropped when stale (an equal seq is
        // treated as already-applied); hook snapshots (seq==0) are naturally ordered and always
        // apply. The cursor is monotonic — it never moves backward.
        if let snap = patch.snapshot {
            let lastSeq = lastSeqStore[id] ?? 0
            // Permission-fence for fileTail agents (Codex): a `PermissionRequest` hook arrives as a
            // seq==0 push ("naturally ordered, always apply") but does NOT advance the cursor — leaving
            // `.waiting/.permission` open to being clobbered by a rollout line the agent wrote µs before
            // it blocked (the tool-call line → `.running`, seq = its timestamp) that the polling tailer
            // delivers a tick LATER and that sails past the `seq > lastSeq` gate. That flips the card back
            // to `.running`: no Needs-You row, no push, silently blocked. So a hook-pushed blocking wait
            // on a fileTail agent FENCES the cursor to "now" in the tailer's own µs clock space — dropping
            // the already-stale pre-block line while still admitting genuinely-later post-approval lines
            // (their timestamps exceed now). Claude has no fileTail, so its seq==0 hooks are unaffected
            // (and its statusline seq lives in a different clock space — fencing there could wrongly drop
            // its reports, which is exactly why this is capability-gated, not global).
            let effectiveSeq = fencedSeq(for: snap, taskAgentId: task.agentId, lastSeq: lastSeq)
            let allowed = effectiveSeq == 0 || effectiveSeq > lastSeq
            if effectiveSeq > lastSeq { lastSeqStore[id] = effectiveSeq }
            if allowed {
                if let c = snap.ctxPct { task.ctxPct = max(0, min(100, c)) }
                if let d = snap.desc { task.desc = d }
                // Model: a reported launch *id* updates the model (and tracks in-session /model
                // switches), resolved to a full handle via the adapter; the display label is UI-only
                // and never becomes the launch id. (Storing the label as the id broke resume/restart.)
                if let mid = snap.modelId, !mid.isEmpty, mid != task.model.id {
                    var m = (try? registry.get(task.agentId))?.model(for: mid) ?? AgentModel(id: mid)
                    if let label = snap.modelDisplay, !label.isEmpty { m.displayName = label }
                    task.model = m
                } else if let label = snap.modelDisplay, !label.isEmpty, label != task.model.displayName {
                    task.model.displayName = label
                }
                // session_name (a /rename mirror): apply only a *genuine* change, so a statusline
                // echoing the `--name` we launched with never prematurely clears `titleProvisional`
                // (which restart/clear set precisely so the next user prompt re-titles the card).
                if let name = snap.sessionName, !name.isEmpty, name != task.title {
                    task.title = name
                    task.titleProvisional = false
                }
                // The agent's observed run-state maps onto a `.live(_)` phase.
                if let run = snap.run, task.phase.kind != .dead {
                    task.phase = .live(run)
                }
                // A worktree card stays long-lived on a completed turn (`.live(.waiting(.humanTurn))`, set
                // by `run` above); only a read-only freeform/scratch card (a one-shot delegation) concludes.
                if snap.turnCompleted == true, shouldConcludeOnTurnCompletion(task) {
                    task.phase = .dead(.completed)
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
            let (saved, rev) = try await store.update(id, debounceFlush: true) { $0.applyReportFields(from: task) }
            emit(.taskUpserted(saved), rev: rev)
            didChange = true
        }

        // Phase change → the funnel. `observedEpoch` fences a superseded generation (a stale liveness
        // signal is dropped as a no-op). The companion `mutate` carries the dead metadata atomically with
        // the phase write; the funnel emits the upsert, runs conclusions, and fires wake-on-live.
        if targetPhase != before.phase {
            let result = await transition(id, to: targetPhase, observedEpoch: observedEpoch) { t in
                t.deadReason = targetDeadReason
                t.deadDetail = targetDeadDetail
            }
            if result == .applied {
                didChange = true
                // Activity only on a real transition — dead, or a waiting<->running change. Derived from
                // the coarse `phase` word before vs after (the retired `status`-transition tracking).
                if let word = Self.activityWord(targetPhase), Self.activityWord(before.phase) != word {
                    let card = await store.get(id) ?? before
                    if word == "died" {
                        emitActivity(.dead, card, .agent, "agent died")
                    } else {   // "waiting" | "running"
                        emitActivity(.statusChanged, card, .agent, "agent \(word)")
                    }
                }
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

    /// The coarse activity word for a phase — the transition vocabulary the Activity feed used to read
    /// off `status`. `.dead(.completed)` maps to nil (a done conclusion is not a "died" activity).
    private static func activityWord(_ phase: Phase) -> String? {
        switch phase {
        case .live(.running):   return "running"
        case .live(.waiting):   return "waiting"
        case .dead(.completed): return nil
        case .dead:             return "died"
        default:                return nil   // creatingWorktree / launching / relaunching / archived
        }
    }

    /// The seq a snapshot is gated with. Normally the snapshot's own seq. The one exception is the
    /// fileTail permission-fence (see the call site): a seq==0 hook that opens a blocking permission wait
    /// on a `.fileTail` agent is stamped with a synthetic "now" in the tailer's µs clock space so a
    /// late-delivered pre-block rollout line can't clobber it. Everything else is unchanged.
    private func fencedSeq(for snap: SnapshotReport, taskAgentId: String, lastSeq: UInt64) -> UInt64 {
        guard snap.seq == 0, snap.run == .waiting(.permission),
              (try? registry.get(taskAgentId))?.capabilities.telemetry == .fileTail else {
            return snap.seq
        }
        // Epoch µs — the SAME scale `CodexAdapter.rolloutSeq` stamps tail lines with. `max(_, lastSeq+1)`
        // guarantees we advance the cursor even under an improbable clock stall.
        let nowMicros = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
        return max(nowMicros, lastSeq &+ 1)
    }

    /// Read-only freeform/scratch cards are the durable-card form of a one-shot delegation: they have no
    /// branch lifecycle to merge, so an adapter's explicit task-completion signal is the card's completion
    /// signal. Worktree cards remain long-lived and keep their existing `.waiting(.humanTurn)` behavior.
    private func shouldConcludeOnTurnCompletion(_ task: Task) -> Bool {
        task.origin != .worktree && task.access == .readOnly && !task.archived && task.phase.kind != .dead
    }
}
