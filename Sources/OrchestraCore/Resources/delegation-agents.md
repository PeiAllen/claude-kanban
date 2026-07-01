# Orchestra delegation — when to hand off, fork, fan-out, or wait

You are one agent on an Orchestra board. Besides doing the work yourself, you can **delegate** to other
**cards** — each a durable, board-visible unit of work in its own git worktree, possibly running a
different agent (Claude or Codex). This file is about **when** to reach for that, and when NOT to. The
delegation tools below are the **same MCP/CLI surface** every agent sees — the seam is agent-agnostic.

## The delegation surface (the tools)

- **`spawn` / `batch-spawn`** — start a new card (or N) with a **seed** (the task + any handoff context).
  A spawn either cuts a git **worktree** (`repo` + `branch`) *or* runs **freeform** in an existing
  directory (`cwd`, no worktree) — optionally **read-only** (`access: readOnly`: the agent can
  read/search/git but not edit/write/commit).
- **`handoff <ref> <context…>`** — clean-context resume: restart the SAME session seeded with `context`
  (folded with the card's pending inbox). Same worktree, same branch, fresh context. Hand off to a *new*
  card instead by spawning with the context as the seed.
- **`send <ref> <message>`** — enqueue a message into a card's durable inbox; it is delivered at the card's
  next turn.
- **`wait <ref…>`** — block until **any** watched card concludes (merged / done / exited). Run it in the
  background so your turn ends; you are nudged awake when a child concludes.

## Delegate, or just continue?

Delegate only when the work wants **isolation, parallelism, durability, a different agent, or its own
PR/branch**. If it fits your current context and is tightly coupled to what you're already doing, **just do
it inline** — a card + worktree + wake round-trip is real overhead. Don't pay it for trivial or
tightly-coupled work.

## The four moves — when to use each

- **Handoff** — *your context is exhausted or messy but the task continues.*
  - *Same card* (`handoff <thisCard> <summary>`): keep going on the SAME work with a clean context window,
    same worktree/branch. Write a tight summary as the seed.
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
- **Wait** — *after spawning children, react when they finish.* Background `wait <refs>`; you are woken when
  any concludes; drain your inbox for the conclusions and act (e.g. spawn the next PR in the stack). Several
  children concluding at once coalesce in the inbox and drain together — none is lost.

  Note: Codex is woken by a send-keys **nudge**, so a just-concluded delegation may take a beat to surface
  in your composer — that's expected; the conclusion is already durable in your inbox.

## Cards vs. ephemeral in-context helpers — keep both

Spinning up a **card** is heavyweight and durable; it is NOT the tool for throwaway, in-context work.

- Use a **card** for **durable · parallel · cross-agent · isolated** work: it outlives your turn, gets its
  own git worktree, can run in parallel while you stay responsive, can be a different agent, can produce a
  PR/branch, and is visible on the board.
- Keep **ephemeral in-context work** (a quick read-only sweep, a lookup, throwaway analysis you fold back
  into your OWN turn right away) *in your own turn* — don't spin up a card for it. If your harness has a
  native subagent / task helper, that is the right tool for ephemeral fan-out; a card is not.

**Rule of thumb:** if the result must survive your turn, produce a commit or PR, run in parallel while you
stay responsive, or use a different agent → **card**. If you just need to parallelize reading/searching and
synthesize the answer now → keep it **in-context** (a native subagent if you have one). Reach for a card
*in addition to*, never *instead of*, ephemeral in-context helpers.

## The reactive orchestration loop

The headline pattern: spawn the stack head → background `wait` → your turn ends → the child concludes → you
are nudged awake → drain your inbox → spawn the next-in-stack off the merged branch. Repeat. That is how one
card orchestrates a whole PR forest without polling.
