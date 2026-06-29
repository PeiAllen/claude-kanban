---
project: claude-kanban
feature: code-review-on-board
type: design-index
depth: 2
created: 2026-06-26
updated: 2026-06-29
---

# View/Review Code on the Board — Design Index

> See an agent's changes **in Orchestra** — a diffstat on the card and a structured diff view in the
> inspector — instead of only "View changes" → Zed. Part of the
> [[extensibility-roadmap/index|extensibility roadmap]] (axis 7). Feeds [[../pr-review-phase/index|axis 5]]
> (the PR-review view).

## Status vs `main` (2026-06-29)

> **Unbuilt** (design-only), but two facts now shift the baseline. **(1) Shipped foundation:** PR2 replaced
> `Task.worktree` with **`Task.cwd` + `Task.origin: CardOrigin {worktree, scratch, borrowed}`**, and PR3/PR4
> shipped **freeform/borrowed/scratch** cards — so the non-git guard keys on **`origin`** (a `.scratch` or
> `.borrowed` card may point at a dir with **no git baseline**, i.e. `cwd != .worktree`), not a `kind` field.
> The diff view must degrade gracefully for these. **(2) Parent-relative baseline:** for **stacked branches**
> the reviewable diff is **relative to the parent branch, not `main`**
> ([[../stacked-branches-and-guardian-handoff|stacked-branches-and-guardian-handoff]] §2). That makes a
> **`parentBranch`/`parentCardId`** card field (new, **unbuilt**) the baseline input for `DiffProvider` — a
> third `DiffBase` alongside working/branch.

## Layers

| Layer | Document | Status |
|-------|----------|--------|
| 1 — Initial design | [[01-design]] | approved |
| 2 — Contract | [[02-contract]] | approved |
| 3 — Implementation | [[03-implementation]] | not started (design-only pass) |
| 3 — Tests | [[04-tests]] | not started (design-only pass) |

> Design-only pass: L1+L2 approved 2026-06-26. Generic DiffProvider (difftastic default, git fallback +
> structured payload); default branch baseline; event-driven refresh; read-only.

## Current picture

```mermaid
flowchart TD
    WT[(worktree)] --> DP[DiffProvider: difftastic default / git fallback]
    DP --> Insp[Inspector: diff view - difftastic display]
    DP --> Struct[git structured FileDiff -> diff verb]
    Struct --> Agent[agent/PR-review reads diff]
    Ev[commit/push/edit/pull events + selection] --> Stat[git --numstat]
    Stat --> Card[card footer: files +/-]
```

## Open questions (rolled up)

_Resolved at the 2026-06-26 gate:_ generic `DiffProvider` with **difftastic default** + git fallback (git
for the structured payload) · default baseline **branch (else working)** · refresh **event-driven** + on
selection · read-only (inline comments → axis 5).

_Opened by the 2026-06-29 synthesis:_ a **parent-relative** baseline for stacked branches — diff vs the
parent branch via a new `parentBranch`/`parentCardId` field, not vs `main`
([[../stacked-branches-and-guardian-handoff|stacked-branches-and-guardian-handoff]] §2) · the non-git guard
keys on shipped **`Task.origin`** (`.scratch`/`.borrowed` cards may have no git baseline).
