import Foundation

/// A stateless, idempotent driver for ONE transitional phase. The reconciler (a later PR) dispatches by
/// `Phase.Kind`; verbs never reference steppers. A stepper holds NO per-card state — the card arrives as
/// an argument because crash recovery's whole premise is that phase + persisted fields re-derive
/// everything from disk. The four concrete steppers (Materialize/Launch/Relaunch/Teardown) land in PR4b.
public protocol PhaseStepper: Sendable {
    /// The phase this stepper drives toward its target.
    static var drives: Phase.Kind { get }   // creatingWorktree | launching | relaunching | archivedPending
    /// Advance the card one edge toward the target. MUST be idempotent — re-running from the same
    /// persisted phase produces no additional side effect.
    func step(_ card: Task, _ ctx: ConvergeContext) async throws
    /// Has the target been reached? The crash-convergence oracle (PR4b's matrix tests).
    func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool
}

/// The outcome of `ConvergeContext.materialize` — the actor-bound worktree/scratch materialization the
/// `MaterializeStepper` delegates to (remote-base fetch + `worktrees.ensure` + lineage recording + the
/// S2-3(iii) rollback + the resource epilogue). Keeps `lineage`/`remoteParents` actor-owned.
public enum MaterializeOutcome: Sendable {
    /// The cwd materialized — advance to `.launching`, adopting the (re-derived) parent branch.
    case launching(parentBranch: String?)
    /// Materialization failed (fetch/ensure/lineage) AFTER any rollback ran — mark `.dead(.spawnFailed)`.
    case failed(detail: String)
    /// A newer intent made the card terminal DURING the `ensure` await — the epilogue already released the
    /// just-cut tree; do NOT transition (the card is already terminal).
    case terminalNoop
}

/// A plain dependency bundle handed to every stepper, so steppers are testable with stubs and steppable
/// off the service actor. Carries no behavior — just references to the real machinery, plus a handful of
/// closures that re-enter the service actor for the duties that touch actor-private state (`lineage`,
/// `remoteParents`, `readinessWaiters`, `derivedCard`, `wake`, …). Steppers stay THIN orchestrators:
/// anything actor-private is delegated through a closure here, never reached directly from the struct.
public struct ConvergeContext: Sendable {
    public let store: TaskStore
    public let worktrees: WorktreeRegistry
    public let sessions: any SessionManaging
    public let adapters: AgentRegistry
    /// The card durable message queue — Teardown's dedup child-nudge writes through here.
    public let inbox: Inbox
    /// The scratch-root fence — teardown's `rm -rf` guard. Carried as a plain value (the stepper
    /// bundle has no Config); always the owning service's `config.scratchRoot`.
    public let scratchRoot: String
    /// The sole `phase` writer, closed over the service actor. Steppers make progress ONLY through here.
    /// `mutate` is the companion field-write applied INSIDE the same `store.update` patch as the phase, so
    /// e.g. clearing `pendingSeed` (carried #1) or setting `archived`/`deadDetail`/`parentBranch`/`spawnBase`
    /// (carried #5) lands atomically with the phase. Callers pass `{ _ in }` when there is no companion.
    /// `expecting` is the phase the caller was DISPATCHED for: the write applies only if the card is still
    /// in it. The epoch fence alone cannot catch a supersede that leaves the generation alone (the launch
    /// timeout's `markDead` does not bump `sessionEpoch`, and `dead → live` is a legal revival edge), so a
    /// step whose readiness confirms AFTER the timeout concluded the card would otherwise re-animate it.
    public let transition: @Sendable (_ id: UUID, _ to: Phase, _ observedEpoch: Int?, _ expecting: Phase.Kind?,
                                      _ mutate: @escaping @Sendable (inout Task) -> Void) async -> TransitionResult
    /// Actor-bound materialization (fetch + `worktrees.ensure` + lineage recording + rollback + epilogue).
    public let materialize: @Sendable (_ id: UUID) async -> MaterializeOutcome
    /// Actor-bound bring-up + capability-gated readiness (wraps `launchAndConfirm`'s readiness machinery),
    /// so `readinessWaiters`/`pendingReadiness`/`launchReadyTicks` + `ORCH_EPOCH` stamping stay actor-owned.
    /// `expecting`/`epoch` are the phase + generation the step was DISPATCHED for: the bring-up (`kill` +
    /// `ensure`) stands down `.superseded` if the card has left them, so a stale step can never tear down and
    /// re-create a live agent's session.
    public let finishLaunch: @Sendable (_ id: UUID, _ flavor: LaunchFlavor,
                                        _ expecting: Phase.Kind, _ epoch: Int) async -> ReadinessOutcome
    /// Actor-bound teardown duties Teardown can't reach from the struct: cancel treeStat/child-fanout
    /// debounces + remote watch + re-nudge timer AND the child find+nudge+wake (`lineage`/`derivedCard`/`wake`).
    public let teardownActorDuties: @Sendable (_ id: UUID) async -> Void
    /// Emit an activity feed entry (re-materialized / spawn-failed / backoff), closed over the actor.
    public let emitActivity: @Sendable (_ id: UUID, _ kind: ActivityKind, _ text: String) async -> Void

    public init(store: TaskStore, worktrees: WorktreeRegistry, sessions: any SessionManaging,
                adapters: AgentRegistry, inbox: Inbox, scratchRoot: String,
                transition: @escaping @Sendable (UUID, Phase, Int?, Phase.Kind?, @escaping @Sendable (inout Task) -> Void) async -> TransitionResult,
                materialize: @escaping @Sendable (UUID) async -> MaterializeOutcome,
                finishLaunch: @escaping @Sendable (UUID, LaunchFlavor, Phase.Kind, Int) async -> ReadinessOutcome,
                teardownActorDuties: @escaping @Sendable (UUID) async -> Void,
                emitActivity: @escaping @Sendable (UUID, ActivityKind, String) async -> Void) {
        self.store = store; self.worktrees = worktrees; self.sessions = sessions
        self.adapters = adapters; self.inbox = inbox; self.scratchRoot = scratchRoot
        self.transition = transition
        self.materialize = materialize; self.finishLaunch = finishLaunch
        self.teardownActorDuties = teardownActorDuties; self.emitActivity = emitActivity
    }
}

// MARK: - the four concrete steppers

/// Does the card have a resumable vendor transcript on disk? (agentSessionId present + the adapter's own
/// state path exists). Pure — mirrors `OrchestraService.isResumable`, but reachable from a stepper struct.
private func transcriptExists(_ card: Task, _ adapter: any Adapter) -> Bool {
    guard let sid = card.agentSessionId, !sid.isEmpty else { return false }
    let ctx = AdapterContext(cwd: card.cwd, repo: card.repo, model: card.model.id,
                             sessionId: sid, name: card.title)
    guard let tp = adapter.sessionInfo(ctx, current: sid, prior: card.priorSessionIds)?.transcriptPath
    else { return false }
    return FileManager.default.fileExists(atPath: tp)
}

/// The `.blank` landing (or `.waiting` for a resume). Extracted so Launch/Relaunch share the read — and
/// the reconciler's epoch-identity adopt (`+Reconcile`), which jumps `.launching→.live` WITHOUT the
/// LaunchStepper, so it must derive the same landing itself.
func landing(of flavor: LaunchFlavor) -> RunState {
    if case .blank(let l, _) = flavor { return l }
    return .waiting(.humanTurn)
}

/// Derive the launch flavor from persisted fields alone (crash-recovery re-derives from disk): a card
/// with a resumable transcript resumes (`pendingSeed` folded); else a blank launch that submits the
/// `initialPrompt` only for a real (non-provisional) first launch, landing `.running`; a provisional
/// (never-prompted) card lands `.waiting` with no positional.
func deriveLaunchFlavor(_ card: Task, _ adapter: any Adapter) -> LaunchFlavor {
    if transcriptExists(card, adapter) { return .resume(seed: card.pendingSeed) }
    let land: RunState = card.titleProvisional ? .waiting(.humanTurn) : .running
    let prompt: String? = card.titleProvisional ? nil : (card.initialPrompt.isEmpty ? nil : card.initialPrompt)
    return .blank(landing: land, prompt: prompt)
}

/// Conclude a bring-up that could not create a session at all, with the reason we actually hold.
///
/// A HOST-resource failure is the machine's fault, not the card's, so it gets its own `DeadReason` and
/// carries the resource + its numbers to the UI. Anything we do NOT positively recognise keeps the caller's
/// existing classification (`.spawnFailed` / `.resumeFailed`), so this never relabels a death it doesn't
/// understand — it only stops the detail from being thrown away.
///
/// `pendingSeed` is deliberately LEFT SET: the launch never happened, so a handoff/wake seed staged for it
/// must still ride the next resume rather than being silently dropped by a machine-wide hiccup.
private func concludeFailedLaunch(_ id: UUID, _ failure: LaunchFailure, fallback: DeadReason,
                                  expecting: Phase.Kind, ctx: ConvergeContext) async {
    let reason: DeadReason = failure.resource != nil ? .resourceExhausted : fallback
    let result = await ctx.transition(id, .dead(reason), nil, expecting) { t in
        t.deadReason = reason
        t.deadDetail = failure.detail
        t.deadResource = failure.resource
    }
    // An exhausted host takes down EVERY card's ability to start a terminal, so say it once at board level
    // too — the Recovery panel is only seen by someone who already clicked the card they think is broken.
    if result == .applied, let report = failure.resource {
        await ctx.emitActivity(id, .warning, "\(report.headline) \(report.resource.remedy)")
    }
}

/// Drives `.creatingWorktree` → `.launching` (or `.dead(.spawnFailed)`). Owns ALL of spawn's
/// materialization via `ctx.materialize` (so Task 3's spawn flip is a clean delete of the inline walk).
public struct MaterializeStepper: PhaseStepper {
    public init() {}
    public static var drives: Phase.Kind { .creatingWorktree }
    public func step(_ card: Task, _ ctx: ConvergeContext) async throws {
        switch await ctx.materialize(card.id) {
        case .launching(let parentBranch):
            _ = await ctx.transition(card.id, .launching, nil, .creatingWorktree) { t in
                t.parentBranch = parentBranch
                t.spawnBase = nil   // consumed — the base is now recorded as lineage
            }
        case .failed(let detail):
            _ = await ctx.transition(card.id, .dead(.spawnFailed), nil, .creatingWorktree) { t in
                t.deadReason = .spawnFailed; t.deadDetail = detail
            }
        case .terminalNoop:
            break   // a newer intent already made the card terminal; materialize released what it cut
        }
    }
    public func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool {
        guard let now = await ctx.store.get(card.id) else { return false }
        return FileManager.default.fileExists(atPath: now.cwd) && now.phase.kind != .creatingWorktree
    }
}

/// Consume a staged `--model` re-seat on the `.live` landing — the exact companion cleanup `pendingSeed`
/// gets, and for the same reason: the intent has now been delivered (the session is up, launched with this
/// model), so it must not be replayed onto a later launch. It also RE-ASSERTS `model` from the request,
/// because the outgoing session's final statusline can revert `model` while the card is `.relaunching`
/// (report()'s model write is not epoch-fenced), and the card must end up displaying the model it actually
/// came up on. A launch that FAILED never reaches here, so `pendingModel` survives for the retry — again
/// mirroring `pendingSeed`.
/// The adapter is OPTIONAL because the intent must be consumed either way. The adopt path resolves its
/// adapter with `try?`, and if that ever fails, clearing `pendingSeed` while leaving `pendingModel` set
/// would strand the re-seat on a successfully-landed card — replaying it onto some later launch. Without
/// an adapter we can't resolve the id to a full `AgentModel` for display, so `model` is left as-is; but
/// the INTENT is always consumed, because the launch it described has happened.
func consumeModelReseat(_ t: inout Task, _ adapter: (any Adapter)?) {
    guard let want = t.pendingModel else { return }
    if let adapter { t.model = adapter.model(for: want) }
    t.pendingModel = nil
}

/// Drives `.launching` → `.live` (carries requirement #1: clear `pendingSeed` on readiness-at-epoch).
public struct LaunchStepper: PhaseStepper {
    public init() {}
    public static var drives: Phase.Kind { .launching }
    public func step(_ card: Task, _ ctx: ConvergeContext) async throws {
        guard let adapter = try? ctx.adapters.get(card.agentId) else { return }
        let flavor = deriveLaunchFlavor(card, adapter)
        let land = landing(of: flavor)
        let epoch = card.sessionEpoch
        switch await ctx.finishLaunch(card.id, flavor, .launching, epoch) {
        case .confirmed:
            // `expecting: .launching` — the landing carries the same fence as the bring-up: if the launch
            // timeout concluded the card while we were confirming readiness, do NOT revive it.
            _ = await ctx.transition(card.id, .live(land), epoch, .launching) { t in
                t.pendingSeed = nil
                consumeModelReseat(&t, adapter)
            }
        case .launchFailed(let failure):
            // The session could not be created and we KNOW why — conclude now with the real reason rather
            // than idling in `.launching` until the timeout overwrites it with "launch timed out after 30s".
            await concludeFailedLaunch(card.id, failure, fallback: .spawnFailed,
                                       expecting: .launching, ctx: ctx)
        case .timedOut:
            break   // leave `.launching` for the reconciler's phaseChangedAt timeout (Task 2) — no hot-loop
        case .superseded:
            break   // a newer bring-up / landing owns the card (it left `.launching` or bumped its epoch)
        }
    }
    public func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool {
        guard let now = await ctx.store.get(card.id), now.phase.kind == .live else { return false }
        let e = (try? ctx.sessions.stampedEpoch(name: ctx.sessions.sessionName(now.id))) ?? nil
        return e == now.sessionEpoch
    }
}

/// Drives `.relaunching` → `.live` (or `.dead(.resumeFailed)`). Re-materializes a missing worktree first.
public struct RelaunchStepper: PhaseStepper {
    public init() {}
    public static var drives: Phase.Kind { .relaunching }
    public func step(_ card: Task, _ ctx: ConvergeContext) async throws {
        guard let adapter = try? ctx.adapters.get(card.agentId) else { return }
        // Require the worktree — re-materialize a tree deleted under a live card (emit when recreated).
        // A branch that is ALSO gone throws here → fail safe to `.dead(.resumeFailed)`.
        if card.origin == .worktree {
            do {
                let wt = try await ctx.worktrees.ensure(repo: card.repo, branch: card.branch, cardId: card.id)
                if wt.created {
                    await ctx.emitActivity(card.id, .recovered, "re-materialized worktree for “\(card.title)”")
                }
            } catch {
                _ = await ctx.transition(card.id, .dead(.resumeFailed), nil, .relaunching) { t in
                    t.deadReason = .resumeFailed; t.deadDetail = "worktree/branch gone: \(error)"
                }
                return
            }
        }
        // Resume when resumable (`pendingSeed` folded); a provisional card is a blank restart; a
        // non-provisional card whose transcript vanished can't resume → fail safe.
        let flavor: LaunchFlavor
        if transcriptExists(card, adapter) {
            flavor = .resume(seed: card.pendingSeed)
        } else if card.titleProvisional {
            flavor = .blank(landing: .waiting(.humanTurn), prompt: nil)
        } else {
            _ = await ctx.transition(card.id, .dead(.resumeFailed), nil, .relaunching) { t in
                t.deadReason = .resumeFailed; t.deadDetail = "transcript gone"
            }
            return
        }
        let land = landing(of: flavor)
        let epoch = card.sessionEpoch
        switch await ctx.finishLaunch(card.id, flavor, .relaunching, epoch) {
        case .confirmed:
            _ = await ctx.transition(card.id, .live(land), epoch, .relaunching) { t in
                t.pendingSeed = nil
                consumeModelReseat(&t, adapter)
            }
        case .launchFailed(let failure):
            await concludeFailedLaunch(card.id, failure, fallback: .resumeFailed,
                                       expecting: .relaunching, ctx: ctx)
        case .timedOut:
            break   // leave `.relaunching` for the reconciler's timeout (Task 2) — keeps `pendingSeed`
        case .superseded:
            break   // a newer relaunch bumped the epoch and owns the card (single-winner discipline)
        }
    }
    public func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool {
        guard let now = await ctx.store.get(card.id), now.phase.kind == .live else { return false }
        let e = (try? ctx.sessions.stampedEpoch(name: ctx.sessions.sessionName(now.id))) ?? nil
        return e == now.sessionEpoch
    }
}

/// Drives `.archivedPending` → `.archivedComplete`. Each duty idempotent (crash-then-redrive safe),
/// sourced from the current `archive()` body. Reachable-via-`ctx` duties live here; the actor-private
/// ones (debounce/watch cancels + child nudge) go through `ctx.teardownActorDuties`.
public struct TeardownStepper: PhaseStepper {
    public init() {}
    public static var drives: Phase.Kind { .archivedPending }

    /// Does the card STILL carry the archive intent this step was dispatched for? Teardown is the one
    /// stepper whose duties are irreversible (a killed session, an `rm -rf`'d scratch dir, a released
    /// worktree), and `archivedPending` is NOT a resting phase: `reopen` is a legal edge straight out of it
    /// (`archivedPending → creatingWorktree`), so the card can be brought back up WHILE this step is in
    /// flight — every duty below suspends. An unfenced stale step would then tear down a card that a reopen
    /// already owns: the agent execs in a directory that no longer exists and its pane dies on the spot.
    /// So re-verify ownership before each duty and stand down the moment the card leaves the intent — the
    /// same single-winner discipline `finishLaunch` applies to ITS destructive `kill`+`ensure` hop.
    private func stillArchiving(_ id: UUID, _ ctx: ConvergeContext) async -> Bool {
        (await ctx.store.get(id))?.phase.kind == .archivedPending
    }

    public func step(_ card: Task, _ ctx: ConvergeContext) async throws {
        guard await stillArchiving(card.id, ctx) else { return }
        // 1 · kill the agent session (idempotent — a gone session is a no-op).
        try? ctx.sessions.kill(ctx.sessions.sessionName(card.id))
        guard await stillArchiving(card.id, ctx) else { return }
        // 2 · release any bare-parent borrow the card left open (idempotent).
        try? await ctx.worktrees.releaseBorrow(borrowerCardId: card.id)
        guard await stillArchiving(card.id, ctx) else { return }
        // 3 · origin-aware run-dir reclaim, matching today's `archive()` switch.
        switch card.origin {
        case .worktree:
            // The SINGLE removal policy: keeps a shared/dirty tree, never force-drops (`force: false`).
            try? await ctx.worktrees.release(cardId: card.id, cards: await ctx.store.all(), force: false)
        case .scratch:
            // Truly ephemeral — rm -rf, DOUBLE-guarded (debug `assert` + the release-safe runtime `if`).
            // Conservative mode (post-corrupt boot, carry #3) removes NOTHING — the scratch dir's ownership
            // is as unprovable as a worktree's from an empty board, so the reclaim is gated on it too.
            assert(card.cwd.hasPrefix(ctx.scratchRoot + "/"))   // never rm -rf outside the scratch root
            let conservative = await ctx.worktrees.conservativeMode
            // Re-fence AFTER that actor hop: the `rm -rf` is the point of no return, so it takes the
            // LAST possible ownership check (a reopen landing during the hop must not lose its cwd).
            guard await stillArchiving(card.id, ctx), !conservative,
                  card.cwd.hasPrefix(ctx.scratchRoot + "/") else { break }
            try? FileManager.default.removeItem(atPath: card.cwd)
        case .borrowed:
            break   // Orchestra never deletes a borrowed dir.
        }
        guard await stillArchiving(card.id, ctx) else { return }
        // 4 · actor-private duties: cancel debounces/remote-watch/re-nudge + child find→nudge→wake (dedup).
        await ctx.teardownActorDuties(card.id)
        // 5 · the final flip — companion-writing the `archived` Bool mirror atomically with the phase.
        _ = await ctx.transition(card.id, .archived(teardownComplete: true), nil, .archivedPending) { t in t.archived = true }
    }
    public func verify(_ card: Task, _ ctx: ConvergeContext) async -> Bool {
        (await ctx.store.get(card.id))?.phase.kind == .archivedComplete
    }
}

/// The reconciler-owned `Phase.Kind → PhaseStepper` map — the four real steppers plug in here. Kept as a
/// single named seam so the reconciler (Task 2) dispatches by kind without a structural change.
enum PhaseSteppers {
    static let byKind: [Phase.Kind: any PhaseStepper] = [
        .creatingWorktree: MaterializeStepper(),
        .launching:        LaunchStepper(),
        .relaunching:      RelaunchStepper(),
        .archivedPending:  TeardownStepper(),
    ]
}
