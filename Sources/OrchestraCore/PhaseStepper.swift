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
    /// The sole `phase` writer, closed over the service actor. Steppers make progress ONLY through here.
    /// `mutate` is the companion field-write applied INSIDE the same `store.update` patch as the phase, so
    /// e.g. clearing `pendingSeed` (carried #1) or setting `archived`/`deadDetail`/`parentBranch`/`spawnBase`
    /// (carried #5) lands atomically with the phase. Callers pass `{ _ in }` when there is no companion.
    public let transition: @Sendable (_ id: UUID, _ to: Phase, _ observedEpoch: Int?,
                                      _ mutate: @escaping @Sendable (inout Task) -> Void) async -> TransitionResult
    /// Actor-bound materialization (fetch + `worktrees.ensure` + lineage recording + rollback + epilogue).
    public let materialize: @Sendable (_ id: UUID) async -> MaterializeOutcome
    /// Actor-bound bring-up + capability-gated readiness (wraps `launchAndConfirm`'s readiness machinery),
    /// so `readinessWaiters`/`pendingReadiness`/`launchReadyTicks` + `ORCH_EPOCH` stamping stay actor-owned.
    public let finishLaunch: @Sendable (_ id: UUID, _ flavor: LaunchFlavor) async -> ReadinessOutcome
    /// Actor-bound teardown duties Teardown can't reach from the struct: cancel treeStat/child-fanout
    /// debounces + remote watch + re-nudge timer AND the child find+nudge+wake (`lineage`/`derivedCard`/`wake`).
    public let teardownActorDuties: @Sendable (_ id: UUID) async -> Void
    /// Emit an activity feed entry (re-materialized / spawn-failed / backoff), closed over the actor.
    public let emitActivity: @Sendable (_ id: UUID, _ kind: ActivityKind, _ text: String) async -> Void

    public init(store: TaskStore, worktrees: WorktreeRegistry, sessions: any SessionManaging,
                adapters: AgentRegistry, inbox: Inbox,
                transition: @escaping @Sendable (UUID, Phase, Int?, @escaping @Sendable (inout Task) -> Void) async -> TransitionResult,
                materialize: @escaping @Sendable (UUID) async -> MaterializeOutcome,
                finishLaunch: @escaping @Sendable (UUID, LaunchFlavor) async -> ReadinessOutcome,
                teardownActorDuties: @escaping @Sendable (UUID) async -> Void,
                emitActivity: @escaping @Sendable (UUID, ActivityKind, String) async -> Void) {
        self.store = store; self.worktrees = worktrees; self.sessions = sessions
        self.adapters = adapters; self.inbox = inbox; self.transition = transition
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

/// Drives `.creatingWorktree` → `.launching` (or `.dead(.spawnFailed)`). Owns ALL of spawn's
/// materialization via `ctx.materialize` (so Task 3's spawn flip is a clean delete of the inline walk).
public struct MaterializeStepper: PhaseStepper {
    public init() {}
    public static var drives: Phase.Kind { .creatingWorktree }
    public func step(_ card: Task, _ ctx: ConvergeContext) async throws {
        switch await ctx.materialize(card.id) {
        case .launching(let parentBranch):
            _ = await ctx.transition(card.id, .launching, nil) { t in
                t.parentBranch = parentBranch
                t.spawnBase = nil   // consumed — the base is now recorded as lineage
            }
        case .failed(let detail):
            _ = await ctx.transition(card.id, .dead(.spawnFailed), nil) { t in
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

/// Drives `.launching` → `.live` (carries requirement #1: clear `pendingSeed` on readiness-at-epoch).
public struct LaunchStepper: PhaseStepper {
    public init() {}
    public static var drives: Phase.Kind { .launching }
    public func step(_ card: Task, _ ctx: ConvergeContext) async throws {
        guard let adapter = try? ctx.adapters.get(card.agentId) else { return }
        let flavor = deriveLaunchFlavor(card, adapter)
        let land = landing(of: flavor)
        let epoch = card.sessionEpoch
        switch await ctx.finishLaunch(card.id, flavor) {
        case .confirmed:
            _ = await ctx.transition(card.id, .live(land), epoch) { t in t.pendingSeed = nil }
        case .timedOut:
            break   // leave `.launching` for the reconciler's phaseChangedAt timeout (Task 2) — no hot-loop
        case .superseded:
            break   // a newer bring-up owns the card
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
                _ = await ctx.transition(card.id, .dead(.resumeFailed), nil) { t in
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
            _ = await ctx.transition(card.id, .dead(.resumeFailed), nil) { t in
                t.deadReason = .resumeFailed; t.deadDetail = "transcript gone"
            }
            return
        }
        let land = landing(of: flavor)
        let epoch = card.sessionEpoch
        switch await ctx.finishLaunch(card.id, flavor) {
        case .confirmed:
            _ = await ctx.transition(card.id, .live(land), epoch) { t in t.pendingSeed = nil }
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
    public func step(_ card: Task, _ ctx: ConvergeContext) async throws {
        // 1 · kill the agent session (idempotent — a gone session is a no-op).
        try? ctx.sessions.kill(ctx.sessions.sessionName(card.id))
        // 2 · release any bare-parent borrow the card left open (idempotent).
        try? await ctx.worktrees.releaseBorrow(borrowerCardId: card.id)
        // 3 · origin-aware run-dir reclaim, matching today's `archive()` switch.
        switch card.origin {
        case .worktree:
            // The SINGLE removal policy: keeps a shared/dirty tree, never force-drops (`force: false`).
            try? await ctx.worktrees.release(cardId: card.id, cards: await ctx.store.all(), force: false)
        case .scratch:
            // Truly ephemeral — rm -rf, DOUBLE-guarded (debug `assert` + the release-safe runtime `if`).
            // Conservative mode (post-corrupt boot, carry #3) removes NOTHING — the scratch dir's ownership
            // is as unprovable as a worktree's from an empty board, so the reclaim is gated on it too.
            assert(card.cwd.hasPrefix(Config.scratchRoot + "/"))   // never rm -rf outside the scratch root
            if !(await ctx.worktrees.conservativeMode), card.cwd.hasPrefix(Config.scratchRoot + "/") {
                try? FileManager.default.removeItem(atPath: card.cwd)
            }
        case .borrowed:
            break   // Orchestra never deletes a borrowed dir.
        }
        // 4 · actor-private duties: cancel debounces/remote-watch/re-nudge + child find→nudge→wake (dedup).
        await ctx.teardownActorDuties(card.id)
        // 5 · the final flip — companion-writing the `archived` Bool mirror atomically with the phase.
        _ = await ctx.transition(card.id, .archived(teardownComplete: true), nil) { t in t.archived = true }
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
