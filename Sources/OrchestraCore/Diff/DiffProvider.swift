import Foundation

/// Computes a card's worktree diff for the board footer + inspector. **Read-only.** Two jobs, both from
/// git: a cheap `DiffStat` (`git diff --numstat`) and a rendered ANSI patch string. There is **no
/// structured payload** — an agent reads a diff by running `git diff` in its own cwd, so re-serving it
/// would be dead weight. A git failure (not a repo / git missing) degrades to `nil`/`""` — never
/// fabricated. See `docs/09-design-decisions.md` (§ code review on the board — axis 7).
public protocol DiffProvider: Sendable {
    func stat(worktree: String, base: DiffBase, parentBranch: String?) throws -> DiffStat?
    func render(worktree: String, base: DiffBase, parentBranch: String?) throws -> String
}
