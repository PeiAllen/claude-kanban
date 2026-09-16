import Foundation

/// A path's propagation intent, chosen by the user. Orchestra derives the mechanism (symlink for a
/// directory, copy-in plus write-back for a file) from the path's shape — never from this value.
public enum PropagationPolicy: String, Codable, Sendable, CaseIterable {
    /// Git already puts the path in every worktree. Only valid for a path inside the repo.
    case tracked
    /// One instance, visible to every card. The only value with a propagation mechanism.
    case shared
    /// Nothing happens. The path dies with the worktree.
    case ephemeral
}

/// One named group of paths an adapter (or a user) declares for propagation.
public struct PropagationItem: Codable, Sendable, Equatable, Hashable {
    public let name: String
    public let paths: [String]
    public let exclusions: [String]

    public init(name: String, paths: [String], exclusions: [String]) {
        self.name = name
        self.paths = paths
        self.exclusions = exclusions
    }
}

/// Which of an adapter's launch writes are allowed, computed per launch from the resolved policy
/// table. Dormant until PR5/PR6 wire it into `AdapterContext` — never persisted, so it carries no
/// `Codable` conformance.
public struct PropagationGrant: Sendable, Equatable {
    public let writablePaths: Set<String>

    public init(writablePaths: Set<String>) {
        self.writablePaths = writablePaths
    }
}
