import Foundation
import OrchestraKit

/// Does this checkout take part in propagation.
public enum Eligibility: Sendable, Equatable {
    case participates
    case skipped
}

/// Which known repo (if any) a checkout's cwd resolves into — already determined by the caller via
/// I/O (`rev-parse --show-toplevel` for a borrowed card). An enum rather than a bare `String?`: a
/// bare optional lets a future caller pass a plausible non-nil default and silently defeat the
/// "never write into an arbitrary directory" guard; `.outsideAnyRepo` has to be named on purpose.
public enum RepoContainment: Sendable, Equatable {
    case insideRepo(root: String)
    case outsideAnyRepo
}

/// A pure switch over a card's origin and its (already-resolved) repo relationship to the primary.
/// No I/O, no proc.
public enum PropagationEligibility {
    /// - Parameters:
    ///   - origin: the card's origin. Only this — never `Task.repo` — decides which of the cases
    ///     below applies. See the note below on why.
    ///   - checkoutRepo: which known repo (if any) contains the checkout's cwd, already resolved by
    ///     the caller. Only consulted for a `.borrowed` origin.
    ///   - primaryRoot: the repo's primary checkout root, already canonicalized by the caller.
    ///
    /// `.participates` for a worktree card, and for a borrowed card inside a known repo that is not
    /// the primary checkout itself. `.skipped` for scratch, for a directory outside any known repo,
    /// and for the primary checkout itself — never sync onto self.
    ///
    /// **Wider than the design doc's `decide(card:primaryRoot:)`.** `Task.repo` is raw, unvalidated
    /// `SpawnInput.repo` passthrough for a `.borrowed` card (`OrchestraService.swift:450-460`): it
    /// can be empty, and even non-empty carries no proven relationship to `cwd`, so it cannot answer
    /// "is cwd inside a known repo". The design's own `sync` step 1 already resolves that question
    /// impurely — via `rev-parse --show-toplevel` for a borrowed card — before calling this
    /// function; `checkoutRepo` names exactly what step 1 already has in hand. Taking `origin`
    /// directly (not the whole `Task`) makes that independence explicit: nothing here can reach for
    /// `card.repo` or `card.cwd` by accident. `checkoutRepo` and `primaryRoot` must already be
    /// canonicalized: `PathResolver.canonical` runs `realpath`, which is I/O and so can't happen
    /// inside a pure function.
    public static func decide(origin: CardOrigin, checkoutRepo: RepoContainment, primaryRoot: String) -> Eligibility {
        switch origin {
        case .worktree:
            return .participates
        case .scratch:
            return .skipped
        case .borrowed:
            switch checkoutRepo {
            case .outsideAnyRepo:
                return .skipped
            case .insideRepo(let root):
                return root == primaryRoot ? .skipped : .participates
            }
        }
    }
}
