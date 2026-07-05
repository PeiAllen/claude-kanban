import Foundation
import OrchestraKit

/// Pure phone-side rules for the agent-terminal ownership lease (PR T4). The daemon (PR D4) is the
/// authority for *who* owns a card's `agent` terminal; these functions decide what the **phone** does
/// about the owner snapshots it sees — chiefly: *do I (this phone) still hold the lease I took?* When the
/// answer flips to no (a desktop Retake, another phone, or a release), the takeover surface must drop its
/// live attach and stop heartbeating.
///
/// Symmetric to `DesktopTerminalPolicy`: AppKit-free, primitive-typed, so it compiles for iOS and is
/// exercised directly by `swift test` (`PhoneTakeoverPolicyTests`) without a daemon or a running app.

/// Whether THIS phone still holds a card's `agent` lease it acquired at `myEpoch`.
public enum PhoneTakeoverStatus: Equatable {
    case holding   // this phone client still owns it, at an epoch >= the one it took
    case lost      // released, taken by the desktop, or taken by a newer/other client — drop the attach
}

/// Decide, from the latest owner snapshot, whether this phone still holds the lease.
///
/// The takeover result gives the phone `(myClientId, myEpoch)`. Every later owner snapshot — a live
/// `agentTerminalOwner` event, a `heartbeat` reply, or a reconnect reconcile — is fed back here:
///
/// - No owner (`nil`) → the lease was released/cleared → **lost**.
/// - Owner is this phone (`.phone`, same `clientId`) at `epoch >= myEpoch` → **holding**. `>=` (not `==`)
///   so a benign self-retake on reconnect (which bumps the epoch under the same client) still reads as held.
/// - Anything else — `.desktop`, a different phone `clientId`, or a *lower* epoch (a stale snapshot from
///   before our takeover) — → **lost**. The desktop-Retake path lands here (`ownerKind == .desktop`), which
///   is exactly the signal the surface uses to show "Desktop retook control".
///
/// Fail-safe: the default is `.lost`. An ambiguous or unexpected snapshot drops the exclusive attach
/// rather than risk two live clients resize-fighting the one `agent` window.
public func phoneTakeoverStatus(myClientId: String, myEpoch: Int,
                                owner: AgentTerminalOwner?) -> PhoneTakeoverStatus {
    guard let owner else { return .lost }
    if owner.ownerKind == .phone, owner.clientId == myClientId, owner.epoch >= myEpoch {
        return .holding
    }
    return .lost
}
