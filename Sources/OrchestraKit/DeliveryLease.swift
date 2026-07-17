import Foundation

/// The three delivery routes a claimed batch can ride (L2 route table). The route is persisted on the
/// lease because the claimable set is route-sensitive: a retried relaunch re-owns its own prior
/// `relaunchSeed` lease at any epoch, so a restart never comes up seedless.
public enum DeliveryRoute: String, Codable, Sendable {
    case stopDrain, channelPush, relaunchSeed
}

/// A per-message delivery lease: the record that a batch is in flight to a specific session, so the
/// message can stay durable until receipt is proven. Persisted on `InboxMessage` (one file, one atomic
/// write — a sidecar lease file would reintroduce the two-file atomicity bug this design removes).
///
/// A message is re-claimable once its lease is older than `deliveryLeaseTimeout` OR its `epoch` is below
/// the claiming epoch (the funnel's epoch bump PROVES the leased session is gone, so re-claim is
/// immediate — no waiting out the timeout on a restart).
public struct DeliveryLease: Codable, Sendable, Equatable {
    /// Minted fresh on every (re-)lease. Confirms/releases are token-scoped, so a late ack from a
    /// superseded attempt can never remove a re-claimed message.
    public let token: UUID
    public let route: DeliveryRoute
    /// The `sessionEpoch` this batch was delivered to. Always read from the card on the service actor —
    /// the Inbox never guesses epochs.
    public let epoch: Int
    public let leasedAt: Date
    /// Rollout byte offset captured post-kill/pre-launch, and the path it came from. **Declared here,
    /// consumed in B3** (first-reference rule): they fence a held `relaunchSeed` lease's confirm so a
    /// stale pre-kill line — or a replayed one after a daemon restart — can never falsely confirm.
    public let tailWatermark: Int64?
    public let tailPath: String?

    public init(token: UUID = UUID(), route: DeliveryRoute, epoch: Int, leasedAt: Date,
                tailWatermark: Int64? = nil, tailPath: String? = nil) {
        self.token = token; self.route = route; self.epoch = epoch; self.leasedAt = leasedAt
        self.tailWatermark = tailWatermark; self.tailPath = tailPath
    }
}

/// What one atomic `Inbox.claim` yields: the token to confirm with, exactly the message ids the payload
/// rendered (never more — the fit runs inside the claim), and the rendered payload itself. `ids` may be
/// empty for a handoff-only `relaunchSeed` batch (payload non-empty, zero messages consumed).
public struct ClaimedBatch: Sendable, Equatable {
    public let token: UUID
    public let ids: [UUID]
    public let payload: String
    public init(token: UUID, ids: [UUID], payload: String) {
        self.token = token; self.ids = ids; self.payload = payload
    }
}
