import Foundation

/// Provider-neutral, current-turn activity text. This is live observation, not durable progress history
/// and not evidence that a top-level turn is open.
public struct ActivitySummary: Codable, Equatable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// The provider's current aggregate reason it needs a person. This is deliberately a fact, rather
/// than a list of request objects: the provider is authoritative for its own active prompt state.
public enum ProviderHumanNeed: String, Codable, Equatable, Sendable {
    case unspecified
    case permission
    case input
}

/// Aggregate provider commitment to start another turn without human or Orchestra input. Providers may
/// combine several native wake sources before emitting this marker; those sources do not leak into Core.
public struct AutomaticResume: Codable, Equatable, Sendable {
    public init() {}
}

public struct WaitingInfo: Codable, Equatable, Sendable {
    public var resume: AutomaticResume?

    public init(resume: AutomaticResume? = nil) {
        self.resume = resume
    }
}

/// Orchestra's current view of whether a live card's provider has an open top-level turn.
public enum TurnStatus: Codable, Equatable, Sendable {
    case running
    case waiting(WaitingInfo = WaitingInfo())
    case unavailable

    private enum CodingKeys: String, CodingKey {
        case name
        case detail
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .running:
            try container.encode("running", forKey: .name)
        case .waiting(let info):
            try container.encode("waiting", forKey: .name)
            try container.encode(info, forKey: .detail)
        case .unavailable:
            try container.encode("unavailable", forKey: .name)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        switch name {
        case "running":
            self = .running
        case "waiting":
            self = .waiting(try container.decode(WaitingInfo.self, forKey: .detail))
        case "unavailable":
            self = .unavailable
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "unknown TurnStatus case \"\(name)\""
            )
        }
    }
}

/// The complete provider-neutral state attached to a live card. It is a current snapshot: leaving the
/// live lifecycle phase discards it, and a later live phase reconstructs it from provider observation.
public struct AgentState: Codable, Equatable, Sendable {
    public var turnStatus: TurnStatus
    public var activity: ActivitySummary?
    public var humanNeed: ProviderHumanNeed?

    public init(
        turnStatus: TurnStatus,
        activity: ActivitySummary? = nil,
        humanNeed: ProviderHumanNeed? = nil
    ) {
        self.turnStatus = turnStatus
        self.activity = activity
        self.humanNeed = humanNeed
    }

    private enum CodingKeys: String, CodingKey {
        case turnStatus
        case activity
        case humanNeed
        // A previous release persisted this array. Its detailed state is stale after a restart, so
        // decode the containing snapshot but deliberately expose observation as unavailable.
        case activeRequests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !container.contains(.activeRequests) else {
            self.init(turnStatus: .unavailable)
            return
        }
        self.init(
            turnStatus: try container.decode(TurnStatus.self, forKey: .turnStatus),
            activity: try container.decodeIfPresent(ActivitySummary.self, forKey: .activity),
            humanNeed: try container.decodeIfPresent(ProviderHumanNeed.self, forKey: .humanNeed)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(turnStatus, forKey: .turnStatus)
        try container.encodeIfPresent(activity, forKey: .activity)
        try container.encodeIfPresent(humanNeed, forKey: .humanNeed)
    }

    /// Whether the provider owns the next move. `nil` means observation is unavailable, not false.
    public var workInFlight: Bool? {
        switch turnStatus {
        case .running:
            return true
        case .waiting(let info):
            return info.resume != nil
        case .unavailable:
            return nil
        }
    }

    public var isWaiting: Bool {
        if case .waiting = turnStatus { return true }
        return false
    }

    public var providerRequiresHuman: Bool {
        humanNeed != nil
    }
}

extension AgentState {
    public static var running: AgentState { .init(turnStatus: .running) }
    public static var waiting: AgentState { .init(turnStatus: .waiting()) }
}
