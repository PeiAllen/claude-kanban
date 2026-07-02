import Foundation

/// Resolves a `DiffBase` to the single git rev passed to `git diff <rev>`. Mirrors `Launcher`'s
/// merge-base resolution (origin/HEAD → local `main` → `master`). Any unresolved base falls back to
/// `HEAD`, so a repo with no base branch — or no commits — still diffs its working tree.
enum DiffBaseline {
    /// The git rev for `base`. `.working` → `HEAD`; `.branch` → merge-base with the default branch;
    /// `.parent` → merge-base with the card's parent branch, falling back to `.branch` when
    /// `parentBranch` is nil (the stacked-branches stub).
    static func range(_ base: DiffBase, worktree: String, parentBranch: String?) -> String {
        switch base {
        case .working:
            return "HEAD"
        case .branch:
            return mergeBase(worktree: worktree, ref: defaultBaseRef(worktree: worktree)) ?? "HEAD"
        case .parent:
            if let pb = parentBranch, !pb.isEmpty, let mb = mergeBase(worktree: worktree, ref: pb) {
                return mb
            }
            return range(.branch, worktree: worktree, parentBranch: nil)
        }
    }

    /// The repo's default base branch: origin/HEAD → local `main` → `master`, or nil.
    private static func defaultBaseRef(worktree: String) -> String? {
        if let r = try? Proc.run(["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: worktree),
           r.ok {
            let ref = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ref.isEmpty { return ref }
        }
        for name in ["main", "master"] {
            if let r = try? Proc.run(["git", "rev-parse", "--verify", "--quiet", name], cwd: worktree), r.ok {
                return name
            }
        }
        return nil
    }

    /// `git merge-base HEAD <ref>` — the fork point — or nil.
    private static func mergeBase(worktree: String, ref: String?) -> String? {
        guard let ref, let r = try? Proc.run(["git", "merge-base", "HEAD", ref], cwd: worktree), r.ok
        else { return nil }
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }
}
