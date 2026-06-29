---
project: claude-kanban
feature: stacked-branches-and-guardian-handoff
type: design-note
created: 2026-06-29
updated: 2026-06-29
related:
  - "[[freeform-and-borrowed-cards/index|freeform-and-borrowed-cards]]"
  - "[[pr-review-phase/index|pr-review-phase (axis 5)]]"
  - "[[context-continuity/index|context-continuity (axis 6)]]"
  - "[[code-review-on-board/index|code-review-on-board (axis 7)]]"
  - "[[configurable-columns/index|configurable-columns (axis 1)]]"
  - "[[../plans/intentionally-support-multiple-cards-iridescent-otter|multi-card plan]]"
---

# Stacked Branches & the Guardian Hand-off — Design Note

> Resolves the "is card↔worktree 1:1 worth it?" question by working two real use cases —
> **stacked branches** and a **review/guardian phase** — all the way through. Conclusion:
> **target enforced 1:1** (each `.worktree` card owns exactly one branch's tree), keep the
> *worktree-optional* escape hatch (freeform/borrowed/scratch), and retire the N:1 collision
> machinery. Neither use case needs two live cards sharing one tree.

## 1. The decision: enforced 1:1, not N:1

Today the system *permits* N:1 incidentally — `WorktreeManager.ensure` is idempotent on
`repo+branch` (`WorktreeManager.swift:26`), so a second card on the same branch silently
reuses the tree. The [[../plans/intentionally-support-multiple-cards-iridescent-otter|multi-card plan]]
made that safe with an archive **refcount guard** + a **`SharedWorktreeBadge`** collision signal.

The hard constraint that reframes everything: **git forbids the same branch in two worktrees.**
So every possible N:1 case is *two cards on the identical `repo+branch`* — i.e. **two writers
on one branch with no lock.** That has no safe form. The safe co-location patterns we actually
want are read-only inspect (PR1 shell) and freeform/borrowed cards — none of which need
`.worktree` sharing.

**Decision:** make worktree↔card a real **1:1** invariant. Spawn on an already-checked-out
branch must not silently share — it either **refuses** (with a jump-to-the-owning-card
affordance) or **auto-branches** (suffixed branch + own tree). This **retires** the refcount
guard, `BoardModel.worktreeSiblings`, and the `SharedWorktreeBadge` + footer count badge — the
machinery existed only to babysit incidental sharing. (PR2's `cwd`/`origin` refactor stays; it's
net-positive under every option.)

> *Open:* refuse vs auto-branch at spawn. Refuse preserves branch identity (what the user typed);
> auto-branch never blocks but mutates the branch name. Lean **refuse + jump** for intentionality.

## 2. Stacked branches are the poster child *for* 1:1

A stack `A → B → C` is **distinct branches**, and git happily checks out distinct branches in
separate worktrees simultaneously. So the native model is one card per branch, each with its own
tree — parallel agents, **zero branch-switching churn**. (Keeping a stack "all on one worktree",
the common workaround, is strictly worse: one tree holds one checked-out branch, so everything
serializes.) This use case wants **more** worktrees, not shared ones.

**Gap — spawn off a base branch.** `WorktreeManager.swift:38` creates a new branch with
`git worktree add -b <branch> <wt>` and **no start-point**, so it always branches off the repo's
current HEAD. A stack needs `… add -b B <wt> A`. Add `base: String?` to `SpawnInput`, thread it to
`ensure(repo:branch:base:)`. *(Pre-existing stacks already work — line 36's existing-branch path
checks each branch out into its own tree.)*

**Gap — parent/stack metadata.** A `parentBranch` (or `parentCardId`) on the card unlocks:
- review diffs **relative to the parent**, not `main` (feeds [[code-review-on-board/index|axis 7]]'s
  `DiffProvider` baseline);
- **restack order** when a lower branch is amended;
- board **grouping** of a stack.

**Restacking** (rebase B/C onto an amended A) is a feature in its own right — a command or a
guardian agent that walks the stack parent-first. Orthogonal to the schema; out of scope here.

## 3. The guardian is a lifecycle phase, not a co-tenant

A review/guardian agent on a branch is **not** a second card borrowing the tree. It is the
card's own **review phase**, in one of two shapes — both already approved designs, both 1:1:

- **(a) Same card continues** → [[pr-review-phase/index|pr-review-phase (axis 5)]]: the card enters
  a **review column** (a [[configurable-columns/index|configurable-columns]] instance with an
  `onEnter` policy); the agent — same card, same worktree — addresses PR comments/checks, pushes,
  loops. Optionally combined with a context handoff in *continue-same-card* mode.
- **(b) New card replaces it** → [[context-continuity/index|context-continuity (axis 6)]] in
  *new-linked-card* mode: the agent authors a handoff, a fresh card is `spawn`ed seeded with it.
  The new card resets **context**, not the **worktree** — it continues the *same* branch's work.

Neither is N:1. (a) is one card throughout. (b) is a **baton pass**: the successor inherits the
worktree, the predecessor retires — exactly **one live owner at every instant**.

## 4. Hand-off = worktree ownership transfer (not sharing)

(b)'s baton pass is the one genuinely new mechanic. Two ways, mapping onto §1:

- **Refcount way (rejected):** spawn successor on the same branch (momentary 2 cards on the tree),
  archive predecessor; refcount keeps the tree. Free today, but it's a *transient N:1* and relies
  on the guard we're retiring.
- **Transfer / commit-first respawn (chosen):** a review handoff happens **after a commit**, so:
  predecessor archives (branch kept, tree reclaimed), successor spawns on the now-existing branch
  and re-checks it out (`WorktreeManager.swift:36`). One owner at all times; no refcount. For a
  handoff with *uncommitted* state, add an explicit `handoff(X→Y)` that reassigns `cwd` ownership —
  still strictly 1:1.

**Principle:** *handoff carries intent; artifacts carry facts.* The committed code, the plan file,
and the card's `desc` are the durable state-of-record; the handoff payload only carries
"where I am / what's next / what I learned that isn't in the files." This keeps successive
handoffs from degrading into a telephone game.

## 5. End-to-end workflow this enables

1. **Stack of impl cards** — one card per branch, own worktree (1:1), spawned **off its parent**
   (§2 base-branch gap).
2. **Parent/stack metadata** — relative-diff review, restack order, board grouping (§2).
3. **Guardian = review column** the card moves into (§3a), optionally with a **context handoff**
   (§3b) to a fresh-context successor.
4. **Handoff = ownership transfer** via commit-first respawn or explicit transfer (§4) — all 1:1.

Nothing here needs concurrent N:1 worktree sharing.

## 6. What changes / retires

- **Retire:** archive refcount guard, `worktreeSiblings`, `SharedWorktreeBadge` + footer badge.
- **Add:** spawn `base` branch; `parentBranch`/`parentCardId`; spawn 1:1 gate (refuse+jump);
  worktree ownership transfer for handoff.
- **Keep:** PR2 `cwd`/`origin`; freeform/borrowed/scratch (the worktree-*optional* escape);
  PR1 read-only inspect shell.

## 7. Lifecycle & concurrency interactions (fork × handoff)

Once handoff and **forks** (linked child cards seeded via `additionalContext`, parent stays live,
merge-back via `send`) coexist, the dangerous case is: **a fork is in flight and its parent
handoffs before the fork concludes.** Root cause — every handoff kills the parent's tmux, and a
*transfer* handoff kills the whole card, while merge-back (`send → sessions.sendKeys`,
`SessionManager.swift:150`) **throws the instant the target session isn't alive** (no queue, no
retry).

| Fork Y in flight, parent X then… | Merge-back outcome | Severity |
|---|---|---|
| `move` (transition) | nothing — pure data; `id`/`cwd`/session unchanged | none (until `onEnter` exists) |
| continue-handoff (`restart X`) | tmux recreated, same name → `send` *succeeds* but lands on a **fresh-context X with no memory of forking Y** → orphaned message | medium |
| transfer-handoff (`archive X` + spawn Z) | `orchestra-<X.id>` killed → `send` **throws "session not alive"** → conclusion **lost** | high |
| manual `archive X` (`removeWorktree:true`) while a borrowed-RO fork reads `X.cwd` | tree removed **under** the fork (keep-tree check counts only `.worktree` siblings, not borrowers) | high |

Narrower gaps: `restart`'s `kill→ensure` window briefly fails `isAlive` (transient `send` throw even
for continue-handoff); `require` doesn't reject archived cards (double-handoff / resurrect-archived);
`recovering` prevents report-misattribution but does **not** serialize the operation (concurrent
restart races).

**Fix — merge-back targets the card *lineage*, not a live tmux session** (and rides the same
`additionalContext` seed channel):

1. **Durable, persisted merge-back inbox** (`Task.pendingContext: [String]`), injected as
   `additionalContext` on the card's next live turn ("a fork you launched concluded: …"). Kills the
   `isAlive` race **and** the continue-handoff amnesia. Must be persisted (survives daemon restart).
2. **Lineage pointer** `Task.succeededBy` set on transfer-handoff; merge-back to X reroutes to Z.
   Continue-handoff keeps the same `id`, so it just works.
3. **Forks-in-flight = durable inherited state** (reverse-lookup of live `parentCardId` children):
   continue-handoff's seed says "forks in flight: …, expect their conclusions"; transfer inherits them.
4. **Borrowed-fork tree safety:** accept that an ephemeral RO fork's *filesystem view* dies with the
   tree (consistent with PR1 inspect's "lives and dies with the tab"); its *conclusion* still survives
   via the inbox (#1).
5. **Guards:** `assertActive` (reject archived) on restart/handoff/transfer; serialize per-card
   handoff/restart on the `recovering` lock.

### 7.1 Why the lineage can die — and why the inbox is load-bearing

A dead lineage does **not** imply user intent. Three causes:

- **(A) Intentional user archive** — clean. Should still *warn* when live forks exist (informed intent),
  and on proceed the live forks are **promoted to standalone cards** (they keep their own session +
  `cwd`; merge-back then surfaces as an activity item) rather than dying with the parent.
- **(B) Voluntary agent self-archival** — a fork-aware agent shouldn't, but today that's convention,
  not enforcement (`archive` ignores children; `require` ignores `archived`). **Harden into a guard:**
  `archive` refuses / requires override when the card has live `parentCardId` children.
- **(C) Involuntary death** — `.dead` via recovery with no user/agent consent: `sessionVanished`
  (crash/OOM/sleep/tmux killed), `rebootUnrevived` (daemon restart, not resumable), context-overflow
  with no handoff. **Unpreventable** — does not pass through `archive()`.

(C) is why merge-back safety can't assume intent: the inbox **must be persisted** (a reboot is itself a
death cause), terminal surfacing of a conclusion into a dead lineage is **guaranteed to occur**, and a
fork orphaned by a dying parent should be **promoted to a standalone card** (it has its own session +
`cwd`) with an activity note — never cascade-killed. (A)+(B) are engineerable to "informed/blocked";
(C) must simply be tolerated.

## 8. Open items

- Spawn 1:1 enforcement: **refuse + jump** vs **auto-branch** (§1).
- Handoff with uncommitted state: explicit transfer op vs require-commit-first (§4).
- Does the review column reuse the existing `Column.review` case or a new configurable column?
- Relationship of *general* hand-off (any-time, context-bloat) to subagents and fan-out — see the
  separate hand-off exploration (TBD note).
- User archive with live forks: **hard-block + override** vs **warn-and-proceed** (§7.1 A/B).
- Orphan-fork policy on parent death: **promote to standalone card** (chosen) vs auto-archive (§7.1 C).
- Merge-back delivery: inject on the card's **next turn** vs interrupt the live agent immediately (§7.1).
