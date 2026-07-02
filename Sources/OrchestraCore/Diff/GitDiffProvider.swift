import Foundation

/// Git-backed `DiffProvider`: `git diff --numstat` for the stat, difft-or-git for the ANSI render. Both
/// key off the same `git diff <range>` so the footer stat and the inspector render never disagree
/// (untracked-uncommitted files show in neither until staged/committed). All calls are read-only; a git
/// failure (not a repo / git missing) degrades to `nil`/`""`.
public struct GitDiffProvider: DiffProvider {
    public init() {}

    public func stat(worktree: String, base: DiffBase, parentBranch: String?) throws -> DiffStat? {
        let range = DiffBaseline.range(base, worktree: worktree, parentBranch: parentBranch)
        guard let r = try? Proc.run(["git", "diff", "--numstat", range], cwd: worktree), r.ok else {
            return nil   // not a repo / git failed → degrade (never fabricate)
        }
        var files = 0, insertions = 0, deletions = 0
        for line in r.stdout.split(separator: "\n") {
            // "<added>\t<deleted>\t<path>"; a binary file is "-\t-\t<path>".
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count == 3 else { continue }
            files += 1
            insertions += Int(cols[0]) ?? 0
            deletions += Int(cols[1]) ?? 0
        }
        return files > 0 ? DiffStat(filesChanged: files, insertions: insertions, deletions: deletions) : nil
    }

    public func render(worktree: String, base: DiffBase, parentBranch: String?) throws -> String {
        let range = DiffBaseline.range(base, worktree: worktree, parentBranch: parentBranch)
        // difftastic (structural, syntax-aware) when on PATH — inline mode fits a narrow inspector pane;
        // DFT_COLOR=always forces ANSI under a non-TTY.
        if Proc.toolExists("difft") {
            let env = ["GIT_EXTERNAL_DIFF": "difft", "DFT_DISPLAY": "inline", "DFT_COLOR": "always"]
            if let r = try? Proc.run(["git", "diff", range], cwd: worktree, env: env), r.ok {
                return r.stdout
            }
        }
        // git's own colored diff (difft absent / failed).
        guard let r = try? Proc.run(["git", "-c", "color.ui=always", "diff", range], cwd: worktree), r.ok else {
            return ""
        }
        return r.stdout
    }
}
