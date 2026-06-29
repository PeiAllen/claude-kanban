---
project: claude-kanban
feature: non-git-cards-search
type: design-index
depth: 2
created: 2026-06-26
updated: 2026-06-29
---

# Non-git Cards + Searchability — Design Index

> Two linked needs: (a) **search/discover/debug** agents (text query over cards, server-side `find`, the
> existing `sessions` debug handles), and (b) **non-git cards** — agents not tied to a git worktree, shown
> in their own area. Part of the [[extensibility-roadmap/index|extensibility roadmap]] (axis 4).

## Status vs `main` (2026-06-29)

- **The "non-git cards" half SHIPPED — under a richer schema than this doc proposed.** Freeform/borrowed/
  scratch cards are real board citizens now; see [[../freeform-and-borrowed-cards/index|freeform-and-borrowed-cards]].
  The model change landed as **`Task.cwd: String` + `Task.origin: CardOrigin { worktree, scratch, borrowed }`
  + `Task.access: CardAccess`** (the `Task.worktree` string was removed), **not** the 2-way
  `Task.kind: CardKind { gitWorktree, freeform }` sketched here. `SpawnInput` gained `cwd`, `scratch`,
  and `access`; spawn branches on `origin`, and `archive` guards git cleanup on it. Read this axis's L1/L2
  `CardKind`/`kind` as the *shipped* `origin` enum.
- **The freeform area shipped STANDALONE — not an axis-1 lane.** Non-`.worktree` cards live in a dedicated
  `FreeformRegionView`, deliberately **independent** of [[../configurable-columns/index|configurable-columns]]
  (freeform is a card *category*, not a workflow stage). The "freeform area = an axis-1 lane keyed off
  `CardKind`" decision is retired.
- **The SEARCH half is what remains unbuilt.** `find`/`list?query`/`TaskSearch` and the app search field
  do **not** exist yet — that is the live scope of this axis. The [[../agent-integration/index|axis 3]]
  `link` verb + the shipped `cwd`/`origin` schema are the substrate search builds on (e.g. searching
  notes/progress, relating non-git cards).

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
