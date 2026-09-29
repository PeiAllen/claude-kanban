import Foundation
import OrchestraKit

/// The five `SharedStore` operations `PropagationService` drives. A protocol (not the concrete actor)
/// so the service's orchestration — chains, lock rule, stand-downs, notices — unit-tests against a
/// scripted store without scripting every git call underneath. `SharedStore` conforms as-is.
public protocol SharedStoring: Sendable {
    func attach(checkout: String, repo: String, declared: DeclaredSet.Result,
                noteNovel: (@Sendable (String) -> Void)?) async throws -> StoreHandle
    func commitLocal(_ handle: StoreHandle, declared: DeclaredSet.Result, unignoredLeaves: Set<String>) async throws -> CommitOutcome
    func receive(_ handle: StoreHandle, paths: [String], declared: DeclaredSet.Result) async throws -> ReceiveOutcome
    func send(_ handle: StoreHandle, paths: [String], declared: DeclaredSet.Result) async throws -> SendOutcome
    func resolve(_ handle: StoreHandle, paths: [String], declared: DeclaredSet.Result) async throws -> ResolveOutcome
}

extension SharedStore: SharedStoring {}

/// What a sync is for. `.receiveOnly` runs at launch (write the shared files in, send nothing);
/// `.full` runs on the idle edge; `.flush` runs before a worktree is removed.
public enum SyncIntent: Sendable, Equatable { case receiveOnly, full, flush }

public enum SkipReason: Sendable, Equatable {
    /// `PropagationEligibility.decide` said the checkout does not take part (scratch, outside any known
    /// repo, or the primary itself).
    case ineligible
    /// A worktree card whose repo no longer resolves, or a borrowed cwd the resolver refuses.
    case repoUnresolved
    /// The checkout is not a git work tree, so the store shares nothing for it.
    case notARepo
}

public enum StandDownReason: Sendable, Equatable {
    /// The checkout's git dir holds a `MERGE_HEAD`. The daemon never creates one, so a human did.
    case mergeInProgress
    /// `propagation.json` failed to decode. Corrupt must never decay into the permissive default.
    case policyLoadFailed
    /// `git` is older than 2.40, or its version could not be read.
    case gitTooOld
    /// `IgnoreProbe.classify` could not answer, so nothing may be written or shared.
    case probeUnknown(detail: String)
}

public enum SyncOutcome: Sendable, Equatable {
    case skipped(SkipReason)
    /// No `shared` item survived — nothing for the store to do, and no store call was made.
    case nothingShared
    case standDown(StandDownReason)
    /// A live process holds a git lock, or the lock probe could not prove nobody does.
    case busy
    /// `receive` was clean. `send` is nil when the intent was `.receiveOnly` or the card is read-only.
    case completed(receive: ReceiveOutcome, send: SendOutcome?)
    case conflicted(paths: [String], storeSha: String)
    case partial(dirty: [String])
    case refusedOutOfSet(paths: [String])
    /// A `.flush` sync finished, but these files were left out of the commit (over 5 MiB) and so were never
    /// sent. The worktree holds the only copy of the edit: teardown must keep it.
    case unsent(paths: [String])
    case failed(String)
}

public struct ItemStatus: Sendable, Equatable {
    public let name: String
    public let policy: PropagationPolicy
    public let paths: [String]
}

/// The last conflict noticed for a checkout — paths sorted, plus the store sha they conflicted against.
public struct ConflictRecord: Sendable, Equatable {
    public let paths: [String]
    public let storeSha: String
}

public struct PropagationStatus: Sendable, Equatable {
    public let repo: String
    public let items: [ItemStatus]
    /// Leaves the project does not ignore in this checkout, so the store stands them down.
    public let unignoredLeaves: [String]
    public let conflict: ConflictRecord?
    /// `GIT_OPTIONAL_LOCKS=0 git --git-dir=<dir>` for reading the store; nil until the git dir exists.
    public let readCommand: String?
}

public struct StoreLocation: Sendable, Equatable {
    public let storeGitDir: String
    public let checkoutGitDir: String
    public let workTree: String
}

public enum AdoptStop: Sendable, Equatable {
    case primarySyncFailed(SyncOutcome)
    /// A pattern still re-includes these leaves (a `!negation` line), so untracking them would strand them.
    case negationRemains(paths: [String])
    case policyLoadFailed
    case policySaveFailed
    /// `git ls-files` or `git rm --cached` failed in the calling checkout. Nothing was committed.
    case projectGitFailed(String)
    case notParticipating(SyncOutcome)
}

public enum AdoptOutcome: Sendable, Equatable {
    case adopted(untracked: [String])
    case stopped(AdoptStop)
}

public enum PropagationServiceError: Error, Sendable, Equatable {
    /// `resolve` called for a card that is not in a state to resolve — the wrapped outcome says why.
    case notParticipating(SyncOutcome)
    case storeFailed(String)
}
