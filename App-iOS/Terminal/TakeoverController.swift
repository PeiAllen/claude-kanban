import SwiftUI
import OrchestraKit
import OrchestraUI

/// Drives one phone takeover session's lease lifecycle (PR T4): acquire the `agent` lease as `.phone`,
/// heartbeat it ~every 10s, drop the attach the moment a desktop Retake (or a release) flips ownership
/// away, and release cleanly on **Return to Desktop**. All lease RPCs go through `BoardModel`'s phone
/// methods, so `clientId` stays private to the shared model — this controller only knows *its* epoch.
///
/// Provider-neutral: the lease coordinates *who* attaches the real `agent` window; nothing here inspects
/// whether that window is running Claude or Codex.
@MainActor
final class TakeoverController: ObservableObject {
    enum Phase: Equatable {
        case acquiring                 // taking the lease
        case holding(TmuxTarget)       // we own it — attach + heartbeat
        case lostToDesktop             // desktop retook (or released) — attach dropped
        case failed(String)            // couldn't acquire (no daemon / RPC error)
    }

    @Published private(set) var phase: Phase = .acquiring

    let cardId: UUID
    private let model: BoardModel
    private var epoch = 0
    private var heartbeat: _Concurrency.Task<Void, Never>?
    private var released = false

    /// Heartbeat cadence + a guard: refresh well within D4's 30s stale window so a single dropped beat on
    /// a flaky mobile link doesn't strand the lease.
    private let heartbeatInterval: UInt64 = 10 * 1_000_000_000

    // F1 — bounded-retry acquire. Non-blocking spawn (PR4b) can return a card BEFORE its tmux `agent`
    // window exists, so a phone-spawn-into-agent takeover fails transiently (the daemon has no window to
    // lease yet). Retry while the card is being born; the `→ live` edge re-arms the budget for a long
    // checkout that outran it. Shares the same bounded backoff (1,2,4,8,8; max 5) as the terminal hosts.
    private var acquireAttempts = 0
    private let acquirePolicy = TerminalReconnectPolicy()
    private var acquiring = false        // an acquire loop is in flight (so a re-arm can't stack a second)
    private var lastCardLive = false     // edge detector for `cardPhaseChanged` → re-arm on false→true

    init(cardId: UUID, model: BoardModel) {
        self.cardId = cardId
        self.model = model
    }

    var isHolding: Bool { if case .holding = phase { return true }; return false }
    var target: TmuxTarget? { if case .holding(let t) = phase { return t }; return nil }

    /// Acquire the lease and start heartbeating. Called once on view appear. Because non-blocking spawn
    /// (PR4b) can return the card BEFORE its tmux `agent` window exists, the initial grant may fail
    /// transiently — so this drives a bounded RETRY loop while the card is being born, and the view re-arms
    /// it on the `→ live` edge (`cardPhaseChanged`) when a long checkout outran the fixed budget.
    func begin() async {
        await runAcquireLoop()
    }

    private func runAcquireLoop() async {
        guard !acquiring else { return }        // one loop at a time; a re-arm resets the budget in place
        acquiring = true
        defer { acquiring = false }
        while !released, case .acquiring = phase {
            if let result = await model.takeOverAgentTerminalAsPhone(cardId) {
                epoch = result.state.epoch
                // The surface may have been dismissed while this acquire RPC was in flight. `returnToDesktop()`
                // ran at `.acquiring`, where `isHolding` was false, so it released NOTHING — the just-granted
                // lease would otherwise be orphaned (a heartbeat nobody watches, stale in ~30s). Now that we
                // know the epoch, release it instead of entering `.holding`.
                guard !released else { await model.releaseAgentTerminalAsPhone(cardId, epoch: epoch); return }
                phase = .holding(result.target)
                startHeartbeat()
                return
            }
            if released { return }
            acquireAttempts += 1
            let born = cardIsBeingBorn
            guard TakeoverRetryDecision.shouldRetry(beingBorn: born, attemptsSoFar: acquireAttempts,
                                                    maxAttempts: acquirePolicy.maxReconnects),
                  let delay = acquirePolicy.delay(forAttempt: acquireAttempts) else {
                // No more retries this round. A live/dead card that STILL fails to grant is a genuine failure
                // (surface it); a being-born budget-exhaustion instead PAUSES in `.acquiring` (keeps showing
                // "Taking over…") until the `→ live` edge re-arms via `cardPhaseChanged`. A dismissal that
                // raced the acquire leaves nothing to cover, so never overwrite a teardown with `.failed`.
                if !released, TakeoverRetryDecision.isPermanentFailure(beingBorn: born) {
                    phase = .failed("Couldn't take over the agent terminal — the daemon didn't grant the lease.")
                }
                return
            }
            try? await _Concurrency.Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }
    }

    /// Is the card still being born (no `agent` window yet), so a failed acquire should retry rather than
    /// permanently fail? An unknown card (not yet in the store) reads as being-born — the safe default that
    /// keeps retrying instead of failing a card that's merely mid-spawn. Phase-driven → agent-agnostic.
    private var cardIsBeingBorn: Bool {
        guard let phase = model.tasks.first(where: { $0.id == cardId })?.phase else { return true }
        switch phase.kind {
        case .creatingWorktree, .launching, .relaunching: return true
        default:                                          return false
        }
    }

    /// The card's phase changed (the view feeds `card.phase` here). On the false→true `→ live` edge — the
    /// moment the `agent` window finally exists — RE-ARM the acquire budget and restart a paused/failed
    /// loop, because the fixed backoff (~15–23s) can be shorter than a long checkout. No-op once we hold /
    /// lost / released, and off the edge.
    func cardPhaseChanged(to cardPhase: OrchestraKit.Phase?) {   // the CARD's phase (nested `Phase` shadows it here)
        let isLive = (cardPhase?.kind == .live)
        defer { lastCardLive = isLive }
        guard TakeoverRetryDecision.shouldRearmOnLive(wasLive: lastCardLive, isLive: isLive) else { return }
        guard !released, !isHolding else { return }
        if case .lostToDesktop = phase { return }   // already resolved away — don't revive
        acquireAttempts = 0                          // re-arm the budget (the running loop, if any, picks it up)
        phase = .acquiring                           // revive a paused/failed acquire
        _Concurrency.Task { [weak self] in await self?.runAcquireLoop() }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let id = cardId, ep = epoch
        heartbeat = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(nanoseconds: self?.heartbeatInterval ?? 10_000_000_000)
                if _Concurrency.Task.isCancelled { return }
                guard let self else { return }
                // The reply is mirrored into `agentOwners`; `reconcile()` reads it (a desktop retake makes
                // the epoch-guarded heartbeat return the *desktop* owner → we detect the loss here).
                await self.model.heartbeatAgentTerminalAsPhone(id, epoch: ep)
                self.reconcile()
            }
        }
    }

    /// Re-check ownership against the mirrored owner snapshot. Called by the heartbeat AND by the view on
    /// every `agentOwners` change, so a desktop retake *event* is caught between beats, not only on a beat.
    func reconcile() {
        guard isHolding else { return }
        if !model.phoneStillHoldsAgentTerminal(cardId, epoch: epoch) {
            phase = .lostToDesktop
            heartbeat?.cancel(); heartbeat = nil
        }
    }

    /// Stop heartbeating and release the lease (epoch-guarded, so it can't clear a newer owner).
    /// Idempotent. This is the ONE teardown path: the **Return to Desktop** button calls it, and the view
    /// also calls it on `onDisappear` so a dismissal that isn't the button (swipe-down / programmatic
    /// dismiss) still hands control back instead of stranding a heartbeat-less lease that goes stale in
    /// ~30s while the surface still reads "You have control" (#8). There is no phone-side "suspend and
    /// resume": the takeover surface is presented in a `fullScreenCover`, so a dismiss tears down this
    /// `@StateObject` — a reopen builds a fresh controller that re-acquires from `.acquiring` via `begin()`.
    /// The daemon's 30s stale window is the only grace, and it covers a hard kill where `onDisappear`
    /// never runs.
    func returnToDesktop() async {
        heartbeat?.cancel(); heartbeat = nil
        guard !released else { return }
        released = true
        // Only release while we still hold it — once lost, the lease is already the desktop's and a stale
        // release would be a daemon no-op anyway.
        if isHolding {
            await model.releaseAgentTerminalAsPhone(cardId, epoch: epoch)
        }
    }
}
