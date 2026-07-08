import Foundation

/// A remote parent in its canonical, storable form. Two shapes (owner-resolved read-only tier): a pull
/// request (`pr#<N>`, fetched via `refs/pull/N/head` from `origin`) or a remote branch
/// (`<remote>/<name>`, fetched via `refs/heads/<name>` from `<remote>`). The canonical string
/// round-trips through `Task.parentBranch` / `branch.<child>.orchestra-parent`; `privateRef` is the
/// local fetch destination all diff/tree consumers baseline against (never stored — always derived).
///
/// O4: the remote name is no longer hardcoded to `origin` — `parse` consults the repo's configured
/// remotes so an `upstream/feat` parent works, and the parsed remote threads through the fetch/ls-remote
/// argv. A `<remote>/<name>` form is only remote when `<remote>` is a real remote, so a local slashed
/// branch (`feature/foo`) stays local.
public enum RemoteParentRef: Equatable, Sendable {
    case pullRequest(Int)
    case branch(remote: String, name: String)

    /// Classify a base/parent string against the repo's `remotes`. `nil` ⇒ a local branch name (the
    /// caller keeps today's behavior). `pr#<N>` is a PR; `<remote>/<name>` is remote iff `<remote>` is
    /// in `remotes` — otherwise it's a local (possibly slashed) branch name.
    public static func parse(_ ref: String, remotes: [String]) -> RemoteParentRef? {
        if ref.hasPrefix("pr#") {
            let n = ref.dropFirst("pr#".count)
            guard let pr = Int(n), pr > 0 else { return nil }
            return .pullRequest(pr)
        }
        guard let slash = ref.firstIndex(of: "/") else { return nil }
        let remote = String(ref[..<slash])
        let name = String(ref[ref.index(after: slash)...])
        guard !name.isEmpty, remotes.contains(remote) else { return nil }
        return .branch(remote: remote, name: name)
    }

    /// The remote to fetch / ls-remote from. A PR is GitHub-`origin` scoped; a branch carries its remote.
    public var remoteName: String {
        switch self {
        case .pullRequest:            return "origin"
        case .branch(let r, _):       return r
        }
    }

    /// The LHS of the fetch refspec (the ref on the remote we copy down).
    public var remoteSrc: String {
        switch self {
        case .pullRequest(let n):     return "refs/pull/\(n)/head"
        case .branch(_, let name):    return "refs/heads/\(name)"
        }
    }

    /// The short name under `refs/orch/parents/`. Disjoint sub-namespaces (S4) — `pr/<N>` vs
    /// `branch/<remote>/<name>` — so `pr#7` and a branch literally named `pr-7` (and `origin/foo` vs
    /// `upstream/foo`) never collide on one private ref that two watchers would fight over.
    public var privateName: String {
        switch self {
        case .pullRequest(let n):     return "pr/\(n)"
        case .branch(let r, let name): return "branch/\(r)/\(name)"
        }
    }

    /// The local private ref the fetch lands in — the diff/tree baseline for a remote parent.
    public var privateRef: String { "refs/orch/parents/\(privateName)" }

    /// The canonical string stored on the card / in git config.
    public var canonical: String {
        switch self {
        case .pullRequest(let n):     return "pr#\(n)"
        case .branch(let r, let name): return "\(r)/\(name)"
        }
    }
}
