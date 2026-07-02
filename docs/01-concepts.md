# 1. Concepts

This chapter defines the vocabulary the rest of the manual relies on: what Orchestra is, what a *card*
is, the columns and lifecycle a card moves through, and the four *modes* a card can run in.

## What Orchestra is

Orchestra is a **local-only, single-user, native macOS app for orchestrating many coding agents at
once.** Instead of babysitting one agent in one terminal, you run a *board* of them — each agent works
autonomously in its own isolated directory while you supervise from a Kanban view, stepping in only
when a card needs steering or review.

It is deliberately **local-only**: there is no server, no account, no network service. Everything runs
on your Mac. The only network access in the whole system is the first `swift build` resolving the MCP
SDK dependency; after that the core, daemon, and CLI are fully offline.

Three facts define the shape of the product:

- **The agent is the unit of work.** One card = one autonomous agent session.
- **The daemon is the source of truth.** A background process (`orchestrad`) owns the tasks, worktrees,
  and sessions and keeps running with the app closed. The app is just one of three windows onto it.
- **State is pushed, not polled.** The agent reports its own context-window usage, current activity,
  and status back to the board through a hook channel, so the board reflects reality in near real time.

The authoritative high-fidelity UI is the **Orchestra** prototype on Claude Design; the app's visual
language (light/linear, radial wallpaper, hairline borders, mono accents) matches it pixel-for-pixel.

## Cards

A **card** is a [`Task`](03-data-model.md) — an autonomous, persistent agent session occupying one row
of the board. Each card tracks a single agent's work and carries everything needed to display, drive,
resume, and clean up that work:

- a **title** (derived from the first prompt) and a live **description** (pushed by the agent),
- the **directory** the agent runs in (`cwd`) and how that directory came to be (`origin`),
- the **agent** and **model** running it,
- its **column** and **status**,
- and its session identity (`agentSessionId`, plus superseded ids) for resume and transcript search.

Each card maps to exactly one **tmux session** named `orchestra-<uuid>`, and (for worktree cards) to
exactly one **git worktree**. A card is referenced by a short id (the first 6 characters of its UUID),
its full UUID, or an `orchestra://task/<shortId>-<slug>` URI — any of which the CLI, MCP, and deep
links accept. See [Cards, worktrees & sessions](04-cards-worktrees-sessions.md) for the mapping.

## Columns and the lifecycle

The board has **three columns**, which are the lifecycle stages of a card:

| Column | Display name | Meaning |
|--------|--------------|---------|
| `plan` | Plan | Early/exploratory work — the agent is figuring out what to do. |
| `impl` | Implementation | Active work — the agent is building. |
| `review` | Review | The work is ready to be reviewed (by you, or later by an automated review phase). |

There is deliberately **no `done` column.** Finishing a card archives it: its status becomes `done` and
it leaves the board into the **Done popover** (an archive list). This keeps the board to the three
*active* stages and avoids a perpetually-growing fourth column. Archiving is **not terminal**, though —
a Done card can be **reopened** from the popover: the daemon recreates its worktree and resumes the
agent, bringing the card back onto the board in its original column
([`reopen`](04-cards-worktrees-sessions.md#recovery-resume-and-restart)).

A card also carries an independent **status** that reflects the agent's runtime state, distinct from
which column it's in:

| Status | Meaning |
|--------|---------|
| `waiting` | Idle, awaiting a prompt (e.g. a freshly-spawned provisional card, or one just restarted/cleared). |
| `running` | The agent is actively executing. |
| `done` | Finished and archived. |
| `dead` | The session crashed or exited and needs recovery — distinct from a clean `done`. |

You move a card between columns by dragging it on the board or with `orchestra move <ref> --col …`.
Status, by contrast, is driven by the agent itself through the report channel (a prompt submission
flips it to `running`; a `Stop`/`Notification` hook flips it to `waiting`; a `SessionEnd` can flip it
to `dead`). See [Architecture](02-architecture.md#the-report-channel) for how those signals arrive.

## The four card modes

A card's **origin** records how its working directory was created, and its **access** records whether
the agent may write. Together these give four practical modes:

| Mode | `origin` | `access` | Directory | Orchestra cleans it up? |
|------|----------|----------|-----------|-------------------------|
| **Worktree** (default) | `worktree` | `readWrite` | A dedicated git worktree at `~/.orchestra/worktrees/<repo>/<branch>` | Yes — removed on archive (kept if dirty). |
| **Borrowed / Freeform** | `borrowed` | `readWrite` | Any existing directory you point at | No — never deletes a borrowed dir. |
| **Scratch** | `scratch` | `readWrite` | A fresh throwaway dir at `~/.orchestra/scratch/<id>` | Yes — `rm -rf` unconditionally on archive. |
| **Read-only** | any | `readOnly` | As above, but writes are blocked | Per the origin above. |

- **Worktree cards** are the default and the workflow's backbone. The repo must be on the allowlist;
  Orchestra cuts an isolated worktree so parallel agents never share a working tree. These are the
  cards that live in the Plan/Implementation/Review columns.
- **Borrowed (freeform) cards** run an agent directly in a directory you already have — no worktree, no
  allowlist gate (the OS sandbox is the boundary). They live in a separate **freeform region** docked
  below the columns, not in the workflow lanes.
- **Scratch cards** are for throwaway experiments: Orchestra makes a clean directory, and deletes it
  outright when you archive the card (a double-gated `rm -rf` that only fires for scratch origins under
  the scratch root).
- **Read-only** is an *access mode* layered on any origin: the agent gets edit tools removed, a
  kernel-level write-block on its directory, and a semantic "deny any mutation" policy. It can read,
  search, and run read-only `git`, but it cannot change anything. See
  [the read-only barrier](04-cards-worktrees-sessions.md#the-read-only-barrier).

The governing principle is **ownership**: *Orchestra deletes only what it made.* Worktrees and scratch
dirs it created are cleaned on archive; borrowed directories are left untouched. This is covered in
[Design decisions](09-design-decisions.md#ownership-orchestra-deletes-only-what-it-made).

## The three control surfaces

Everything Orchestra can do is exposed identically through three clients, because all three call the
same [`CommandRegistry`](05-command-reference.md):

- the **SwiftUI app** — the board, inspector, and embedded terminals;
- the **`orchestra` CLI** — scripting and quick actions from a shell;
- the **MCP bridge** — so another agent (e.g. a Claude Code session) can orchestrate the board itself.

This "one state, three surfaces" property is a core design commitment, not an accident — see
[Architecture](02-architecture.md). The next chapter explains how the surfaces, the daemon, and the
agents fit together.
