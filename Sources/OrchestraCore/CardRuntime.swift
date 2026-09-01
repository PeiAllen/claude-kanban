import Foundation

/// All of a card's **in-memory, card-lifetime** actor state, in one value. The point is structural:
/// teardown detaches the whole entry (`detachCardRuntime`), so a new per-card field added here is
/// torn down by construction — there is no hand-maintained duty list for it to fall off (the list
/// this replaces gained three hand-added entries in its final two weeks).
///
/// What does NOT live here, deliberately:
/// - `inFlightSteps` / `stepAttempts` — reconciler *driving* state, not card state: the teardown
///   step's own claim is live during teardown, and a failed teardown writes its backoff AFTER the
///   detach (the re-drive gate needs it).
/// - `watchRegistry` — persisted relational state; its watcher-side removal is a durable teardown
///   duty, not a struct field.
/// - Collaborator state (`TerminalOwnershipStore` slots, `RolloutTailer` cursors) — owned by their
///   stores; the detach *notifies* them.
///
/// Concurrency: value type, mutated only on the `OrchestraService` actor. The stored `Task` handles
/// and continuation are themselves `Sendable`; copies of the struct share the same underlying task
/// references, which is exactly what the detach's cancel-then-drop needs.
struct CardRuntime {

    // MARK: - The armed-task bag

    /// The per-card timer/loop slots. `CaseIterable` is load-bearing: the detach iterates
    /// `Armed.allCases`-independent `tasks.values`, so a new slot is cancelled at teardown by
    /// construction.
    enum ArmedSlot: Hashable, CaseIterable, Sendable {
        case remoteWatch          // BT6 remote merge-watch loop
        case mergeRequestNudge    // O2 re-nudge loop
        case diffStat             // footer diffstat debounce
        case treeStat             // branch-tree stat debounce
        case childFanout          // child tree-stat fan-out debounce
        case agentObservation     // structured provider event stream + reconnect loop
        case nativeInbox          // provider-native advisory inbox sender loop
    }

    /// One arming of one slot: the running task plus the **arming token** that fences every delayed
    /// callback the task may run after being superseded. Tokens are minted by
    /// `OrchestraService.nextRuntimeToken()` — a service-level monotonic counter, never reused for
    /// the process's life — so a callback from ANY earlier arming (same card or a reopened
    /// successor) can never match the current one. This replaces the per-card `?? 0 + 1` gen
    /// counters, whose restart-from-1 seeding was a verified ghost-match bug across archive→reopen.
    struct Armed {
        let token: UInt64
        let task: _Concurrency.Task<Void, Never>
    }

    /// The bag. Mutate ONLY via the service helpers (`arm`/`disarm`/`clearSlot(ifToken:)`) so the
    /// cancel-before-replace and token-fenced-clear disciplines hold everywhere.
    var tasks: [ArmedSlot: Armed] = [:]

    // MARK: - Live agent observation

    /// Exact subscription identity. The endpoint selects the launch-local provider server; epoch and
    /// provider session fence callbacks that were already queued when a source was superseded.
    struct AgentObservationIdentity: Equatable, Sendable {
        let endpoint: AgentObservationEndpoint
        let sessionEpoch: Int
        let binding: AgentObservationBinding
    }

    /// One ordered ingress for every provider observation affecting this card. The coordinator is
    /// reference-typed so copies of `CardRuntime` retain the same queue and correlation fence.
    let agentObservationCoordinator = AgentObservationCoordinator()
    var agentObservationIdentity: AgentObservationIdentity?
    /// Advances before every normalized provider observation enters the coordinator. Snapshot repairs
    /// capture it so an observation arriving while their subprocess runs makes the result stale.
    var agentObservationGeneration: UInt64 = 0

    /// Provider observations that arrived during the narrow readiness handoff before the stepper
    /// published `.live`. These are normalized source facts, not a second effective-state snapshot;
    /// the live landing drains them through the same coordinator/reducer as every later observation.
    struct PendingAgentSignals: Sendable {
        let context: AgentSignalContext
        var signals: [AgentSignal]
    }
    var pendingAgentSignals: PendingAgentSignals?

    // MARK: - Native message delivery

    /// Exact ownership fence for a live provider-native sender. Provider id prevents an endpoint from a
    /// mismatched hook adapter crossing the neutral Core seam; epoch and harness id fence superseded sessions.
    struct AgentMessageIdentity: Equatable, Sendable {
        let providerId: String
        let sessionEpoch: Int
        let harnessSessionId: String
    }

    /// The one bounded submission budget for the FIFO head. It follows the durable message snapshot and
    /// provider incarnation, but deliberately excludes the ephemeral endpoint so a credential refresh cannot
    /// turn one three-attempt budget into two.
    struct NativeInboxAttempt: Equatable, Sendable {
        let messageId: UUID
        let text: String
        let identity: AgentMessageIdentity
        let count: Int
    }

    /// A hook can report its endpoint just before the launch step publishes `.live`; retain that one
    /// current-generation value and install it at the lifecycle landing.
    struct PendingAgentMessageEndpoint: Sendable {
        let identity: AgentMessageIdentity
        let endpoint: AgentMessageEndpoint
    }

    /// The live sender and the endpoint it was built from. Replacement is centralized in
    /// `reconcileAgentMessageHandle`; detach closes the retained sender before dropping the runtime entry.
    final class AgentMessageHandle: Sendable {
        let identity: AgentMessageIdentity
        let endpoint: AgentMessageEndpoint
        let sender: any AgentMessageSender

        init(identity: AgentMessageIdentity, endpoint: AgentMessageEndpoint,
             sender: any AgentMessageSender) {
            self.identity = identity
            self.endpoint = endpoint
            self.sender = sender
        }
    }

    var pendingAgentMessageEndpoint: PendingAgentMessageEndpoint?
    var agentMessageHandle: AgentMessageHandle?
    /// Every producer advances this even while the single sender loop is active. The loop compares the value
    /// around its empty read so an enqueue cannot land in the clear-slot gap.
    var nativeInboxWakeGeneration: UInt64 = 0
    var nativeInboxAttempt: NativeInboxAttempt?

    // MARK: - Readiness

    /// The inline-readiness waiter (launch/relaunch bring-up). Token-tagged per waiter
    /// (`readinessTokenSeq`) and epoch-scoped; the detach resumes it `.superseded` — a
    /// `CheckedContinuation` must resume exactly once, and discarding the struct would leak it.
    /// (Unreachable at detach under today's step protocol — the registering step holds
    /// `inFlightSteps` until the waiter resolves — kept as a structural invariant.)
    var readinessWaiter: (token: UInt64, expectedEpoch: Int, cont: CheckedContinuation<ReadinessOutcome, Never>)?

    /// An early readiness confirmation that arrived before `awaitReadiness` registered its waiter
    /// (the reentrant-actor window), with the epoch it was observed at. Consumed by the next
    /// bring-up attempt.
    struct PendingReadiness { let epoch: Int? }
    var pendingReadiness: PendingReadiness?

    /// Consecutive liveness ticks a being-born card has had a live session and a pending waiter —
    /// the N=3 readiness fallback. Reset when the card leaves being-born.
    var launchReadyTicks: Int = 0

    // MARK: - Spawn startup-abort watch

    var spawnPending: Date?
    var spawnAttempts: Int = 0
    var spawnRelaunch: (adapterId: String, ctx: AdapterContext)?

    // MARK: - Remote-parent tier

    /// S3-1 once-latch for the persistent remote-parent warnings (gone / PR-closed-unmerged).
    var remoteWarned: Bool = false

    // MARK: - Watch / wait

    /// Live CLI `orchestra wait` processes for this watcher card.
    var activeWaitProcesses: Int = 0

    // MARK: - Funnel bookkeeping
    /// The generation that owes a system-supplied opening prompt. Set in `finishLaunch` and consumed
    /// once by `report()` so a launch seed is not mistaken for a direct human turn.
    var seedTurnEpoch: Int? = nil
    /// Per-card monotonic seq guard for snapshot reports.
    var lastSeq: UInt64 = 0
    /// The reconciler's last observed tmux session state (boardSnapshot cache).
    var observedSession: OrchestraService.ObservedSession?
    /// Last owner event broadcast (owner-visible-fields-only dedup).
    var lastEmittedOwnerSig: OrchestraService.OwnerEmitSig?
    /// The `--model` re-seat tripwire (cleared at `concludeCard` and on each relaunch).
    var modelOverrideWatch: (requested: String, left: String, strikes: Int)?
}

extension OrchestraService {

    /// Mint a process-unique token (arming fences). Monotonic for the daemon's life; never reused,
    /// which is the entire fence guarantee — see `CardRuntime.Armed`.
    func nextRuntimeToken() -> UInt64 {
        runtimeTokenSeq += 1
        return runtimeTokenSeq
    }

    /// The ONLY creator of runtime entries (A1). Gated on the card's `archived` bit — set at the
    /// archive intent, cleared by reopen — so an archived card can never regain an entry no matter
    /// which path writes late (the report funnel has no archived gate of its own). Callers pass the
    /// card they already fetched: possession is the store-presence proof, and every legitimate
    /// create site has it in hand.
    @discardableResult
    func ensureRuntime(for card: Task) -> Bool {
        guard !card.archived else { return false }
        if runtime[card.id] == nil { runtime[card.id] = CardRuntime() }
        return true
    }

    // MARK: - The armed-task bag helpers

    /// Install a new arming for `slot`: cancels any predecessor and mints the fence token the
    /// caller must capture into every delayed callback. Returns nil (and arms nothing) for a card
    /// with no runtime entry — post-archive arming is structurally impossible.
    func arm(_ id: UUID, _ slot: CardRuntime.ArmedSlot,
             _ make: (_ token: UInt64) -> _Concurrency.Task<Void, Never>) -> UInt64? {
        guard runtime[id] != nil else { return nil }
        runtime[id]?.tasks[slot]?.task.cancel()
        let token = nextRuntimeToken()
        runtime[id]?.tasks[slot] = CardRuntime.Armed(token: token, task: make(token))
        return token
    }

    /// Cancel + drop a slot unconditionally (the stop-path). Safe when absent.
    func disarm(_ id: UUID, _ slot: CardRuntime.ArmedSlot) {
        runtime[id]?.tasks[slot]?.task.cancel()
        runtime[id]?.tasks[slot] = nil
    }

    /// Token-fenced terminal self-clear: a finished task drops its own slot ONLY if the slot still
    /// holds its arming. A superseded task's late clear no-ops instead of nil-ing the live
    /// replacement — the ghost-orphan race the old gen counters fenced for the two loops, now
    /// closed for every slot.
    func clearSlot(_ id: UUID, _ slot: CardRuntime.ArmedSlot, ifToken token: UInt64) {
        guard runtime[id]?.tasks[slot]?.token == token else { return }
        runtime[id]?.tasks[slot] = nil
    }

    /// The current arming token for a slot (0 = not armed). The loops' mid-tick ghost gates compare
    /// their captured token against this.
    func armingToken(_ id: UUID, _ slot: CardRuntime.ArmedSlot) -> UInt64 {
        runtime[id]?.tasks[slot]?.token ?? 0
    }

    // MARK: - Detach

    /// The in-memory half of teardown: cancel every armed task, resume any readiness waiter
    /// `.superseded`, release the card's terminal-ownership owners (epoch-preserving tombstone),
    /// and drop the entry. Synchronous on the actor and no-op-safe when the entry is absent (a
    /// crash-redrive arrives with an empty runtime map). Durable duties (watch-registry watcher
    /// side, child nudge, card-file sweep) are NOT here — they run in `teardownActorDuties`
    /// regardless of runtime presence.
    func detachCardRuntime(_ id: UUID) {
        guard var rt = runtime[id] else {
            terminalOwnership.clearOwner(cardId: id)   // store-side tombstone is entry-independent
            return
        }
        for armed in rt.tasks.values { armed.task.cancel() }
        rt.tasks = [:]
        rt.agentMessageHandle?.sender.shutdown()
        rt.agentMessageHandle = nil
        rt.pendingAgentMessageEndpoint = nil
        if let waiter = rt.readinessWaiter {
            rt.readinessWaiter = nil
            waiter.cont.resume(returning: .superseded)
        }
        terminalOwnership.clearOwner(cardId: id)
        runtime[id] = nil
    }
}
