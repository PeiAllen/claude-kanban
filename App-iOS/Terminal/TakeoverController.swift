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

    init(cardId: UUID, model: BoardModel) {
        self.cardId = cardId
        self.model = model
    }

    var isHolding: Bool { if case .holding = phase { return true }; return false }
    var target: TmuxTarget? { if case .holding(let t) = phase { return t }; return nil }

    /// Acquire the lease and start heartbeating. Called once on view appear.
    func begin() async {
        guard case .acquiring = phase else { return }
        guard let result = await model.takeOverAgentTerminalAsPhone(cardId) else {
            // A dismissal that raced the acquire (returnToDesktop ran at `.acquiring`, which held nothing to
            // release) leaves nothing to clean up when the grant itself failed — just don't overwrite the
            // teardown with a `.failed` cover the user can no longer see.
            if !released { phase = .failed("Couldn't take over the agent terminal — the daemon didn't grant the lease.") }
            return
        }
        epoch = result.state.epoch
        // #2: the surface may have been dismissed while this acquire RPC was in flight. `returnToDesktop()`
        // ran at `.acquiring`, where `isHolding` was false, so it released NOTHING — the just-granted lease
        // would otherwise be orphaned (a heartbeat nobody watches, stale in ~30s). Now that we know the
        // epoch, release it instead of entering `.holding`.
        guard !released else {
            await model.releaseAgentTerminalAsPhone(cardId, epoch: epoch)
            return
        }
        phase = .holding(result.target)
        startHeartbeat()
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
