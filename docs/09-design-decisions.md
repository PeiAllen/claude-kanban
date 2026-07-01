# 9. Design decisions

This chapter records the *why* behind Orchestra — the cross-cutting principles that shape the system,
and the history of the shipped feature PRs. The authoritative source is the layered design vault under
[`notes/designs/`](../notes/designs/) (each topic has `index.md` + 01-design → 04-tests layers) and the
shipped-PR plans under [`notes/plans/`](../notes/plans/); this chapter summarizes and links into them.

## Cross-cutting principles

### Thin clients, single coordinator

The daemon runs the one `CommandRegistry` and the `OrchestraService` actor; the app, CLI, and MCP
bridge each serialize calls independently and converge at the server. Commands go in, events come out.
There are no distributed state machines and no per-client truth — a spawn from the CLI updates the app's
board because both subscribe to the same event stream. (`notes/designs/kanban-board/index.md`, "Control-
plane data flow — one coordinator, but federated truth".)

### Federated ground truth, not in-memory state

The daemon does not treat its memory as authoritative. **`tasks.json`** holds metadata, **tmux** is the
authority on liveness, and **git** is the authority on the worktree. This is what makes recovery robust:
the daemon (or the whole machine) can restart and reconstruct reality from disk + `tmux ls` + git,
rather than losing track of running agents.

### Terminal bytes bypass the daemon

The control plane carries commands, state, and events — never PTY bytes. SwiftTerm and the CLI's
`shell`/`inspect` attach to **tmux directly**. This keeps the daemon simple and the terminals fully
interactive and real-time.

### State is pushed through a two-way hook channel

Live card fields (`ctxPct`, `desc`, `status`, session id, title) are **pushed by the agent** via a
managed Claude Code `--settings` file (statusLine + hooks → `orchestra _report`), not scraped from the
pane. The channel is bounded (a stalled daemon can't freeze the agent's status bar) and seq-guarded (a
stale `ctxPct` can't overwrite a fresh one); pane capture is a fallback only. The same channel is the
backbone for the planned Orchestra → agent context injection. (`kanban-board/index.md`, "The Orchestra
hook protocol".)

### Ownership: Orchestra deletes only what it made

Cleanup is decided by `origin`:

- **`worktree`** — Orchestra created it; archive removes the dir (kept if dirty, and only when no other
  live worktree card shares it).
- **`scratch`** — Orchestra created it; archive **unconditionally** `rm -rf`s it (double-gated by the
  `origin == .scratch` check *and* a runtime prefix check under the scratch root).
- **`borrowed`** — *you* created it; archive never touches it.

This clean rule removes any ambiguity about which cleanup is safe. (`notes/designs/freeform-and-
borrowed-cards/index.md`.)

### Trust boundaries: allowlist for worktrees, sandbox for the rest

Worktree cards validate their repo path against the allowlist (`PathResolver`, symlink- and
`..`-escape-safe, component-wise prefix). Borrowed and scratch cards skip the allowlist and rely on the
OS sandbox confining writes to their directory — so freeform cards stay friction-light while the
boundary still holds.

### Read-only is defense in depth

A read-only agent is constrained by three independent layers — edit tools removed, a kernel-level
sandbox write-block, and a semantic auto-mode "deny any mutation" classifier — chosen over a brittle
command deny-list precisely because deny-lists rot and are trivially evaded. (See
[the read-only barrier](04-cards-worktrees-sessions.md#the-read-only-barrier);
`notes/plans/pr1-readonly-inspect-button.md`.)

### authMode: advise on fan-out, never cap

Fanning out many concurrent agents onto a **single subscription seat** (a Claude or Codex plan login,
rather than a metered API key) is the "heavy parallel automation" pattern both providers' anti-automation
terms target — so Orchestra notices it, but it **advises and never blocks**. When a card is brought up on
an adapter whose `capabilities.authMode` is `.subscription`, `AuthRateMonitor` tallies the *live*
subscription-auth cards for that same adapter and, past a threshold (default 3 → the 4th warns), emits an
advisory `ActivityKind.warning` into the feed suggesting API-key mode for large fan-outs. The spawn always
proceeds; there is **no concurrency cap, no queue, no rejection**. Three properties make this a decision
rather than a knob:

- **Warn-only, resolved deliberately.** Capping was considered and rejected — a hard limit on parallelism
  would break the very fan-out topology Orchestra exists to enable. The monitor never throws or blocks.
- **Rate state is per-adapter and derived, not held.** Each subscription is its own seat, so a Claude
  fan-out never pushes a Codex adapter over, and vice versa; and the tally is computed from the current
  card set (the SSOT) on every spawn rather than kept in a counter — so it can't drift and survives a
  daemon restart with no reconciliation.
- **It gates on the capability, never on identity.** The monitor reads `adapter.capabilities.authMode`,
  so an API-key adapter (or a future subscription agent) is classified by its descriptor, never by an
  `if agentId == "claude-code"` branch.

(Agent-provider forest PR **E2**; `notes/plans/e2-authmode-softwarn.md`,
`notes/designs/agent-provider-interface/03-implementation.md` D12 / §9 / q4.)

### 1:1 worktree ↔ card ownership

The target model is **one card owns one branch's worktree** — enforced, not shared. Git forbids the
same branch in two worktrees, so every N:1 case is two writers on one branch (a footgun with no safe
use). Stacked branches want *distinct* trees (still 1:1). This retires the old refcount guard + shared-
worktree badge machinery; the safe co-location patterns (read-only inspect, freeform cards) don't need
worktree sharing. (`notes/designs/stacked-branches-and-guardian-handoff.md`.)

### One seed, four topologies

Handoff, fork, fan-out, and (Claude) subagents are **one primitive** — a fresh session seeded with
authored context — at four topologies. The keystone is an `additionalContext` seed on the spawn/restart
path. The decision rule: *return to the thread?* → fork or subagent; *replace the thread?* → handoff;
*split into many?* → fan-out. Merge-back must be a **durable persisted inbox keyed on card lineage**, not
a `send`-to-tmux (which throws if the session died), and orphaned forks are promoted to standalone cards
rather than cascade-killed. The guiding maxim: **handoff carries intent, artifacts carry facts** — the
seed is for navigation and next steps, while committed code, plan files, and the card description carry
the durable record, so successive handoffs don't degrade into a telephone game. The **live-delivery
substrate** these topologies compose from is now specified as three functions — **F1** resume-in-card,
**F2** wake an idle card, **F3** the durable per-card **inbox** (merge-back drains at the next turn-end) —
in the [agent-provider interface](../notes/designs/agent-provider-interface/index.md) L3 design.
(`notes/designs/context-passing-topologies.md`, `stacked-branches-and-guardian-handoff.md`.)

## Shipped feature history

The v1 architecture (daemon + control plane + two-way hook protocol + per-card worktree + session
recovery + activity feed + sessions debug handles) is documented in the
[`kanban-board/`](../notes/designs/kanban-board/) design vault. On top of it, four feature PRs shipped
(plans in [`notes/plans/`](../notes/plans/)):

| PR | Delivered | Key decision |
|----|-----------|--------------|
| **PR1** — read-only inspect | An inspector button that opens a read-only `claude` in a card's worktree (read/search/git, no writes). | Two independent locks (tool denial + sandbox `denyWrite`); a normal conversational agent that just can't write (not "plan mode"); throwaway and untracked. |
| **PR2** — task schema `cwd`/`origin` | Migrated `Task` from a single `worktree: String` to `cwd: String` + `origin: CardOrigin`. | A *total* `cwd` (no `effectiveCwd` helper); a 3-way `origin` enum instead of two bools (which would have an impossible 4th combo); behavior-neutral (only `.worktree` cards existed after it). |
| **PR3** — freeform & borrowed cards | Cards that run in an existing directory the user doesn't own (`.borrowed`), in a standalone freeform region, plus the `.readOnly` access mode for tracked read-only cards. | Sandbox-as-boundary (no allowlist gate); rescoped the shared-worktree badge/refcount to worktree cards only. |
| **PR4** — scratch cards | A scratch spawn mode (board, CLI `--scratch`, MCP) that makes a fresh `~/.orchestra/scratch/<id>` dir and `rm -rf`s it on archive; startup sweep of orphaned scratch dirs; auto-trusts the dir so the autonomous agent never blocks on Claude's trust dialog. | Double-gated delete (origin check + path-under-scratch-root check); no dirty-guard (the user moves out anything worth keeping first). Trust is *granted* (not mirrored) because Orchestra owns the dir — there's no source repo to mirror from — while borrowed dirs are left to Claude's own prompt. |

Beyond those four feature PRs, the first **foundational** PR of the agent-provider forest has also landed —
**A1, the seam-contract freeze** (`notes/plans/2026-07-01-a1-seam-contract-freeze.md`). It froze the
complete **`AgentCapabilities`** descriptor (seven enum-typed flags, *every* variant spelling — including
cases no adapter exercises yet — locked now so later PRs can't drift the shape) and the defaulted
**`AdapterContext.seed`** carrier, and moved core to gate session-seeding and resumability on the
capability rather than on adapter identity or a nil-return implication. It ships **no** user-visible
change — Claude behavior is byte-for-byte unchanged — because it is deliberately just the drift-proof
shape the Codex adapter, telemetry seam, and live-delivery PRs will build behind (see
[the adapter capability descriptor](04-cards-worktrees-sessions.md#agent-adapters)). Unlike a full axis
shipping, this is plumbing, not a feature — so it stays here as history rather than migrating a roadmap
row.

A second forest PR has since landed on top of A1 — **E2, the authMode soft-warn**
(`notes/plans/e2-authmode-softwarn.md`). It adds a pure `AuthRateMonitor` value type and an `AuthWarning`
result that watch for heavy parallel fan-out on a single subscription seat and emit an advisory
`ActivityKind.warning` past a threshold — **advising, never capping** (see
[authMode: advise on fan-out, never cap](#authmode-advise-on-fan-out-never-cap) above for the decision and
its rationale). Like A1 it is a single forest PR rather than a whole axis, so it too stays here as history
and leaves the roadmap row for the model-providers/agent-integration axes in place until the full seam
ships.

The roadmap of what comes next — the nine extensibility axes the system is being designed toward — is
[chapter 10](10-roadmap.md).
