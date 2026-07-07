import Foundation

/// A remote parent in its canonical, storable form. Two shapes only (owner-resolved read-only tier):
/// a pull request (`pr#<N>`, fetched via `refs/pull/N/head`) or a same-repo remote branch
/// (`origin/<name>`, fetched via `refs/heads/<name>`). The canonical string round-trips through
/// `Task.parentBranch` / `branch.<child>.orchestra-parent`; `privateRef` is the local fetch
/// destination all diff consumers baseline against (never stored — always derived).
public enum RemoteParentRef: Equatable, Sendable {
    case pullRequest(Int)
    case branch(String)

    /// Classify a base/parent string. `nil` ⇒ a local branch name (caller keeps today's behavior).
    public static func parse(_ ref: String) -> RemoteParentRef? {
        if ref.hasPrefix("pr#") {
            let n = ref.dropFirst("pr#".count)
            guard let pr = Int(n), pr > 0 else { return nil }
            return .pullRequest(pr)
        }
        if ref.hasPrefix("origin/") {
            let b = String(ref.dropFirst("origin/".count))
            return b.isEmpty ? nil : .branch(b)
        }
        return nil
    }

    /// The LHS of the fetch refspec (the ref on `origin` we copy down).
    public var remoteSrc: String {
        switch self {
        case .pullRequest(let n): return "refs/pull/\(n)/head"
        case .branch(let b):      return "refs/heads/\(b)"
        }
    }

    /// The short name under `refs/orch/parents/` (`pr-N` keeps PRs from colliding with a branch).
    public var privateName: String {
        switch self {
        case .pullRequest(let n): return "pr-\(n)"
        case .branch(let b):      return b
        }
    }

    /// The local private ref the fetch lands in — the diff/tree baseline for a remote parent.
    public var privateRef: String { "refs/orch/parents/\(privateName)" }

    /// The canonical string stored on the card / in git config.
    public var canonical: String {
        switch self {
        case .pullRequest(let n): return "pr#\(n)"
        case .branch(let b):      return "origin/\(b)"
        }
    }
}
