import Foundation

extension OrchestraService {

    /// The live status callback behind the agent's statusLine + hooks (`orchestra _report`). Merges
    /// present fields onto the Task. The patch is two typed halves: `event` (ordered transitions —
    /// sessionId rollover, prompt re-title, session source, end reason) applied unconditionally, and
    /// `snapshot` (ctxPct/desc/status/model/title) applied as a unit behind the per-card monotonic
    /// `seq` guard. Persists + emits only when something changed.
    public func report(_ id: UUID, _ patch: StatusReport, observedEpoch: Int? = nil,
                       tail: (path: String, startOffset: Int64)? = nil) async throws {
        guard var task = await store.get(id) else { throw OrchestraError.unknownTask(id.uuidString) }
        let before = task
        // Set when a re-seat is judged to have been IGNORED by the vendor; emitted after the write below, so
        // the warning rides a card whose `model` already shows what is really running.
        var modelReseatIgnored: (requested: String, actual: String)? = nil

        // A bring-up STEP owns this card's landing while it is in flight (`inFlightSteps` is the claim, held
        // across its off-actor `kill`+`ensure`). A report must NOT land the card `.live` under it: the step's
        // fence is checked on entry, but the bring-up itself suspends (trust resolve, prepareToLaunch) before
        // the destructive hop, so a same-epoch `.live` landing slipped in HERE would leave the step believing
        // it still owns a being-born card — it would then kill the live session and re-`ensure` a fresh one.
        // That is the production session-loss bug (and the `--parallel` suite hang) in its narrow form.
        //
        // Suppressing only the PHASE write costs nothing: the readiness signals below (`resolveReadiness`)
        // still fire, so the in-flight step confirms and lands `.live` itself through the funnel, with the
        // landing its flavor derives. Every other field (session id, title, desc, model, ctx) still applies,
        // and terminal writes (SessionEnd death, turn-completion) are deliberately NOT gated — a card that
        // genuinely died must still die, and the step's own `kill` is then harmless.
        // Scoped to a card that is still BEING BORN. The claim outlives the landing — a step writes `.live`
        // and only then returns, so `inFlightSteps` still holds the card for a moment afterwards — and a
        // claim-only test would swallow the first real report of a card that is already live (its
        // `waitReason`, its run-state). Once the card IS `.live` the bring-up's destructive work is behind it
        // (and the fences stand a stale one down anyway), so a report must be free to move it again.
        let beingBorn = task.phase.kind == .launching || task.phase.kind == .relaunching
        let bringUpOwnsLanding = beingBorn && inFlightSteps.contains(id)
        // A report we cannot attribute to the CURRENT generation of a still-being-born card. Not the same
        // test as `bringUpOwnsLanding`: that one needs the stepper to have already CLAIMED the card, and
        // `restart` bumps the epoch and returns long before that claim exists. In that gap the outgoing
        // session is still alive and still reporting, so its hooks — including a delayed prompt, and
        // including a pre-epoch session's UNSTAMPED ones — could otherwise land the incoming generation
        // `.live` (no stepper ever visits a `.live` card, so the relaunch is silently dropped and the old
        // session keeps running) or clear `awaitingFirstPrompt` out from under it. Fail-CLOSED, unlike the
        // rest of report(): a report that cannot prove its generation may not move a card that is being born.
        let staleGeneration = beingBorn && observedEpoch != task.sessionEpoch
        // …and a report that is PROVABLY from another generation — stamped, and stamped with a different
        // epoch — is stale no matter what phase the card is in. The two terms are separate because they
        // fence different things and neither subsumes the other: `staleGeneration` alone would admit the
        // outgoing session's stamped prompt once the relaunch has already landed `.live` (the card is no
        // longer being born, so it clears `awaitingFirstPrompt` on a generation that was never prompted and
        // re-titles from the DEAD session's prompt), while this term alone would admit an unstamped report
        // onto a card mid-restart. An UNSTAMPED report on a live card stays admitted — that is the whole
        // pre-epoch-session compatibility case.
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
                // The PHASE writes below carry the same fence as the prompt path: a SessionStart from the
                // session a restart is replacing would otherwise land the incoming generation `.live` — no
                // stepper visits a `.live` card, so the relaunch is dropped and the old session keeps
                // running. Only the phase writes are fenced: `resolveReadiness` must still fire for an
                // unstamped resume, and the `desc`/`awaitingFirstPrompt` writes are harmless either way.
                // Nothing legitimate is blocked — an incoming session's SessionStart is epoch-stamped (and
                // `bringUpOwnsLanding` anyway), and a genuine `/clear` arrives on a `.live` card.
                case "clear":
                    if task.phase.kind != .dead, !bringUpOwnsLanding, attributable {
                        task.phase = .live(.waiting(.humanTurn))
                    }
                    task.desc = ""
                    task.awaitingFirstPrompt = true
                    // `/clear` replaces the session's whole context: whatever it was blocked on is gone.
                    // Fenced like the phase write beside it (and unlike `desc`/`awaitingFirstPrompt`,
                    // which are harmless either way) — erasing the incoming generation's question on the
                    // word of the outgoing session's SessionStart is not harmless.
                    if attributable { task.pendingQuestion = nil }
                case "resume":
                    if task.phase.kind != .dead, !bringUpOwnsLanding, attributable {
                        task.phase = .live(.waiting(.humanTurn))
                    }
                    task.desc = ""
                    resolveReadiness(id, true, observedEpoch: observedEpoch)   // confirm a pending RELAUNCH's inline readiness wait (epoch-fenced)
                case "startup":
                    // Claude `.sessionStartHook` readiness for a fresh LAUNCH: the agent's own
                    // SessionStart(startup) is the launch's ready marker, so resolve the spawn/reopen's
                    // inline waiter for a still-launching card. No phase write here — the launch verb owns
                    // the landing (prompt-in-flight → running, else waiting) once its await unblocks.
                    if before.phase.kind == .launching { resolveReadiness(id, true, observedEpoch: observedEpoch) }
                default:
                    break   // compact: no status change
                }
            }

            // First prompt after restart/clear re-titles the card.
            if let prompt = ev.promptText, !prompt.isEmpty {
                resetInjectCount(id)   // a genuine user turn ends any F3 auto-inject loop (loop guard reset)
                // Both writes below are generation-fenced (see `staleGeneration`): a delayed prompt from the
                // session a `restart` is replacing must neither clear the incoming generation's
                // `awaitingFirstPrompt` — the RelaunchStepper would then find neither a transcript nor
                // permission to blank-launch, and strand the card `.resumeFailed` — nor land it `.live`,
                // which drops the relaunch entirely and leaves the old session running. A card that is NOT
                // being born is unaffected, so an ordinary prompt still re-titles and still lands `.running`.
                if task.awaitingFirstPrompt, attributable {
                    task.awaitingFirstPrompt = false     // lifecycle: this session has now been prompted
                    // Naming: only a card whose title came FROM a prompt may be re-titled by one. A branch,
                    // a 👁 target, or an explicit name all outrank the prompt cutoff that used to win here.
                    if task.titleSource == .prompt { task.title = titleSeed(from: prompt) }
                }
                if task.phase.kind != .dead, !bringUpOwnsLanding, attributable {
                    task.phase = .live(.running)
                }
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
                   task.pendingModel == nil, let watch = modelOverrideWatch[id] {
                    if modelHonored(reported: mid, requested: watch.requested, agentId: task.agentId) {
                        modelOverrideWatch[id] = nil          // re-seat confirmed by the agent itself
                    } else if !modelHonored(reported: mid, requested: watch.left, agentId: task.agentId) {
                        // Neither the model we asked for NOR the one we left — the session deliberately
                        // switched to a third model (`/model`). Not a vendor fault; stop watching.
                        modelOverrideWatch[id] = nil
                    } else if watch.strikes >= 1 {
                        modelOverrideWatch[id] = nil
                        modelReseatIgnored = (watch.requested, mid)   // emitted below, once the write lands
                    } else {
                        modelOverrideWatch[id] = (watch.requested, watch.left, watch.strikes + 1)
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
                // The agent's observed run-state maps onto a `.live(_)` phase — UNLESS doing so would rip a
                // card with an OUTSTANDING LAUNCH INTENT out of its being-born phase on the word of a report
                // we cannot attribute to the relaunched session.
                //
                // `.relaunching → .live` is a legal edge and report()'s phase write is only epoch-fenced when
                // the report is STAMPED. An unstamped one (Codex's file-tail reports carry no epoch) from the
                // still-dying old session would otherwise land the card `.live` before the stepper ever
                // claims it: the relaunch is then never performed (no stepper visits a `.live` card), and the
                // staged `pendingSeed`/`pendingModel` are stranded on a card that silently kept running its
                // OLD session — the handoff dropped, the re-seat replayed onto some later launch.
                //
                // Today the daemon happens to be safe only because `reconcile()` runs before `pollTelemetry()`
                // in the same tick (orchestrad/main.swift), so the tailer never observes an unclaimed
                // `.relaunching` card. That is an ordering coincidence, not a guarantee. This fence makes the
                // invariant explicit: only a report proven to come from the CURRENT generation may land a card
                // that still owes a launch. The stepper (or the adopt path) lands it otherwise, consuming the
                // intent as it goes.
                // B3 D7: a being-born card is landed `.live` ONLY by a report proven to come from the
                // CURRENT generation (a stamped, epoch-matched signal). The old gate required this only when
                // the card `owesLaunch` (pendingSeed/pendingModel set) — but B3's de-drain means a cold
                // idle-wake relaunch now carries NEITHER (the inbox lives in the relaunchSeed claim, not
                // pendingSeed), so an unstamped file-tail snapshot from the dying predecessor would land the
                // card `.live` before the stepper ever claims its seed, stranding the delivery. Dropping the
                // `owesLaunch` term makes the invariant complete: the stepper (or the adopt path) lands a
                // being-born card; a non-current-generation report never does.
                // The SAME predicate the event half applies (hoisted to `staleGeneration` above), so the two
                // halves cannot drift apart on what counts as an attributable report.
                if let run = snap.run, task.phase.kind != .dead, !bringUpOwnsLanding, attributable {
                    task.phase = .live(run)
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

        // Phase change → the funnel. `observedEpoch` fences a superseded generation (a stale liveness
        // signal is dropped as a no-op). The companion `mutate` carries the dead metadata atomically with
        // the phase write; the funnel emits the upsert, runs conclusions, and fires wake-on-live.
        if targetPhase != before.phase {
            // report() is the THIRD `.live` landing, besides the two steppers — and it needs their COMPANION
            // CLEANUP, not just their phase write. When a relaunch's readiness times out, the RelaunchStepper
            // `break`s (PhaseStepper.swift) leaving the card `.relaunching` even though the session came
            // up, and `runStep` releases its claim (+Reconcile.swift). The new session's own report then
            // finds `bringUpOwnsLanding == false` and lands the card `.live` here, over a legal
            // `.relaunching → .live` edge (+Lifecycle.swift). Without this, `pendingSeed`/`pendingModel`
            // are stranded SET on a live card that no stepper will visit again — so the next ordinary
            // restart/resume would replay the handoff seed and silently relaunch on a stale re-seat model,
            // overriding whatever the session had switched to. Scoped to a landing FROM a being-born phase,
            // which is the only way an intent can still be outstanding.
            //
            // Gated on the report being STAMPED WITH THE CURRENT GENERATION. That is the proof the launch
            // actually happened and this is the new session talking — only then have the seed and the model
            // been delivered, and only then may they be consumed. An UNSTAMPED report is not proof of
            // anything (Codex's file-tail reports carry no epoch), and the dying session can still be writing
            // rollout lines while the card sits `.relaunching` with its relaunch not yet run; consuming on
            // one of those would DROP a handoff seed that was never delivered. Fail safe: don't consume.
            let landsFromBringUp = targetPhase.kind == .live
                && (before.phase.kind == .relaunching || before.phase.kind == .launching)
                && observedEpoch == task.sessionEpoch
            let landingAdapter = try? registry.get(task.agentId)
            let result = await transition(id, to: targetPhase, observedEpoch: observedEpoch) { t in
                t.deadReason = targetDeadReason
                t.deadDetail = targetDeadDetail
                if landsFromBringUp {
                    t.pendingSeed = nil
                    if let landingAdapter { consumeModelReseat(&t, landingAdapter) }
                }
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

        // B3 held-relaunch confirm — UNCONDITIONAL (a delivery-proving line may change no field, so it
        // must run outside the `didChange` guard). A `.ticks`-readiness relaunch left its relaunchSeed lease
        // HELD; the first signal proven to come from the CURRENT generation confirms it (removes the messages
        // + rings). Read `before.phase` — the card is already `.live` from the tick landing, and report()
        // reverts the local `task.phase` to `before.phase` above. Provenance-fenced so a stale pre-kill line
        // or a daemon-restart replay never confirms: a fileTail line qualifies only on the SAME rollout path
        // AND at/after the persisted post-kill watermark; a hook qualifies only when its `observedEpoch`
        // matches the lease's epoch. Routed through `confirmDelivery` so the archive guard is never bypassed.
        //
        // The lease must ALSO belong to the card's CURRENT generation. The watermark alone fences only
        // within one launch: it proves the predecessor can't append past it, but NOT that a LATER
        // generation's line is unrelated. A held lease survives an epoch bump whenever the bump skips
        // `claimSeed`'s relaunchSeed re-own — the `LaunchStepper` path (reopen / creatingWorktree) never
        // claims — and a resume keeps `agentSessionId`, so the next session APPENDS to the same transcript
        // past the old watermark. Without this fence that line would confirm a stale lease, deleting
        // messages the new session never received (loss, not duplication). Stale ⇒ no confirm ⇒ the lease
        // expires and the arm re-delivers.
        if case .live = before.phase,
           let lease = (await inbox.peek(id)).first(where: {
               $0.lease?.route == .relaunchSeed && $0.lease?.epoch == before.sessionEpoch })?.lease {
            let proven: Bool
            if let tail {
                proven = tail.path == lease.tailPath
                    && lease.tailWatermark.map { tail.startOffset >= $0 } == true
            } else if let observedEpoch {
                proven = observedEpoch == lease.epoch
            } else {
                proven = false
            }
            if proven { await confirmDelivery(token: lease.token, cardId: id) }
        }
    }

    /// The coarse activity word for a phase — the transition vocabulary the Activity feed used to read
    /// off `status`.
    private static func activityWord(_ phase: Phase) -> String? {
        switch phase {
        case .live(.running):   return "running"
        case .live(.waiting):   return "waiting"
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
}
