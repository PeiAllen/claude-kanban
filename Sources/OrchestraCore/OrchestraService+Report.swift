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

        // --- Event-ordered half (never seq-gated) ---
        if let ev = patch.event {
            // SessionEnd genuine termination → mid-life death (no auto-resume).
            if let reason = ev.endReason, ["exit", "logout", "other"].contains(reason) {
                if !recovering.contains(id) && task.status != .dead && !task.archived {
                    statusTransition = (task.status, .dead)
                    task.status = .dead
                    task.deadReason = .agentExited
                    task.deadDetail = "agent exited (\(reason))"
                }
            }

            // Session id rollover (e.g. after /clear): roll the old current onto priorSessionIds.
            if let newId = ev.sessionId, !newId.isEmpty, newId != task.agentSessionId {
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
            let allowed = snap.seq == 0 || snap.seq > lastSeq
            if snap.seq > lastSeq { lastSeqStore[id] = snap.seq }
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
                }
            }
        }

        // Clear dead metadata if we left .dead.
        if before.status == .dead && task.status != .dead {
            task.deadReason = nil; task.deadDetail = nil
        }

        guard task != before else { return }   // idempotent: no delta -> no persist, no event
        let saved = try await store.update(id) { $0 = task }
        emit(.taskUpserted(saved))

        // Activity only on a real status transition (waiting<->running) or dead.
        if let tr = statusTransition, tr.from != tr.to {
            if tr.to == .dead {
                emitActivity(.dead, saved, .agent, "agent died")
            } else if tr.to == .waiting || tr.to == .running {
                emitActivity(.statusChanged, saved, .agent, "agent \(tr.to.rawValue)")
            }
        }
    }
}
