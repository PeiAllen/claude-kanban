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
the durable record, so successive handoffs don't degrade into a telephone game.
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
| **PR4** — scratch cards | A scratch spawn mode that makes a fresh `~/.orchestra/scratch/<id>` dir and `rm -rf`s it on archive; startup sweep of orphaned scratch dirs. | Double-gated delete (origin check + path-under-scratch-root check); no dirty-guard (the user moves out anything worth keeping first). |

The roadmap of what comes next — the nine extensibility axes the system is being designed toward — is
[chapter 10](10-roadmap.md).
