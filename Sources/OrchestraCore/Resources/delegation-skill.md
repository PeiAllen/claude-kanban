---
name: orchestra-delegation
description: Use when working as a card on an Orchestra board — knowing which column/mode you're in and keeping it honest as your work changes phase, and deciding whether to delegate work to another card (spawn / handoff / fork / fan-out / wait) instead of doing it inline or with a native subagent.
---

# Orchestra delegation — knowing your column, and when to hand off / fork / fan-out / wait

You are one agent on an Orchestra board. Besides doing the work yourself, you can **delegate** to other
**cards** — each a durable, board-visible unit of work in its own git worktree, possibly running a
different agent. This skill is about **when** to reach for that, and when NOT to.

## Sandboxed agents: use MCP first

When your agent harness exposes Orchestra MCP tools, use them for Orchestra control calls such as `send`,
`move`, `spawn`, `batch-spawn`, `handoff`, `wait`, `merge-request`, `shipped`, and `archive`. The local
`orchestra` CLI talks to the daemon over a Unix socket, which a managed sandbox can deny even while the
equivalent MCP call succeeds. The CLI remains valid for unrestricted/local terminal workflows and
shell-native operations. If a CLI call is necessary but fails with `Operation not permitted` or cannot
reach the daemon, do not retry it: send the same operation through MCP. A semantic rejection from either
client is a real rejection, since both use the same Orchestra service.

## Your column is your phase — start on it, and keep it honest

**This applies only if you're a worktree card** (spawned with a `repo` + `branch`). A standalone
**Freeform** or **Scratch** card runs on its own — it is NOT on the board, has no lifecycle column, and
*cannot* `move` between columns (the daemon rejects it); your SessionStart orientation says so. Skip this
whole section if that's you.

A worktree card lives in one of three columns, which are the lifecycle stages of the work:

- **Plan** — you're scoping / figuring out what to do.
- **Implementation** — you're actively building.
- **Review** — the work is ready to be looked at (by a human, or a later automated pass).

At **SessionStart** you're handed a one-line orientation naming your column, your access mode
(read/write vs **read-only**), and your own card id. **Start on that footing without waiting to be
told** — if you were opened in Plan, begin planning; in Implementation, begin building; in Review, begin
reviewing; if you're read-only, read/search/analyze and report rather than editing.

As the work changes phase, **move yourself** so the board keeps reflecting reality. This is a
*suggestion*, not a leash — but a stale column misleads whoever is supervising the board:

- **Plan → Implementation** once you stop scoping and start building.
- **Implementation → Review** once the work is ready for someone to look at.
- **→ Plan** if you fall back to figuring out what to do.

Move with the `move` tool and your own card id (from your SessionStart orientation):
`move <thisCard> --col plan|impl|review`. It's just a board update — no worktree, wake, or round-trip
cost. Don't over-fuss it; move when you cross a real phase boundary, not on every small step.

## The delegation surface (the tools)

- **`spawn` / `batch-spawn`** — start a new card (or N) with a **seed** (the task + any handoff context).
  A spawn either cuts a git **worktree** (`repo` + `branch`) *or* runs **freeform** in an existing
  directory (`cwd`, no worktree) — optionally **read-only** (`access: readOnly`: the agent can
  read/search/git but not edit/write/commit).
- **`handoff <ref> <context…> [--model <id>]`** — F1 clean-context resume: kill + `--resume` the SAME
  session seeded with `context` (folded together with the card's pending inbox). Same worktree, same
  branch, fresh context window. Hand off to a *new* card instead by spawning with the context as the seed.
- **`--model <id>` on `handoff` / `restart` / `resume`** — **re-seat** the card onto a different model
  *in place*: same card, same worktree, same session lineage. `handoff --model` **carries the context
  across** (that's how you escalate yourself to a higher tier mid-task); `restart --model` deliberately
  **drops** it (fresh blank session); `resume --model` re-attaches the existing session on the new model.
  The id must come from your **own agent's** model list — a Claude card cannot re-seat onto a Codex model
  (the session transcript pins the agent), and an unknown id is rejected outright rather than silently
  ignored.
- **`send <ref> <message>`** — enqueue a message into a card's durable inbox (F3); it drains at the card's
  next turn-end, waking it if idle.
- **`wait <ref…>`** — subscribe to **any** watched card's conclusion (merged / done / exited) so you are
  reminded/woken when it finishes. In a managed/sandboxed harness, use MCP `wait`; it records the durable
  watch and returns immediately. In a terminal-native Claude environment, CLI wait may instead run as a
  native Claude Code background task (Bash with `run_in_background: true`, or Monitor if available), so
  Claude is re-invoked when that background process prints/exits.

## Delegate, or just continue?

Delegate only when the work wants **isolation, parallelism, durability, a different agent, or its own
PR/branch**. If it fits your current context and is tightly coupled to what you're already doing, **just do
it inline** — a card + worktree + wake round-trip is real overhead. Don't pay it for trivial or
tightly-coupled work.

## The four moves — when to use each

- **Handoff** — *your context is exhausted or messy but the task continues.*
  - *Same card* (`handoff <thisCard> <summary>`): keep going on the SAME work with a clean context window,
    same worktree/branch. Write a tight summary as the seed.
  - *Same card, higher tier* (`handoff <thisCard> <summary> --model <id>`): the work turned out to need a
    stronger model. **Re-seat yourself** — same card, same branch, context carried across in the summary —
    rather than spawning a successor card and abandoning this one.
  - *New card* (spawn with the summary as seed): when the continuation is distinct work, a different agent,
    or should run while THIS card stays alive.
- **Fork** — *you want an independent exploration or side-discussion of a slice, and you'll want the
  result back.* Default to a **lightweight read-only freeform card in the same directory**: `spawn` with
  `cwd` = your working dir, `access: readOnly`, and the slice as the `seed` — no worktree, no branch,
  nothing to clean up. It explores and reports back via a wake + your inbox. Ideal for *"while planning,
  go over components A, B, and C separately without clogging this context, then pull their conclusions
  back."* Only cut a **worktree fork** (`spawn` with `repo` + `branch`) when the fork will change files
  and you want its own branch/PR.
- **Fan-out** — *N independent pieces of work to run in parallel*, each in its own worktree. `batch-spawn`
  them. There's no come-back wiring unless you also `wait`. Good for a stacked-PR forest or N independent
  tasks.
- **Wait** — *after spawning children, react when they finish.* In a managed/sandboxed harness, start
  MCP `wait`; Orchestra records the durable watch and resumes you when a child concludes. In a
  terminal-native Claude environment, start `orchestra wait <refs>` through Claude Code's background
  execution (`run_in_background: true`) or Monitor. The wait process exits when any child concludes, and
  Claude can then inspect the process output plus the durable inbox, react, and spawn the next PR in the
  stack. Several children concluding at once coalesce in the inbox and drain together — none is lost.

  Choose one completion return channel for each child. If you subscribe with `wait`, treat the wait wake
  as that child's completion signal; do not also ask those same children to `send` a completion/result to
  your inbox, or you can receive two notices in either order. If you need a child-authored result message
  in your inbox, ask the child to `send` that message when done and do not also `wait` on that child.

  **And then archive it.** A child that `send`s its result and ends its turn is left `waiting`, not
  concluded — nothing reclaims it but you. Once you've taken its result and have no follow-up turn to
  ask of it, `archive` the card: research forks, fan-out probes, reviewers alike. Children that
  conclude on their own (merged, exited) need nothing.

## Review pairs — requesting a bounded dual review

To get a plan or implementation reviewed, spawn **one Claude + one Codex reviewer simultaneously**,
both **read-only**, and bound the exchange. Do NOT loop "until no complaints" — deep looped review
belongs to the periodic (streaming) review card, and even that is capped at 3 pair-passes.

- **Reviewing committed work on a branch:** spawn each reviewer as a read-only **worktree** card
  with `base: <your-branch>` — its branch is cut at your tip commit at spawn time, so it reviews a
  **pinned snapshot** even while your branch advances underneath it. Never point a reviewer at a
  working directory that is still being mutated (a freeform `cwd` reviewer sees a moving tree —
  it will silently review the wrong code).
- **Reviewing a plan/doc only:** a read-only freeform card (`cwd` = your worktree) is fine if you
  will not touch the tree while it runs; otherwise pin via `base` as above.
- **Seed** each reviewer with: exactly what to review (diff range / files / doc), the pinned
  commit, and the output contract — *"send your findings to <me> via `send`, severity-tagged
  BLOCKER / MAJOR / minor, then conclude."* Findings return via `send`; do **not** also `wait` on
  the reviewers (one completion channel per child).
- **The bound:** one pass. Fix every confirmed finding; record a one-line rebuttal for anything
  you reject (verify feedback — don't comply performatively). **Iff** any BLOCKER/MAJOR was
  raised, `send` the fix diff back to the same reviewers for **one** confirm/deny turn. Then stop;
  record leftover minors for the next periodic review card.
- **Then archive both reviewers — the parent's job.** Keep them alive until the pass *closes* (the
  confirm/deny turn needs their context), then `archive` every reviewer card, including a failed or
  wholly-rebutted one. They're throwaway. A reviewer left `waiting` is a leak — agent process,
  worktree, tmux session, dead `review/*` branch — and nothing else reclaims it.
- **Degrade, don't hang:** if one backend fails to spawn, proceed **single-reviewer** and say so
  in your plan/merge-request. If one reviewer's findings arrive and the other's don't: `status`
  the straggler — dead → proceed single-reviewer; alive → nudge once via `send`, and if still
  silent by your next wake, archive it and proceed. **Zero** completed reviews = do not advance.

## Cards vs. native subagents — keep both

You also have **native subagents** (the `Task` tool). These are NOT the same as cards, and cards do **not**
replace them.

- Use a **card** for **durable · parallel · cross-agent · isolated** work: it outlives your turn, gets its
  own git worktree, can run in parallel while you stay chattable, can be a different agent (Claude ↔ Codex),
  can produce a PR/branch, and is visible on the board.
- Keep a **native subagent** for **ephemeral, in-context fan-out**: read-only research sweeps, quick
  parallel lookups, throwaway analysis whose result you fold back into your OWN turn right away. A subagent
  has no worktree, no durable state, is gone at turn-end, and is not on the board.

**Rule of thumb:** if the result must survive your turn, produce a commit or PR, run in parallel while you
stay responsive, or use a different agent → **card**. If you just need to parallelize reading/searching and
synthesize the answer now → **subagent**. Reach for a card *in addition to*, never *instead of*, subagents.

## The reactive orchestration loop

The headline pattern: spawn the stack head → subscribe with MCP `wait` in a managed/sandboxed harness
(or start `orchestra wait <child>` as a Claude Code background task in a terminal-native environment) →
your turn ends → the child concludes → the agent wakes → drain your inbox → spawn the next-in-stack off
the merged branch. Repeat. That is how one card orchestrates a whole PR forest without polling.
