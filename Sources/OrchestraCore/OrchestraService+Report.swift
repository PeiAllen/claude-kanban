import Foundation

extension OrchestraService {

    /// The live status callback behind the agent's statusLine + hooks (`orchestra _report`). Merges
    /// present fields onto the Task. Snapshot fields (ctxPct/desc/status/model/title) are dropped when
    /// `seq <= lastSeq[id]` (per-card monotonic guard); genuine event-ordered transitions (sessionId
    /// rollover, prompt re-title, session source, end reason) are NOT seq-gated. Persists + emits only
    /// when something changed.
    public func report(_ id: UUID, _ patch: StatusReport) async throws {
        guard var task = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        let before = task

        // Snapshot guard: stamped statusLine reports (seq>0) are coalesced/dropped when stale.
        // Hook reports (seq==0) are naturally ordered and always apply.
        let snapshotAllowed = patch.seq == 0 || patch.seq > (lastSeqStore[id] ?? 0)
        if patch.seq > 0 { lastSeqStore[id] = max(lastSeqStore[id] ?? 0, patch.seq) }

        var statusTransition: (from: AgentStatus, to: AgentStatus)? = nil

        // --- Event-ordered transitions (not seq-gated) ---

        // SessionEnd genuine termination → mid-life death (no auto-resume).
        if let reason = patch.endReason, ["exit", "logout", "other"].contains(reason) {
            if !recovering.contains(id) && task.status != .dead && !task.archived {
                statusTransition = (task.status, .dead)
                task.status = .dead
                task.deadReason = .agentExited
                task.deadDetail = "agent exited (\(reason))"
            }
        }

        // Session id rollover (e.g. after /clear): roll the old current onto priorSessionIds.
        if let newId = patch.sessionId, !newId.isEmpty, newId != task.agentSessionId {
            if let old = task.agentSessionId, !old.isEmpty { task.priorSessionIds.append(old) }
            task.agentSessionId = newId
        }

        // SessionStart source semantics.
        if let src = patch.sessionSource {
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
        if let prompt = patch.promptText, !prompt.isEmpty {
            if task.titleProvisional {
                task.title = titleSeed(from: prompt)
                task.titleProvisional = false
            }
            if task.status == .waiting { statusTransition = statusTransition ?? (task.status, .running) }
            if task.status != .dead { task.status = .running }
        }

        // A non-empty session_name (a /rename mirror) updates the title + clears provisional.
        if let name = patch.sessionName, !name.isEmpty {
            task.title = name
            task.titleProvisional = false
        }

        // --- Snapshot fields (seq-gated) ---
        if snapshotAllowed {
            if let c = patch.ctxPct { task.ctxPct = max(0, min(100, c)) }
            if let d = patch.desc { task.desc = d }
            if let m = patch.model, !m.isEmpty { task.model = m }
            if let s = patch.status, task.status != .dead {
                if s != task.status { statusTransition = statusTransition ?? (task.status, s) }
                task.status = s
            }
        }
        if let tp = patch.transcriptPath, !tp.isEmpty { /* transcript path tracked via sessionInfo */ _ = tp }

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
