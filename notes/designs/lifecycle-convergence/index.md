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
| 1 — Initial design | [[01-design]] | approved (agentic gate: Opus 4.8 + GPT 5.5 clean, 2026-07-09) |
| 2 — Contract | [[02-contract]] | approved (agentic gate: Opus 4.8 + GPT 5.5 clean, 2026-07-09) |
| 3 — Implementation | [[03-implementation]] | approved (agentic gate: Opus 4.8 + GPT 5.5 clean, 2026-07-09) |
| 3 — Tests | [[04-tests]] | approved (same combined gate) |
| 3 — PR tree (execution order) | [[05-pr-tree]] | approved (same combined gate) |

<!-- Status values: not started · draft · in-review · approved · skipped -->

## Current picture (Layer 2 — modules; the L1 phase machine lives in [[01-design]])

```mermaid
flowchart TD
  subgraph kit [OrchestraKit — compile-time shared]
    MODEL[Phase · RunState · DeadReason · Conclusion]
    CAT[CommandCatalog<br/>kind + phaseGate per verb]
    DS[displayState<br/>label + validActions + isBusy + staleSince]
  end
  subgraph daemon [orchestrad / OrchestraCore]
    CS[ControlServer<br/>+ registry dispatch = phaseGate chokepoint]
    SVC[OrchestraService actor — verbs]
    FUN[transition funnel + isLegalEdge<br/>sole writer of phase]
    STORE[TaskStore<br/>rev + field-delta patches]
    REC[Reconciler — 2s tick + boot]
    STEP[PhaseSteppers ×4<br/>Materialize · Launch · Relaunch · Teardown]
    REG[WorktreeRegistry actor<br/>wraps WorktreeManager]
    SESS[SessionManager — tmux]
    ADAPT[Adapters: claude-code · codex]
  end
  FILES[(tasks.json + rev<br/>watch registry · borrows · inbox)]
  CLIENTS[3 clients] --> CS --> SVC --> FUN --> STORE --> FILES
  CS -.enforces.-> CAT
  DS -.derives from.-> CAT
  REC --> STEP
  STEP --> FUN
  STEP --> REG & SESS & ADAPT
  REG --> FILES
```

## Open questions (rolled up)

- (none yet)
