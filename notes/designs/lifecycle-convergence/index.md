---
project: claude-kanban (Orchestra)
feature: lifecycle-convergence
type: design-index
depth: 3 (full — L1 design, L2 contract, L3 implementation + tests, + PR tree)
created: 2026-07-09
updated: 2026-07-09
---

# Card Lifecycle Convergence — Design Index

> Replace Orchestra's edge-triggered, multi-variable card lifecycle with one persisted `phase` driven
> through a single validated funnel, per-launch epochs, and an idempotent phase-keyed reconciler —
> killing 15 confirmed lifecycle bugs plus the adversarial-review round's findings, agent-agnostically.

**Sources of truth this vault deepens:** the finalized spec [[../2026-07-08-card-lifecycle-convergence|spec]]
and plan `notes/plans/2026-07-08-card-lifecycle-convergence.md` (both re-grounded on `main` @ `f1aa568`,
2026-07-09, after a 3-adversary review round). Gate mode: **agentic** (Opus 4.8 + GPT 5.5 reviewers loop
until no complaints; no human gates — Allen's standing instruction).

## Layers

| Layer | Document | Status |
|-------|----------|--------|
| 1 — Initial design | [[01-design]] | draft |
| 2 — Contract | [[02-contract]] | not started |
| 3 — Implementation | [[03-implementation]] | not started |
| 3 — Tests | [[04-tests]] | not started |
| 3 — PR tree (execution order) | [[05-pr-tree]] | not started |

<!-- Status values: not started · draft · in-review · approved · skipped -->

## Current picture

```mermaid
stateDiagram-v2
  [*] --> creatingWorktree: spawn (all card kinds)
  creatingWorktree --> launching: cwd materialized
  creatingWorktree --> dead: materialize failed
  launching --> live: Ready signal / N=3 liveness ticks
  launching --> dead: launch failed / timeout
  live --> live: status hook
  live --> relaunching: resume / restart / handoff
  live --> dead: exited / vanished / completed
  relaunching --> relaunching: supersede (epoch++)
  relaunching --> live: relaunch confirmed
  relaunching --> dead: relaunch failed
  dead --> relaunching: restart
  dead --> live: REVIVAL (epoch-current signal only)
  dead --> archived: archive
  live --> archived: archive
  creatingWorktree --> archived: archive (supersedes)
  launching --> archived: archive (supersedes)
  relaunching --> archived: archive (supersedes)
  archived --> archived: teardown pending -> complete
  archived --> creatingWorktree: reopen
```

## Open questions (rolled up)

- (none yet)
