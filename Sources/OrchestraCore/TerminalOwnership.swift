import Foundation

/// Key for an owned terminal: a card + a window (only `agent` in v1).
struct OwnerKey: Hashable, Sendable {
    let cardId: UUID
    let window: String
}

/// The daemon-authoritative, ephemeral ownership store for card `agent` terminals. A PURE value type:
/// every mutation takes an injected `now`, so the state machine (CAS, epoch monotonicity, staleness)
/// is deterministically unit-testable without a clock, an actor, or a socket. `OrchestraService`
/// (an actor) owns one instance and supplies `Date()` at the edge.
///
/// Per-card machine: available → desktopOwned → phoneOwned → desktopOwned (any→any via `takeOver`).
/// `epoch` is monotonic per card and never decreases — even across `release` — which is exactly what
/// makes a stale release/heartbeat safe: it can never match a newer owner.
struct TerminalOwnershipStore: Sendable {
    /// An owner goes stale this long after its last `takeOver`/`heartbeat`.
    var heartbeatTimeout: TimeInterval = 30
    static let agentWindow = "agent"

    private struct Slot { var owner: AgentTerminalOwner?; var epoch: Int }
    private var slots: [OwnerKey: Slot] = [:]

    private func isStale(_ owner: AgentTerminalOwner, now: Date) -> Bool {
        now.timeIntervalSince(owner.updatedAt) > heartbeatTimeout
    }

    private func state(_ key: OwnerKey, _ ref: String, now: Date) -> AgentTerminalOwnerState {
        let slot = slots[key]
        let owner = slot?.owner
        return AgentTerminalOwnerState(
            ref: ref, cardId: key.cardId, window: key.window,
            owner: owner, epoch: slot?.epoch ?? 0,
            stale: owner.map { isStale($0, now: now) } ?? false)
    }

    /// Current ownership snapshot (read-only).
    func snapshot(cardId: UUID, ref: String, now: Date,
                  window: String = agentWindow) -> AgentTerminalOwnerState {
        state(OwnerKey(cardId: cardId, window: window), ref, now: now)
    }

    /// Unconditional acquisition: bump the epoch, set the owner, refresh `updatedAt`. ALWAYS wins —
    /// this is how a desktop Retake or a second phone overrides a stale/older owner.
    mutating func takeOver(cardId: UUID, ref: String, clientId: String,
                           kind: AgentTerminalOwnerKind, now: Date,
                           window: String = agentWindow) -> AgentTerminalOwnerState {
        let key = OwnerKey(cardId: cardId, window: window)
        let nextEpoch = (slots[key]?.epoch ?? 0) + 1
        let owner = AgentTerminalOwner(ownerKind: kind, clientId: clientId, epoch: nextEpoch,
                                       cardId: cardId, window: window, updatedAt: now)
        slots[key] = Slot(owner: owner, epoch: nextEpoch)
        return state(key, ref, now: now)
    }

    /// Clear the owner ONLY if the caller holds the current epoch AND clientId. Epoch is preserved
    /// (monotonic) so a later `takeOver` still increments past it. Throws `ownershipDenied` on CAS miss.
    mutating func release(cardId: UUID, ref: String, clientId: String, epoch: Int, now: Date,
                          window: String = agentWindow) throws -> AgentTerminalOwnerState {
        let key = OwnerKey(cardId: cardId, window: window)
        guard let slot = slots[key], let owner = slot.owner,
              owner.epoch == epoch, owner.clientId == clientId else {
            throw OrchestraError.ownershipDenied("release: not the current owner (epoch \(epoch))")
        }
        slots[key] = Slot(owner: nil, epoch: slot.epoch)   // keep epoch monotonic
        return state(key, ref, now: now)
    }

    /// Archive-teardown tombstone: clear the owner of EVERY window of `cardId`, keeping each slot's
    /// epoch. Deliberately NOT CAS-gated — archive is authoritative (no client legitimately holds a
    /// dead card's terminal) — and deliberately NOT a slot removal: the epoch's monotonicity is what
    /// makes a stale release/heartbeat safe (see the type comment), and removing the slot would let a
    /// reopened card (same UUID) restart at epoch 1, ABA-matching a stale client's held epoch.
    /// Residue: one `Int` per archived (card, window), accepted.
    mutating func clearOwner(cardId: UUID) {
        for (key, slot) in slots where key.cardId == cardId && slot.owner != nil {
            slots[key] = Slot(owner: nil, epoch: slot.epoch)
        }
    }

    /// Refresh the owner's `updatedAt` ONLY if the caller holds the current epoch AND clientId. Throws
    /// on CAS miss (owner changed / was taken over). Returns the refreshed (fresh) state.
    mutating func heartbeat(cardId: UUID, ref: String, clientId: String, epoch: Int, now: Date,
                            window: String = agentWindow) throws -> AgentTerminalOwnerState {
        let key = OwnerKey(cardId: cardId, window: window)
        guard let slot = slots[key], let owner = slot.owner,
              owner.epoch == epoch, owner.clientId == clientId else {
            throw OrchestraError.ownershipDenied("heartbeat: not the current owner (epoch \(epoch))")
        }
        let refreshed = AgentTerminalOwner(ownerKind: owner.ownerKind, clientId: owner.clientId,
                                           epoch: owner.epoch, cardId: owner.cardId,
                                           window: owner.window, updatedAt: now)
        slots[key] = Slot(owner: refreshed, epoch: slot.epoch)
        return state(key, ref, now: now)
    }
}
