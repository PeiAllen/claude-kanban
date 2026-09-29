import Foundation

/// Plain value types for `SharedStore` — split out from `SharedStore.swift` to keep that file
/// under the design's 550-line target; these carry no behavior of their own.

public struct StoreHandle: Sendable, Equatable {
    public let storeGitDir: String
    public let checkoutGitDir: String
    public let workTree: String
    public let emptyTreeHash: String
}

public enum SharedStoreError: Error, Sendable, Equatable {
    case gitDidNotRun(argv: [String])
    case gitFailed(argv: [String], exitCode: Int32, stderr: String)
    case sendRetriesExhausted
    /// A batch `IgnoreProbe.classify` failure (`.unknown`) inside a write-out — unlike
    /// `.notARepo` (a stable, permanent state, safe to treat as "nothing ignored here"), this is
    /// a transient probe failure that must never be read as "safe to write" or "safe to advance
    /// HEAD past". Thrown rather than folded into an outcome case, matching every other
    /// SharedStore failure mode.
    case ignoreProbeFailed(detail: String)
}

public enum CommitWarning: Sendable, Equatable {
    case strayUnstaged(paths: [String])
    case oversized(path: String)
    case gitlink(path: String)
}

public enum CommitOutcome: Sendable, Equatable {
    case committed(sha: String, warnings: [CommitWarning])
    case nothingToCommit(warnings: [CommitWarning])
}

public enum ReceiveOutcome: Sendable, Equatable {
    case upToDate
    case materialized(written: [String], deleted: [String])
    case partial(dirty: [String])
    case conflicted(paths: [String], storeSha: String)
}

public enum SendOutcome: Sendable, Equatable {
    case nothingToDo
    case pushed
    case refusedOutOfSet(paths: [String])
    case conflicted(paths: [String], storeSha: String)
    case partial(dirty: [String])
}

public enum ResolveOutcome: Sendable, Equatable {
    case resolved
    case nothingToResolve
    case refusedMarkers(paths: [String])
    case sendOutcome(SendOutcome)
}

/// A tiny thread-safe error box, matching the `DataBox` pattern already in `Proc.swift` — used to
/// carry a thrown error out of an unstructured `Task` in `SharedStore.runSeedSerialized`.
final class ThrownErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: Error?
    func set(_ error: Error) { lock.lock(); _error = error; lock.unlock() }
    func get() -> Error? { lock.lock(); defer { lock.unlock() }; return _error }
}
