import Foundation

/// The single seam mapping a card's parent ref to the concrete git ref its diffs/tree baseline against
/// (goal 1 — parent-relative diffs). Local parents pin `refs/heads/<name>` (defeats tag shadowing,
/// S3-6); remote parents (`<remote>/<b>`, `pr#<N>`) map to their fetched private ref
/// (`refs/orch/parents/…`). O1: every daemon git verb routes through this rule; the canonical string is
/// storage/display only. O4: remote classification consults the repo's configured remotes.
///
/// Returns `nil` (from `resolvedParentRef`) when the card has no parent — every consumer then falls back
/// to the default-branch baseline, keeping nil-parent behavior byte-identical to before branch-tree.
extension OrchestraService {
    /// The repo's configured git remotes (for remote-parent classification). A cheap local `git remote`.
    /// `nonisolated` (pure git, no actor state) so the hot-path `TreeStat` recompute can run it off-actor.
    nonisolated func gitRemotes(repo: String) -> [String] {
        guard let r = try? Proc.run(["git", "-C", repo, "remote"]), r.ok else { return [] }
        return r.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The resolvable git ref for a lineage link (O1) — the ONE canonical→resolvable rule. Local →
    /// `refs/heads/<b>`; remote → its fetched private ref. `nonisolated` (pure git) so the off-actor
    /// `computeTreeStat` can call it.
    nonisolated func resolvableRef(_ link: ParentLink, repo: String) -> String {
        RemoteParentRef.parse(link.parent, remotes: gitRemotes(repo: repo))?.privateRef
            ?? "refs/heads/\(link.parent)"
    }

    /// The resolvable ref for a Task's `parentBranch` (the diff-consumer forwarder of the same rule).
    func resolvedParentRef(_ task: Task) -> String? {
        guard let pb = task.parentBranch, !pb.isEmpty else { return nil }
        return RemoteParentRef.parse(pb, remotes: gitRemotes(repo: task.repo))?.privateRef
            ?? "refs/heads/\(pb)"
    }
}
