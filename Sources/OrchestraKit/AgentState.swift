import Foundation

/// Provider-neutral, current-turn activity text. This is live observation, not durable progress history
/// and not evidence that a top-level turn is open.
public struct ActivitySummary: Codable, Equatable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// One currently-open request for human action. Requests are orthogonal to turn status: a permission
/// request can sit inside a running turn, while an input request can remain after the turn has ended.
public struct AgentRequest: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case permission
        case input
    }

    public var id: String
    public var kind: Kind
    public var prompt: String?

    public init(id: String, kind: Kind, prompt: String? = nil) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
    }
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
    public var activeRequests: [AgentRequest]

    public init(
        turnStatus: TurnStatus,
        activity: ActivitySummary? = nil,
        activeRequests: [AgentRequest] = []
    ) {
        self.turnStatus = turnStatus
        self.activity = activity
        self.activeRequests = activeRequests
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

    public func hasRequest(kind: AgentRequest.Kind) -> Bool {
        activeRequests.contains { $0.kind == kind }
    }
}

extension AgentState {
    public static var running: AgentState { .init(turnStatus: .running) }
    public static var waiting: AgentState { .init(turnStatus: .waiting()) }
    public static var permissionRequested: AgentState {
        .init(
            turnStatus: .running,
            activeRequests: [.init(id: "permission", kind: .permission)]
        )
    }
}
