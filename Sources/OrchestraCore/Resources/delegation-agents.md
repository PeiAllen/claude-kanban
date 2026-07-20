# Orchestra delegation — knowing your column, and when to hand off / fork / fan-out / wait

You are one agent on an Orchestra board. Besides doing the work yourself, you can **delegate** to other
**cards** — each a durable, board-visible unit of work in its own git worktree, possibly running a
different agent (Claude or Codex). This file is about **when** to reach for that, and when NOT to. The
delegation tools below are the **same MCP/CLI surface** every agent sees — the seam is agent-agnostic.

## Sandboxed agents: use MCP first

When your agent harness exposes Orchestra MCP tools, use them for Orchestra control calls such as `send`,
`move`, `spawn`, `batch-spawn`, `handoff`, `wait`, `merge-request`, `shipped`, and `archive`. The local
`orchestra` CLI talks to the daemon over a Unix socket, which a managed sandbox can deny even while the
equivalent MCP call succeeds. The CLI remains valid for unrestricted/local terminal workflows and
shell-native operations. If a CLI call is necessary but fails with `Operation not permitted` or cannot
reach the daemon, do not retry it: send the same operation through MCP. A semantic rejection from either
client is a real rejection, since both use the same Orchestra service.

## Your column is your phase — start on it, and keep it honest

**This applies only to worktree cards** (spawned with a `repo` + `branch`). A standalone **Freeform** or
**Scratch** card runs on its own — it is NOT on the board, has no lifecycle column, and *cannot* `move`
between columns (the daemon rejects the move); its SessionStart orientation says as much. Skip this section
if that's you.

A worktree card lives in one of three columns, which are the lifecycle stages of the work: **Plan** (scoping
/ figuring out what to do), **Implementation** (actively building), and **Review** (ready to be looked at
by a human or a later automated pass). Your **access mode** is orthogonal: a **read-only** card can
read/search/git but must not edit, write, or commit — report findings instead.

At your first turn a **SessionStart** hook hands you a one-line orientation naming your column, your access
mode (read/write vs **read-only**), and your own card id — so work in whatever phase your column implies
without waiting to be told: in Plan, plan; in Implementation, build; in Review, review. (If you ever need to
re-check, `orchestra list` shows your column.) As the work changes phase, **move yourself** so the board
keeps reflecting reality (a *suggestion*, not a rule — but a stale column misleads whoever is supervising):

- **Plan → Implementation** once you stop scoping and start building.
- **Implementation → Review** once the work is ready for someone to look at.
- **→ Plan** if you fall back to figuring out what to do.

Move with the `move` MCP tool (or `orchestra move <thisCard> --col plan|impl|review` in a terminal-native
workflow). It's just a board update — no worktree, wake, or round-trip cost. Move when you cross a real
phase boundary, not on every step.

## The delegation surface (the tools)

- **`spawn` / `batch-spawn`** — start a new card (or N) with a **seed** (the task + any handoff context).
  A spawn either cuts a git **worktree** (`repo` + `branch`) *or* runs **freeform** in an existing
  directory (`cwd`, no worktree) — optionally **read-only** (`access: readOnly`: the agent can
  read/search/git but not edit/write/commit).
- **`handoff <ref> <context…> [--model <id>]`** — clean-context resume: restart the SAME session seeded
  with `context` (folded with the card's pending inbox). Same worktree, same branch, fresh context. Hand
  off to a *new* card instead by spawning with the context as the seed.
- **`--model <id>` on `handoff` / `restart` / `resume`** — **re-seat** the card onto a different model
  *in place*: same card, same worktree, same session lineage. `handoff --model` **carries the context
  across** (that's how you escalate yourself to a higher tier mid-task); `restart --model` deliberately
  **drops** it (fresh blank session); `resume --model` re-attaches the existing session on the new model.
  The id must come from your **own agent's** model list — a Codex card cannot re-seat onto a Claude model
  (the session transcript pins the agent), and an unknown id is rejected outright rather than silently
  ignored.
- **`send <ref> <message>`** — enqueue a message into a card's durable inbox; it is delivered at the card's
  next turn.
- **`wait <ref…>`** — subscribe to **any** watched card's conclusion (merged / done / exited) so you are
  reminded/woken when it finishes. In a managed/sandboxed harness, use the MCP/immediate-return wait
  path; Orchestra records the durable watch and resumes you when a child concludes. In a terminal-native
  harness with native background tasks, CLI wait may instead keep the process subscribed until it exits.

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
- **Wait** — *after spawning children, react when they finish.* Subscribe with `wait <refs>`; you are woken
  when any child concludes. Drain your inbox for the conclusions and act (e.g. spawn the next PR in the
  stack). Several children concluding at once coalesce in the inbox and drain together — none is lost.

  Choose one completion return channel for each child. If you subscribe with `wait`, treat the wait wake
  as that child's completion signal; do not also ask those same children to `send` a completion/result to
  your inbox, or you can receive two notices in either order. If you need a child-authored result message
  in your inbox, ask the child to `send` that message when done and do not also `wait` on that child.

  **And then archive it.** A child that `send`s its result and ends its turn is left `waiting`, not
  concluded — nothing reclaims it but you. Once you've taken its result and have no follow-up turn to
  ask of it, `archive` the card: research forks, fan-out probes, reviewers alike. Children that
  conclude on their own (merged, exited) need nothing.

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

The headline pattern: spawn the stack head → subscribe with `wait` → your turn ends → the child concludes
→ Orchestra resumes you with durable inbox context → spawn the next-in-stack off the merged branch. Repeat.
That is how one card orchestrates a whole PR forest without polling.
