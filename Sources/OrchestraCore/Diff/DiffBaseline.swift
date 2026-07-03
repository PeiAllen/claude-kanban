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

    /// The repo's default base branch, resolved to a **local** ref whenever possible.
    ///
    /// We learn the default branch's *name* from `origin/HEAD` (e.g. `origin/main` → `main`) but then
    /// prefer the LOCAL branch of that name over the remote-tracking ref. This matters because Orchestra
    /// cuts worktrees from **local** `main`, which is routinely ahead of a stale `origin/main`. Basing the
    /// diff on `origin/main` would fork every card at the last-pushed commit, so every card's `.branch`
    /// diff would include local main's own unpushed commits — identical, non-zero noise on every card.
    /// Falls back to the remote-tracking ref (no local branch of that name), then local `main`/`master`.
    static func defaultBaseRef(worktree: String) -> String? {
        if let r = try? Proc.run(["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: worktree),
           r.ok {
            let remoteRef = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)   // e.g. "origin/main"
            if !remoteRef.isEmpty {
                let localName = remoteRef.hasPrefix("origin/")
                    ? String(remoteRef.dropFirst("origin/".count)) : remoteRef
                if !localName.isEmpty,
                   let lr = try? Proc.run(["git", "rev-parse", "--verify", "--quiet", localName], cwd: worktree),
                   lr.ok {
                    return localName   // local branch of the default name — current with local work
                }
                return remoteRef       // no local branch of that name → the remote-tracking ref
            }
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
