---
project: claude-kanban
feature: parent-card-branch-linking
type: design-index
depth: 3 (design + plan only — no implementation on this card)
created: 2026-07-06
updated: 2026-07-06
related:
  - "[[../stacked-branches-and-guardian-handoff|stacked-branches-and-guardian-handoff]]"
  - "[[../context-passing-topologies|context-passing-topologies]]"
  - "[[../code-review-on-board/index|code-review-on-board (axis 7)]]"
  - "[[../pr-review-phase/index|pr-review-phase (axis 5)]]"
---

# Parent Card / Branch Linking — Design Index

> **Branch trees** for Orchestra: a card's branch based on another branch (card-optional parent),
> parent-relative diffs, spawn-on-branch across UI/MCP/CLI, parent→child sync, merge redirection,
> ship-into-parent, child-informs-parent, and remote PR-branch parents.
> Finalizes [[../stacked-branches-and-guardian-handoff|stacked-branches-and-guardian-handoff]] §2
> — renamed: the topology is a **tree** (parent/child cards), not a linear stack; "stacked PRs"
> survives only as GitHub's name for the remote publishing workflow.

## Resolved framing (2026-07-06, with owner)

- **Card-optional parent (option A):** the parent is a **branch ref**; "the parent card" is a
  live lookup (active card whose `repo`+`branch` match — unique under the 1:1 invariant), never
  a stored pointer. Degrades to pure-git behavior when no card owns the branch.
- **Lineage survives card churn:** the parent link is persisted **on the branch** in repo git
  config (`branch.<child>.orchestra-parent`), git-town/Graphite style; `Task.parentBranch` is a
  cache derived at spawn, not the source of truth.
- **Merges are Orchestra acts, not observed events** (local story): ship-into-parent notifies
  the parent's owning card via the F3 inbox and retargets grandchildren. Remote PR parents
  (goal 8) are the one place needing observation — scoped as opt-in `gh`-based checks.

## Layers

| Layer | Document | Status |
|-------|----------|--------|
| 1 — Initial design | [[01-design]] | **approved** (2026-07-06 gate) |
| 2 — Contract | [[02-contract]] | draft |
| 3 — Implementation | [[03-implementation]] | not started |
| 3 — Tests | [[04-tests]] | not started |

<!-- Status values: not started · draft · in-review · approved · skipped -->

## Current picture

```mermaid
flowchart TD
    Spawn[spawn --on branch / UI / MCP / CLI] --> Child[child card + worktree]
    Child -->|branch.child.orchestra-parent| Parent[(parent branch ref)]
    Parent -.->|derived lookup| PCard[parent card, if any]
    Child -->|diff vs merge-base parent| Diff[parent-relative diff + footer stat]
    Child -->|ship| Merge[merge into parent, not main]
    Merge -->|F3 inbox| PCard
    Merge -->|retarget| GChild[grandchildren repointed]
    Remote[(remote PR branch)] -.->|goal 8: gh-based watch| Parent
```

## Investigation verdicts (2026-07-06)

- **Topology: tree, single parent** — unanimous prior art; true DAG needs jj-class machinery git lacks.
- **Sync: merge-down routine + `rebase --onto` only at re-parent + squash at ship** — safest for
  concurrent agents; requires persisting the parent **base OID** (Graphite's `parentBranchRevision` lesson).
- **Remote parents:** fetch into `refs/orch/parents/…` (fork-safe, read-only); merge-detection ladder
  `gh pr view` → branch-deleted heuristic → ancestry (proof-positive only); never trust GitHub auto-retarget.

## Open questions (rolled up)

All L1 questions resolved at the 2026-07-06 gate (see [[01-design]] §Open questions): footer stat
parent-relative only · stale badge + inbox nudge default (auto-sync per-card opt-in) · squash at
ship-into-parent · remote v1 read-only tier · tree publishing hidden-by-default (root PR or full
stacked PRs) · renamed to **branch tree**.
