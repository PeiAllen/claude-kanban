---
project: claude-kanban
feature: extensibility-roadmap
type: design-index
depth: 2
created: 2026-06-26
updated: 2026-06-29
---

# Orchestra — Extensibility Roadmap

> A map-of-content for the **9 forward-looking extensibility designs** for Orchestra. Each axis is its
> own design-only layered plan (Layer 1 *what* + Layer 2 *interfaces*, no implementation yet) in its
> own folder. Deepen an axis to Layer 3 + tests and implement when it's picked up. Anchored by the
> shipped architecture in [[kanban-board/index|kanban-board]].

> **Status vs `main` (2026-06-29).** Two things moved since the 2026-06-26 design pass:
> 1. **Some substrate shipped.** Four feature PRs landed (read-only inspect, `Task.cwd`/`origin`,
>    freeform/borrowed cards + `access`, scratch cards) — so axis 4's *non-git cards* are now partly
>    real and axis 1's *freeform region* exists as a standalone docked panel. See
>    [[../freeform-and-borrowed-cards/index|freeform-and-borrowed-cards]] and `docs/09-design-decisions.md`.
> 2. **Two cross-cutting decisions were added** and now constrain several axes:
>    - **Enforced 1:1 worktree↔card** ([[../stacked-branches-and-guardian-handoff|stacked-branches & guardian hand-off]]) —
>      retires the shipped refcount/`SharedWorktreeBadge` machinery; adds spawn-`base` + `parentBranch`/
>      `parentCardId`. Touches axes 1, 5, 7.
>    - **One seed, four topologies** ([[../context-passing-topologies|context-passing topologies]]) —
>      `AdapterContext.additionalContext` is the **keystone** (still unbuilt); handoff/fork/fan-out all
>      unlock from it. Elevates axis 3, reshapes axis 6, and folds in a lineage/merge-back model.

## Why these, now

The core (daemon + `OrchestraService` actor + thin clients) is sound. These designs widen the seams
**before they calcify** so each future feature drops into an interface that already anticipated it.
Source: the 2026-06-26 deep code review.

## The 9 axes (planned in dependency/leverage order)

| # | Axis | Folder | L1 | L2 |
|---|------|--------|----|----|
| 1 | Configurable kanban columns | [[configurable-columns/index\|configurable-columns]] | ✅ approved | ✅ approved |
| 2 | Multiple model providers | [[model-providers/index\|model-providers]] | ✅ approved | ✅ approved |
| 3 | Deeper agent integration | [[agent-integration/index\|agent-integration]] | ✅ approved | ✅ approved |
| 4 | Non-git cards + searchability | [[non-git-cards-search/index\|non-git-cards-search]] | ✅ approved | ✅ approved |
| 5 | Automated PR-review phase | [[pr-review-phase/index\|pr-review-phase]] | ✅ approved | ✅ approved |
| 6 | Context-clearing continuity | [[context-continuity/index\|context-continuity]] | ✅ approved | ✅ approved |
| 7 | View/review code on the board | [[code-review-on-board/index\|code-review-on-board]] | ✅ approved | ✅ approved |
| 8 | Outside-source intake | [[external-intake/index\|external-intake]] | ✅ approved | ✅ approved |
| 9 | Phone client | [[phone-client/index\|phone-client]] | ✅ approved | ✅ approved |

<!-- Status values: not started · draft · in-review · approved · skipped -->

## Shared seams (the leverage points every axis routes through)

| Seam | Where | Unlocks |
|------|-------|---------|
| `CommandRegistry` as the *true* single source | `Commands.swift` (CLI is hand-written today; `models`/`archivedList` are server-only) | axes 2, 3, 5, 8 |
| `Adapter` provider abstraction | `Agents/Adapter.swift` (+ Claude-shaped report path to generalize) | axes 2, 3, 6 |
| Columns as **data**, not an enum | `Model.swift` `Column`, `Config` | axes 1, 4, 5 |
| `Transport` abstraction over raw-fd UDS | `Control/*` | axes 8, 9 |
| The `report` two-way hook channel | `OrchestraService+Report.swift`, `claude-hooks.json` | axes 3, 5, 6 |

## Cross-axis dependencies

```mermaid
flowchart TD
    Reg[CommandRegistry single source] --> A2[2 model providers]
    Reg --> A3[3 agent integration]
    Reg --> A8[8 external intake]
    A1[1 configurable columns] --> A5[5 PR-review phase]
    A1 --> A4[4 non-git cards + search]
    A2 --> A3
    A3 --> A6[6 context continuity]
    A3 --> A5
    Trans[Transport abstraction] --> A9[9 phone client]
    Reg --> A9
    A7[7 code review on board]
```

## Status — design-only pass complete (2026-06-26); reconciled to shipped `main` (2026-06-29)

All 9 axes have an **approved L1 (design) + L2 (contract)**. The axes themselves are still design-only —
deepen to **L3 (implementation) + L4 (tests)** when picked up — but note that **feature work landed
underneath them**: the [[../freeform-and-borrowed-cards/index|freeform/borrowed/scratch + read-only]] PRs
(PR1–PR4) shipped the `cwd`/`origin`/`access` schema and the freeform region, which partly realize axis 4
and provide axis 1's freeform lane. The **`additionalContext` seed** (axis 3) is now the elevated keystone
the topology family depends on — build it first.

**Axis 2 is now deepened to an implementable L3.** [[../agent-provider-interface|agent-provider interface]]
(+ [[../agent-provider-research-appendix|research appendix]]) takes model-providers from L2 to an
implementable design and **pins the provider-seam decisions** the other axes depend on: the ~5-method
process-adapter shape, the one normalized-event type, the capability descriptor, discover-by-default
session ids, the model registry, the 3-layer permission model, and the durable-inbox/boundary-injector
steering seam. It also pins the **auth finding — drive-the-binary, never-the-token** (the hard ToS
constraint; ACP is opt-in / API-key-only for Claude, while native CLI + Codex `app-server` both preserve
the subscription). This is the L3 backing the committed CodexAdapter follow-on below.

**Sequencing notes from the gates:**
- **Foundational, do first:** the `CommandRegistry` single-source refactor (in axis 3) — it unblocks axes
  3/5/8. `ControlClient` auto-reconnect (from axis 9) is a near-term standalone fix that also hardens the
  desktop (deepens the shipped B5 fix).
- **Committed follow-on:** build a `CodexAdapter` (axis 2) as the first multi-provider consumer once the
  seam lands.
- **Dependency order:** axis 1 (columns) → enables 4 (freeform lane) + 5 (PR-review column). axis 2 →
  3 → 5/6. axis 4 (freeform) ← used by 8 (no-repo intake). axis 7 feeds 5's review view.

## Cross-layer review & refine pass

With all layers in place, the set is now a queryable model. Per the layered-plan two-pass workflow, a
follow-up **review/refine pass** can propagate any change across the affected axes' docs + diagrams in one
pass. Ask for it when reviewing the set as a whole.

## Open questions (rolled up)

_All per-axis gate questions resolved 2026-06-26 (see each axis's index)._ Remaining items are
build-time confirmations noted in the axis docs (e.g. Codex flag/hook coverage at adapter-build time).
