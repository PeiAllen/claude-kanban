---
project: claude-kanban
feature: non-git-cards-search
type: design-index
depth: 2
created: 2026-06-26
updated: 2026-06-26
---

# Non-git Cards + Searchability — Design Index

> Two linked needs: (a) **search/discover/debug** agents (text query over cards, server-side `find`, the
> existing `sessions` debug handles), and (b) **non-git cards** — agents not tied to a git worktree, shown
> in their own area. Part of the [[extensibility-roadmap/index|extensibility roadmap]] (axis 4). Leans on
> [[../configurable-columns/index|configurable-columns]] (a lane is a column/section).

## Layers

| Layer | Document | Status |
|-------|----------|--------|
| 1 — Initial design | [[01-design]] | approved |
| 2 — Contract | [[02-contract]] | approved |
| 3 — Implementation | [[03-implementation]] | not started (design-only pass) |
| 3 — Tests | [[04-tests]] | not started (design-only pass) |

> Design-only pass: L1+L2 approved 2026-06-26. CardKind git/freeform; freeform lane via axis 1;
> search live+archived.

## Current picture

```mermaid
flowchart TD
    Task[Task.kind: gitWorktree | freeform] --> Board[Board: git cards]
    Task --> Area[Separate area: freeform cards]
    Q[list query / find verb] --> Results[matched cards incl. archived]
    Sess[sessions debug handles] --> Debug[jump in / tail / resume]
```

## Open questions (rolled up)

_Resolved at the 2026-06-26 gate:_ scratch-by-default cwd (+ chosen allowlisted dir) · freeform area =
axis-1 lane keyed off `CardKind` · search covers live + archived (+ notes/progress with axis 3).
