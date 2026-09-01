import Foundation

/// The single seam mapping a card's parent ref to the concrete git ref its diffs/tree baseline against
/// (goal 1 — parent-relative diffs). Local parents pin `refs/heads/<name>` (defeats tag shadowing,
/// S3-6); remote parents (`<remote>/<b>`, `pr#<N>`) map to their fetched private ref
/// (`refs/orch/parents/…`). O1: every daemon git verb routes through this rule; the canonical string is
/// storage/display only. O4: remote classification consults the repo's configured remotes.
///
/// Returns `nil` (from `resolvedParentRef`) when the card has no parent — every consumer then falls back
/// to the default-branch baseline, keeping nil-parent behavior byte-identical to before branch-tree.
///
/// PR5 actor-hygiene (Task 5.1.4): `gitRemotes`/`resolvableRef`/`resolvedParentRef` touch no actor
/// mutable state — they're `nonisolated` so `offActor` hops (diffText/recomputeDiffStat/listDocuments,
/// computeTreeStat) can call them from a background thread. `gitRemotes` memoizes on the repo's
/// `.git/config` mtime via `gitRemotesCache` (its own lock, not actor isolation) so a mid-run `git
/// remote add` is still observed — no behavior change vs. the un-memoized original.
extension OrchestraService {
    /// The repo's configured git remotes (for remote-parent classification). A cheap local `git remote`,
    /// memoized per-repo until `.git/config`'s mtime changes.
    ///
    /// Task 5 (proc threading): deliberately still on `Proc.run`, NOT the async `ProcRunning` seam.
    /// This helper must stay synchronous — it is called from sync `@Sendable` closures inside `offActor`
    /// hops across out-of-scope files (+Diff/+Notes/+Remote/+Borrow/materialize, and every
    /// `RemoteParentRef.parse(_:remotes:)` consumer), and its memo (`GitRemotesCache.remotes`) takes a
    /// sync compute closure. Making it async would ripple async-ness through those seams and change
    /// their actor-hop shape; convert it together with the diff tier when that tier moves to the seam.
    nonisolated func gitRemotes(repo: String) -> [String] {
        gitRemotesCache.remotes(repo: repo, configMtime: gitConfigMtime(repo: repo)) {
            gitRemotesProbe(repo)
        }
    }

    /// Production probe for `gitRemotesProbe` — the ONE remaining sync `Proc` fork on the service
    /// (the memo's compute closure is sync, so it can't ride the async ProcRunning seam; see the
    /// Task 5 deferral note). Unit tests inject `{ _ in [] }` via TestEnv, so the unit tier's
    /// default path genuinely forks nothing (impl-review M3).
    public static func defaultGitRemotesProbe(_ repo: String) -> [String] {
        guard let r = try? Proc.run(["git", "-C", repo, "remote"]), r.ok else { return [] }
        return r.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The mtime of the repo's REAL `.git/config` — resolving through a linked worktree's `.git` FILE
    /// (`gitdir: <path>`) to the common dir, since a worktree's remotes live in the common config, not
    /// its own per-worktree gitdir. `nil` when `.git` is missing or unreadable (the memo still caches
    /// once but can never invalidate — acceptable only because a real card's `repo` is always the main
    /// repo, where `.git` is a directory; see Task 5.1.4 brief).
    nonisolated func gitConfigMtime(repo: String) -> Date? {
        let dotGit = "\(repo)/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        let configPath: String
        if isDir.boolValue {
            configPath = "\(dotGit)/config"                                   // normal repo
        } else if let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),  // worktree: `gitdir: <path>`
                  let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
            let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            // the worktree's remotes live in the COMMON dir's config (…/.git, parent of worktrees/<name>)
            let commonDir = URL(fileURLWithPath: gitdir).deletingLastPathComponent().deletingLastPathComponent()
            configPath = commonDir.appendingPathComponent("config").path
        } else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate]) as? Date
    }

    /// The resolvable git ref for a lineage link (O1) — the ONE canonical→resolvable rule. Local →
    /// `refs/heads/<b>`; remote → its fetched private ref.
    nonisolated func resolvableRef(_ link: ParentLink, repo: String) -> String {
        resolvableRef(link, remotes: gitRemotes(repo: repo))
    }

    /// Remotes-taking variant for callers that already hoisted `gitRemotes` to a GCD hop —
    /// async-twin bodies (Task.detached → cooperative pool) must not reach the sync fork
    /// (impl-review M1 residual).
    nonisolated func resolvableRef(_ link: ParentLink, remotes: [String]) -> String {
        RemoteParentRef.parse(link.parent, remotes: remotes)?.privateRef
            ?? "refs/heads/\(link.parent)"
    }

    /// The resolvable ref for a Task's `parentBranch` (the diff-consumer forwarder of the same rule).
    nonisolated func resolvedParentRef(_ task: Task) -> String? {
        guard let pb = task.parentBranch, !pb.isEmpty else { return nil }
        return RemoteParentRef.parse(pb, remotes: gitRemotes(repo: task.repo))?.privateRef
            ?? "refs/heads/\(pb)"
    }
}
