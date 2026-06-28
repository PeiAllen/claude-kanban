---
project: claude-kanban
feature: context-continuity
type: design-index
depth: 2
created: 2026-06-26
updated: 2026-06-26
---

# Context-clearing Continuity — Design Index

> When an agent's context fills, don't lose the thread: the agent **saves a handoff**, and Orchestra
> **launches a fresh agent seeded with it** — either continuing the same card or spinning a new task.
> Part of the [[extensibility-roadmap/index|extensibility roadmap]] (axis 6). Builds on
> [[../agent-integration/index|agent-integration]] (`additionalContext` injection) + the shipped
> ctxPct / `restart` machinery.

## Layers

| Layer | Document | Status |
|-------|----------|--------|
| 1 — Initial design | [[01-design]] | approved |
| 2 — Contract | [[02-contract]] | approved |
| 3 — Implementation | [[03-implementation]] | not started (design-only pass) |
| 3 — Tests | [[04-tests]] | not started (design-only pass) |

> Design-only pass: L1+L2 approved 2026-06-26. Agent-authored handoff only; `handoff`/`continue` over
> CLI+MCP; auto ctxPct trigger default off; default mode continue-same-card.

## Current picture

```mermaid
flowchart TD
    Ctx[ctxPct high OR manual] --> Ask[Orchestra asks agent for a handoff]
    Ask --> Save[handoff verb -> Task.handoff]
    Save --> Choose{continue or new task?}
    Choose -->|continue| Restart[restart withContext=handoff - same card]
    Choose -->|new task| Spawn[spawn withContext=handoff - new linked card]
    Restart --> Fresh[fresh agent resumes with context]
    Spawn --> Fresh
```

## Open questions (rolled up)

_Resolved at the 2026-06-26 gate:_ ship both triggers (auto default off) + `handoff`/`continue` over
CLI + MCP · agent-authored handoff only · default mode continue-same-card.
