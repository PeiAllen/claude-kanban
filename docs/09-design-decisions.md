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
substrate** these topologies compose from is specified as three functions — **F1** resume-in-card,
**F2** wake an idle card, **F3** the durable per-card **inbox** (merge-back drains at the next turn-end) —
in the [agent-provider interface](../notes/designs/agent-provider-interface/index.md) L3 design. **F3 has
now landed** (PR C1, below): `send` routes through a durable [inbox store](03-data-model.md#the-inbox-store-f3),
and the Claude Stop hook drains it into the agent at its turn-end. `send`-to-tmux is retired exactly as the
maxim demanded — a queued conclusion no longer throws if the session died, and coalesces with other returns
until the next turn. **F2 wake + the conclusion-watch have now landed too** (PR C2, below): the
[`wait` command / `MergeWatch`](05-command-reference.md#notes-on-key-commands) let an orchestrator card
block until a watched child concludes, with each conclusion coalescing into the parent's inbox and waking
it — the reactive fan-out. (`notes/designs/context-passing-topologies.md`, `stacked-branches-and-guardian-handoff.md`.)

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

A third forest PR has landed on top of A1 — **A2, the telemetry-source seam**
(`notes/plans/2026-07-01-a2-telemetry-source-seam.md`). It draws the **transport/parse boundary** the
agent-provider design (D3) calls for: the daemon-side **transport** obtains only *raw* bytes, while the
raw→`StatusReport` **parse** is the **adapter's** own, because that conversion is agent-dependent. A2
relocated the parse out of the `orchestra` CLI target (the former `ReportHelper.map`/`toolDesc`) into a new
defaulted protocol method `Adapter.parse(_ raw: RawTelemetry) -> StatusReport?` (added with a `nil`-returning
default in `extension Adapter`, so no conformer breaks) plus a `RawTelemetry` envelope
(`hooksPush(kind:payload:)` for pushed hook events, `fileTail(line:)` reserved for a future rollout tailer;
`ptyScrape` deferred — no v1 consumer). `ClaudeCodeAdapter.parse` now owns the `hooksPush` conversion,
carrying the former CLI logic **verbatim**; the hidden `orchestra _report` helper — which *is* the Claude
push transport — calls `ClaudeCodeAdapter().parse(.hooksPush(...))` instead of a local `map`. The daemon's
`report` endpoint and the `OrchestraService.report` seq-gate merge are **untouched**, so Claude telemetry
is byte-identical (the pre-existing `ReportTests` stayed green unchanged). The `fileTail` parse and the
daemon-side rollout tailer that feeds it — the same `adapter.parse` seam from a different transport — land
with the Codex adapter (PR B2). Like A1 and E2, this is a single forest PR of plumbing, not a whole axis,
so it stays here as history rather than migrating a roadmap row. (As-built symbols are recorded in
[agent-provider-interface/02-contract.md](../notes/designs/agent-provider-interface/02-contract.md) §Area 1.)

A fourth landed PR is **C1 — the durable inbox + F3 Stop-drain**
(`notes/plans/2026-07-01-c1-inbox-stopdrain.md`). It builds the first of the design's three live-delivery
functions (see [One seed, four topologies](#one-seed-four-topologies)): a durable per-card **`Inbox`**
store (sibling to `TaskStore`, actor-over-JSON, FIFO-per-card, restart-durable — see
[the inbox store](03-data-model.md#the-inbox-store-f3)), with `send` **rerouted through it** instead of
typing into tmux, and a `StopDrain` helper that composes the pending messages into a 10 000-char-bounded
payload. The delivery reuses — rather than adds to — the existing Claude Stop hook: the same
`_report --event notify` command, on detecting `hook_event_name == "Stop"`, calls a new Orchestra-internal
[`drain` RPC](05-command-reference.md#server-only-built-in-methods) and prints a `{"decision":"block",
"reason":…}` continuation so the model reads the queued messages and keeps working. Two decisions shape it:
the merge-back is **turn-end, never mid-turn** — a queued `send` waits for the agent's natural stop rather
than interrupting it — and because `stop_hook_active` is only *informational* on the agent, Orchestra
enforces its **own consecutive-inject loop guard** (`drainForStop`, cap 25, reset by a genuine
`UserPromptSubmit`) to break a runaway Stop→inject→Stop cycle, leaving messages durable when it trips. The
change is deliberately additive: `HooksRenderer`/`claude-hooks.json` are untouched, and the Stop hook's
existing notify→`waiting` report is preserved byte-for-byte. Waking an *idle* card so it takes a turn to
drain (F2) is the next increment. Like the forest PRs above, C1 is one live-delivery function, not a whole
axis, so it stays here as history while the roadmap's context-continuity row remains open.

A fifth landed PR is **C2 — F2 wake + the merge-watch conclusion-watch**
(`notes/plans/2026-07-01-c2-wake-mergewatch.md`). It builds the second of the three live-delivery functions
and the reactive fan-out on top of C1's inbox: an orchestrator card can watch its spawned children and be
woken as each concludes. Two symbols carry it — a `MergeWatch` actor and a `Conclusion` value
(`{cardId, ref, kind ∈ {done, exited}}`), surfaced as the [`wait` command](05-command-reference.md#notes-on-key-commands)
(auto-exposed as an MCP tool; registry↔MCP parity stays green) plus an `orchestra wait <ref…>` CLI verb.
Three decisions shape it:

- **Conclusion is read from real card state, never git.** The prior fan-out bug was calling `git merge-base`
  to decide "merged" — which false-positives a branch with **zero commits ahead of main** as already merged.
  C2 keys conclusion on `OrchestraService`'s own derived card state (`isConcluded`: archived/Done, or dead
  with `deadReason == .agentExited`), the state it already adjudicates. A dedicated regression test pins the
  0-commit case as *not* concluded.
- **The service is the single authority; `MergeWatch` only subscribes.** `MergeWatch` owns **no** detection —
  no git poll, no file stat, no per-card watcher. It parks a `CheckedContinuation` keyed on the watch set (the
  existing `awaitResume`/`resolveResume` pattern) and is resolved when the service — the one writer that marks
  terminal state — calls `concludeCard`. That call fires from exactly two places: `archive` (→ `.done`) and
  the `report` clean-exit branch (agent-exited, guarded so a *recovering* card never counts → `.exited`). A
  transient crash (`sessionVanished`) that may still be revived is deliberately **not** a conclusion —
  "process ended" ≠ "card concluded."
- **Fan-out coalesces; wake is only a trigger.** Watching N children yields **one conclusion per child, as
  each concludes** — not a barrier on all N. `concludeCard` routes each into every registered watcher's
  durable inbox (F3 coalesce) and calls `wake`; several children concluding while the parent is mid-turn all
  enqueue and drain together at its next turn-end, so no return is lost or needs its own wake. `wake` dispatches
  on the adapter's `wakeTransport`: Claude's `nativeReinvoke` is a no-op *push* — the wake instead rides the
  background `orchestra wait` process exiting (which the harness re-invokes on), and Codex send-keys is deferred
  to a later PR (C4). `wait` also short-circuits on an already-concluded child so the re-issue race can't lose a
  conclusion.

Like the forest PRs above, C2 is one live-delivery function, not a whole axis, so it stays here as history;
the remaining live-delivery function — **F1** resume-in-card — and the Codex send-keys wake keep the roadmap's
model-providers / context-continuity rows open. (As-built symbols are recorded in
[agent-provider-interface/02-contract.md](../notes/designs/agent-provider-interface/02-contract.md) §Area 4.)

The roadmap of what comes next — the nine extensibility axes the system is being designed toward — is
[chapter 10](10-roadmap.md).
