---
project: claude-kanban
feature: context-passing-topologies
type: design-note
created: 2026-06-29
updated: 2026-06-29
related:
  - "[[stacked-branches-and-guardian-handoff|stacked-branches-and-guardian-handoff]]"
  - "[[context-continuity/index|context-continuity (axis 6)]]"
  - "[[agent-integration/index|agent-integration (axis 3)]]"
  - "[[configurable-columns/index|configurable-columns (axis 1)]]"
  - "[[freeform-and-borrowed-cards/index|freeform-and-borrowed-cards]]"
---

# Context-Passing Topologies — Handoff / Fork / Fan-out on One Seed

> Handoff, fork, fan-out, and (Claude-side) subagents are **one primitive — "start/restart an agent
> with an authored context seed" — at four topologies.** Build the seed once and the rest is wiring.
> This note unifies the patterns, names the single keystone gap, and specifies the safe lifecycle
> model. The 1:1-worktree decision and the fork×handoff interaction detail live in
> [[stacked-branches-and-guardian-handoff|the stacked-branches note]]; this is the umbrella.

## 1. The keystone: an `additionalContext` seed (the one missing field)

`restart` (`OrchestraService+Recovery.swift:100–135`) **already is** continue-same-card handoff —
almost. It mints a fresh `agentSessionId` (old → `priorSessionIds`), **keeps `cwd` + the worktree**,
sets `status → .waiting`, clears `desc`, and relaunches in the same tmux. The *only* missing step is
**seeding the fresh session**: it passes `prompt: nil`, and there is **no context-seed field anywhere**
— `AdapterContext` (`Adapter.swift:4–23`) carries `cwd/repo/model/startIn/sessionId/prompt/name/
hooksPath/access/trustCwd` but **no context-seed field**; `SpawnInput` (`Model.swift:484–520`) has no
seed/parent field either.

So the entire family reduces to **one field**:

```
AdapterContext.additionalContext: String?     // authored seed: handoff / fork-brief / plan-slice
SpawnInput.additionalContext:     String?     // same, at spawn
restart(_:withContext:)                        // pass the seed into the fresh session
```

delivered to the CLI as a seeded first message (or `--append-system-prompt`). This is already
specced — agent-integration axis 3 lists *"additionalContext on re/start → Agent."* Build it first;
**handoff, fork, and fan-out-with-context all unlock from it**, and it *also* carries merge-back
safely (§5).

> `restart` **clears `desc`** — so `desc` is not a durable carrier across a reset. Durable facts must
> live in committed code / plan files (the artifacts); the seed carries only intent + next-steps.

## 2. The four topologies

| Pattern | Topology | Interactive? | Past kept? | New card? | Mechanism |
|---|---|---|---|---|---|
| **Handoff** | 1→1 succession | n/a | dropped | optional | `restart + seed` (continue) · `spawn(inherit) + seed + archive(removeWorktree:false)` (transfer) |
| **Fork** | 1→1 + rejoin | **yes** | parent kept | yes (linked) | `spawn linked + seed`, parent live, merge-back via inbox |
| **Subagent** | 1→1 + rejoin | no | parent kept | **no** (in-process) | Claude Agent/Task tool — Orchestra-invisible |
| **Fan-out** | 1→**N** | no | plan card kept/retired | yes (N children) | `batch-spawn` + per-slice seed + `parentCardId` |

**Decision rule:** *return to the thread?* → fork (interactive) or subagent (non-interactive). *replace
the thread?* → handoff. *split into many?* → fan-out. *need a steerable, board-visible, persistent
unit?* → card (fork/handoff/fan-out). *throwaway helper that returns a summary?* → subagent.

## 3. Handoff — molt in place, or pass the baton

- **Continue-same-card (default for "agent going long"):** `restart(X) + seed`. Same card id, same
  worktree, fresh session+context. **No ownership transfer — the card never changes**, only its
  session molts. ~95% built; needs only the seed. Right for guardian-running-long, impl-running-long,
  plan→impl context reset.
- **New-card transfer (only for a distinct card identity — role change / clean board history):**
  `spawn` Y inheriting `{repo, branch, cwd, origin:.worktree, model, column}`, seed Y, then
  `archive(X, removeWorktree: false)` (`OrchestraService.swift:194` — the param exists). Keeps the
  **entire working tree** (tracked + untracked + ignored — build state survives), unlike a re-checkout
  respawn. Strictly 1:1; no refcount needed (the caller knows ownership moved).

## 4. Fork — branch and rejoin

Spawn a **linked child** (`parentCardId = X`, seeded with X's brief), **parent stays live**, conclude
with a merge-back. Two cwd flavors, both already expressible via PR3 origins:
- **Needs the files (read):** `origin = .borrowed`, `access = .readOnly`, `cwd = X.cwd` (or the PR1
  inspect shell for a no-card peek). Parent keeps editing; fork reads + discusses.
- **Pure discussion (no files):** `.scratch` / cwd-light card seeded with context only.

New structural needs: **`Task.parentCardId`** (absent today — `origin` is directory-kind, not a card
ref) and the **merge-back inbox** (§5). Decision rule vs handoff: *fork when you'll return to the
parent; handoff when the parent is being replaced.*

## 5. Merge-back & safe lifecycle (the load-bearing safety model)

Naïve merge-back via `send` is unsafe: `send → sendKeys` **throws if the session isn't alive**
(`SessionManager.swift:150`), and every handoff kills the parent's tmux (transfer kills the whole
card). So **merge-back targets the card *lineage*, not a live session**, riding the §1 seed channel:

1. **Durable, persisted inbox** `Task.pendingContext: [String]` → injected as `additionalContext` on
   the card's next live turn ("a fork you launched concluded: …"). Persisted, because daemon restart
   is itself a death cause.
2. **Lineage pointer** `Task.succeededBy` set on transfer-handoff; merge-back to X reroutes to Z.
3. **Forks-in-flight = inherited state** (reverse-lookup of live `parentCardId` children): the
   continue-handoff seed warns the fresh agent to expect outstanding conclusions; transfer inherits them.
4. **Guards:** `assertActive` (reject archived) on restart/handoff/transfer; serialize per-card
   restart/handoff on the `recovering` lock.

**Lineage death is not always intentional** — design for all three: **(A)** user archive (warn; live
forks **promoted to standalone cards**, never killed), **(B)** agent self-archival (harden into a guard
that refuses while live children exist), **(C)** involuntary (`sessionVanished`, `rebootUnrevived`,
ctx-overflow — unpreventable, must be tolerated: persisted inbox + terminal surfacing as an activity
item + orphan-promotion). Full matrix in [[stacked-branches-and-guardian-handoff|the stacked-branches
note §7]].

## 6. Subagents — Orchestra needs nothing to enable

Subagents (Claude Agent/Task tool) run **inside** a card's one `claude` process — Orchestra sees one
session/tmux/`cwd`, and their tool-use is part of the parent's transcript (no hook misattribution).
Cranking them up is a pure Claude-side skill/config lever; it works transparently and, by keeping the
*main* context lean, **lowers `ctxPct` growth** — composing with handoff (subagents *prevent* bloat;
handoff *recovers* from it). The only Orchestra-side angle is **observability**, already designed as
agent-integration axis 3's in-card `progress`/`note` sub-status tree (which explicitly lists
subagents). Optional: have the skill emit those reports so the tree populates.

## 7. Column transitions are a consumer, not a new mechanism

- **Within the worktree category (plan ↔ impl ↔ review):** `move` is a pure data update
  (`TaskStore.swift:93`, no `onEnter` hook). A context reset at a boundary is **opt-in**: manual
  `restart + seed`, or an `onEnter` policy once [[configurable-columns/index|configurable-columns]]
  lands. Card + worktree untouched by the move.
- **Across categories (freeform → workflow):** `origin` is per-card and immutable; this is **not a
  move** but a **promotion = spawn a new `.worktree` card seeded from the freeform card** (+ optional
  `git diff` patch if it was a checkout). *Category change = new card; only intra-category stage
  changes are moves.*
- **plan → many PRs:** **fan-out** (`batch-spawn` + per-slice seed + `parentCardId`), plan card as
  epic/parent.

## 8. Build order

1. **`additionalContext` seed** (axis 3) — the keystone; unblocks everything below + carries merge-back.
2. **Handoff:** `restart + seed` (continue) · `spawn(inherit) + seed + archive(removeWorktree:false)`
   (transfer). Retire the refcount/badge per the 1:1 decision.
3. **`parentCardId` + merge-back inbox + lineage guards** (§5) → fork.
4. **Fan-out:** `batch-spawn` + per-slice seed + `parentCardId` (epic→tasks).
5. **`onEnter` column policy** (axis 1) — makes plan→impl/review resets automatic; manual
   `restart + seed` works without it.

Steps 2–4 are mostly wiring once step 1 exists. **The context seed is the chokepoint; build it first
and the rest is topology.**

## 9. Open items

- Seed delivery: seeded first message vs `--append-system-prompt` (precedence vs the hooks `--settings`).
- Merge-back timing: inject on the card's **next turn** vs interrupt the live agent immediately.
- `parentCardId` board affordance: ephemeral child popover vs full board citizen (link verb, axis 3).
- Fan-out: does the plan card persist as an epic or archive after spawning? (lineage/grouping UI.)
