import Foundation
import OrchestraKit

/// In-memory registry of parked `channel-wait` long-polls — the Claude no-restart push transport's
/// daemon half.
///
/// **B4 ships this STARVED.** Every method below is real and operates on `parked`, but nothing in
/// this PR ever *writes* `parked`: the `park` entry point is D1's (`channel-wait`, the ControlServer
/// built-in beside `hook`). So `isAttached` is structurally false, `push` structurally refuses, and
/// `wake`'s channel branch is compiled, reachable-by-code-path, and unreachable-in-fact until D2
/// flips a capability. "Dark" means unreachable, never undeclared — `wake` and the TeardownStepper
/// call these methods, so the type must exist where it is first referenced.
///
/// Parking is keyed `(cardId, epoch)`: the broker matches a poll only at the card's CURRENT
/// generation, so a pre-relaunch bridge can never take or ack a new-epoch batch into a dead session.
/// A newer poll for the same key supersedes the older (single parked poll per generation).
public actor ChannelBroker {

    /// One parked long-poll. `connection` identifies the bridge socket so a close hook can drop
    /// exactly its polls; `resolve` answers that connection's held request and reports whether the
    /// response actually reached the bridge. D1 supplies a closure that resumes the held request's
    /// continuation — keeping the broker free of any transport type.
    ///
    /// `nil` resolves the poll EMPTY — the timeout/revoke shape, which the pump answers by
    /// re-polling. Every removal path below resolves rather than merely dropping: a parked
    /// `channel-wait` that is discarded without an answer hangs to its ~55s timer, and the bridge
    /// cannot re-poll at the new epoch until it does. `async` because "the write landed" is only
    /// knowable after the response is handed back — a synchronous closure could report at most "the
    /// continuation was still live", which is NOT what `push`'s Bool is contracted to mean.
    struct ParkedPoll: Sendable {
        let connection: UUID
        let resolve: @Sendable (ClaimedBatch?) async -> Bool
    }

    struct Key: Hashable, Sendable { let cardId: UUID; let epoch: Int }

    /// The parked polls. **No writer in B4** — see the type doc.
    private var parked: [Key: ParkedPoll] = [:]

    public init() {}

    /// Is a poll parked for this card at exactly this generation? The `wake` ladder's channel gate:
    /// liveness is observed, never assumed, so an unregistered or dead bridge degrades to the cold
    /// path instead of stranding the message.
    public func isAttached(_ cardId: UUID, epoch: Int) -> Bool {
        parked[Key(cardId: cardId, epoch: epoch)] != nil
    }

    /// Hand a claimed batch to the card's parked poll. `false` when nothing is parked or the write
    /// failed — the caller then RELEASES the claim and falls through cold in the same call, so the
    /// relaunch seed sees the full batch (no self-shadowing). A consumed poll is unparked either way;
    /// a failed write IS the detach.
    public func push(_ cardId: UUID, _ batch: ClaimedBatch, epoch: Int) async -> Bool {
        let key = Key(cardId: cardId, epoch: epoch)
        guard let poll = parked[key] else { return false }
        parked[key] = nil                     // consumed either way; a failed write IS the detach
        return await poll.resolve(batch)
    }

    /// Drop every poll on one connection (the universal per-connection close hook, D1). The
    /// connection is already gone, so resolving is best-effort — but it runs through the same
    /// `remove` path so there is exactly ONE removal discipline to reason about.
    public func detach(connection: UUID) async {
        await remove { $0.value.connection == connection }
    }

    /// Lifecycle teardown: drop every poll for a card, whatever its generation (TeardownStepper).
    public func detachAll(_ cardId: UUID) async {
        await remove { $0.key.cardId == cardId }
    }

    /// The funnel's epoch-bump duty: a bumped generation proves the leased session is gone, so every
    /// OLDER-epoch poll is revoked at once rather than lingering until its ~55s timer. This is the one
    /// EAGER action an epoch bump takes — leases themselves are re-owned lazily by the next claim.
    public func revokeOlderEpochs(_ cardId: UUID, epoch: Int) async {
        await remove { $0.key.cardId == cardId && $0.key.epoch < epoch }
    }

    /// The single removal path: unpark the matching polls and RESOLVE each one empty. Removing
    /// without resolving would leave the bridge's held request unanswered until its own timer —
    /// exactly the stall `revokeOlderEpochs` exists to prevent.
    private func remove(where match: (Dictionary<Key, ParkedPoll>.Element) -> Bool) async {
        let doomed = parked.filter(match)
        guard !doomed.isEmpty else { return }
        for key in doomed.keys { parked[key] = nil }        // unpark BEFORE resolving (no re-entry)
        for poll in doomed.values { _ = await poll.resolve(nil) }
    }
}
