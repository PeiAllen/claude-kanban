import Foundation

extension OrchestraService {

    /// The live status callback behind the agent's statusLine + hooks (`orchestra _report`). Merges
    /// present fields onto the Task. The patch is two typed halves: `event` (ordered transitions —
    /// sessionId rollover, prompt re-title, session source, end reason) applied unconditionally, and
    /// `snapshot` (ctxPct/desc/status/model/title) applied as a unit behind the per-card monotonic
    /// `seq` guard. Persists + emits only when something changed.
    public func report(_ id: UUID, _ patch: StatusReport) async throws {
        guard var task = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        let before = task
        var statusTransition: (from: AgentStatus, to: AgentStatus)? = nil
        var turnCompletionConcluded = false

        // --- Event-ordered half (never seq-gated) ---
        if let ev = patch.event {
            let staleSessionEnd = ev.endReason != nil
                && ev.sessionId != nil
                && task.agentSessionId != nil
                && ev.sessionId != task.agentSessionId

            // SessionEnd genuine termination → mid-life death (no auto-resume).
            if !staleSessionEnd,
               let reason = ev.endReason, ["exit", "logout", "other"].contains(reason) {
                if !recovering.contains(id) && task.status != .dead && !task.archived {
                    statusTransition = (task.status, .dead)
                    task.status = .dead
                    task.deadReason = .agentExited
                    task.deadDetail = "agent exited (\(reason))"
                }
            }

            // Session id rollover (e.g. after /clear): roll the old current onto priorSessionIds.
            if !staleSessionEnd,
               let newId = ev.sessionId, !newId.isEmpty, newId != task.agentSessionId {
                if let old = task.agentSessionId, !old.isEmpty { task.priorSessionIds.append(old) }
                task.agentSessionId = newId
            }

            // SessionStart source semantics.
            if let src = ev.sessionSource {
                switch src {
                case "clear":
                    if task.status != .dead { task.status = .waiting }
                    task.desc = ""
                    task.titleProvisional = true
                case "resume":
                    if task.status != .dead { task.status = .waiting }
                    task.desc = ""
                    resolveResume(id, true)   // confirm a pending recovery
                default:
                    break   // startup / compact: no status change
                }
            }

            // First prompt after restart/clear re-titles the card.
            if let prompt = ev.promptText, !prompt.isEmpty {
                resetInjectCount(id)   // a genuine user turn ends any F3 auto-inject loop (loop guard reset)
                if task.titleProvisional {
                    task.title = titleSeed(from: prompt)
                    task.titleProvisional = false
                }
                if task.status == .waiting { statusTransition = statusTransition ?? (task.status, .running) }
                if task.status != .dead { task.status = .running }
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
                if let s = snap.status, task.status != .dead {
                    if s != task.status { statusTransition = statusTransition ?? (task.status, s) }
                    task.status = s
                    if s == .waiting { task.waitReason = snap.waitReason }
                }
                if snap.turnCompleted == true, shouldConcludeOnTurnCompletion(task) {
                    if task.status != .done { statusTransition = (before.status, .done) }
                    task.status = .done
                    task.waitReason = nil
                    turnCompletionConcluded = true
                }
            }
        }

        // Clear dead metadata if we left .dead.
        if before.status == .dead && task.status != .dead {
            task.deadReason = nil; task.deadDetail = nil
        }
        // waitReason is meaningful only while waiting.
        if task.status != .waiting { task.waitReason = nil }

        guard task != before else { return }   // idempotent: no delta -> no persist, no event
        let saved = try await store.update(id) { $0 = task }
        emit(.taskUpserted(saved))

        // Code review on the board (axis 7): any per-card activity that lands here (a normalized
        // StatusReport — no tool_name) coalesces into a re-stat of the footer diffstat. Adapter-
        // agnostic by construction; the debounce + idempotent recompute bound the cost.
        if saved.origin == .worktree {
            scheduleDiffStat(id)
            scheduleTreeStat(id)                                    // this card's own parent may have moved
            scheduleChildFanout(id)                                 // a moved parent stales children (debounced)
        }

        // Activity only on a real status transition (waiting<->running) or dead.
        if let tr = statusTransition, tr.from != tr.to {
            if tr.to == .dead {
                emitActivity(.dead, saved, .agent, "agent died")
            } else if tr.to == .waiting || tr.to == .running {
                emitActivity(.statusChanged, saved, .agent, "agent \(tr.to.rawValue)")
            }
        }

        // A clean agent exit (SessionEnd exit/logout/other) is a SETTLED conclusion (.exited) — the
        // agent quit, no auto-resume. A transient crash (sessionVanished) is NOT concluded here; it may
        // still be revived (that path never sets `.agentExited`, and `recovering` guards a stale exit).
        if let tr = statusTransition, tr.to == .dead, saved.deadReason == .agentExited, !recovering.contains(id) {
            await concludeCard(id, .exited)
        }
        if turnCompletionConcluded {
            await concludeCard(id, .done)
        }
    }

    /// The seq a snapshot is gated with. Normally the snapshot's own seq. The one exception is the
    /// fileTail permission-fence (see the call site): a seq==0 hook that opens a blocking permission wait
    /// on a `.fileTail` agent is stamped with a synthetic "now" in the tailer's µs clock space so a
    /// late-delivered pre-block rollout line can't clobber it. Everything else is unchanged.
    private func fencedSeq(for snap: SnapshotReport, taskAgentId: String, lastSeq: UInt64) -> UInt64 {
        guard snap.seq == 0, snap.status == .waiting, snap.waitReason == .permission,
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
        task.origin != .worktree && task.access == .readOnly && !task.archived && task.status != .dead
    }
}
