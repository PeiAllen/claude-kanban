---
project: claude-kanban
feature: freeform-and-borrowed-cards
type: design-spec
created: 2026-06-28
updated: 2026-06-29
related:
  - "[[../non-git-cards-search/index|non-git-cards-search (axis 4)]]"
  - "[[../configurable-columns/index|configurable-columns (axis 1)]]"
  - "[[../code-review-on-board/index|code-review-on-board (axis 7)]]"
  - "[[../stacked-branches-and-guardian-handoff|stacked-branches & guardian hand-off]]"
  - "[[../context-passing-topologies|context-passing topologies]]"
---

# Freeform, Borrowed & Read-only Cards — Design Spec

> Lets a card run somewhere **other than a freshly-cut git worktree**: in an existing checkout,
> an arbitrary directory, or a throwaway scratch dir — plus a read-only "Inspect" agent you launch
> in an existing card's shell. Deepens axis-4 ([[../non-git-cards-search/index|non-git-cards-search]])
> to implementation, and replaces the dangerous "two writers sharing one worktree" framing with a
> clean ownership model.

> **Status vs `main` (2026-06-29) — SHIPPED.** All four PRs landed (PR1 read-only inspect, PR2 `cwd`/
> `origin` schema, PR3 freeform/borrowed + `access`, PR4 scratch). This doc is now a *record* of a
> shipped feature, not a forward plan. **One section is now reversed:** §6 ("keep the refcount + badge,
> rescoped") was superseded on 2026-06-29 by the **enforced-1:1** decision in
> [[../stacked-branches-and-guardian-handoff|stacked-branches & guardian hand-off]] §1 — the refcount
> guard + `worktreeSiblings` + `SharedWorktreeBadge` + footer badge are now slated to be **retired**,
> not kept. The "future alternative (not now)" at the end of §6 became the chosen direction. The
> read-only recipe (§3) also shipped as **three** layers, not two (see the note in §3). Line numbers
> below are pre-PR and now stale; the authoritative current map lives in `docs/04-cards-worktrees-sessions.md`.

## 1. Why — the two real use cases

Both motivating cases are **non-conflicting by construction** — neither is two agents collaboratively
editing the same files (the footgun the original [[../../plans/intentionally-support-multiple-cards-iridescent-otter|multi-card plan]] tried to make safe):

1. **Ad-hoc task** — "launch an agent to fix my permissions / process some data," possibly not even
   in a git project. Distinct, independent jobs that may share a directory (e.g. several agents in `~`)
   but never touch each other's work. → **freeform cards.**
2. **Inspect/query** — "an agent is coding in a worktree and I want to understand the state of
   something there without spoiling its context," or "how does this repo do X on `main`?" Read-only,
   ephemeral, co-located with the thing it inspects. → a **read-only `claude` in that card's shell**
   (with no card overhead); or, when there is no owning card (a bare repo `main`), a **read-only
   freeform card.**

The unifying realization: the safe primitive is not "share a worktree + coordinate." It is **a card
that doesn't *own* the directory it runs in.** Ownership is the concept the model encodes.

## 2. The model

One run-directory field, one origin tag, one access mode. The `worktree` *string* is removed entirely
(its value is redundant — equal to `cwd`, and re-derivable from `repo + branch`).

```swift
// on Task
cwd:    String                              // the ONE path: where the agent + shells run (always set)
origin: .worktree | .scratch | .borrowed    // what kind of dir this is (subsumes isWorktree + ownership)
access: .readWrite | .readOnly              // default .readWrite
// repo / branch stay as-is (git cards; worktree path derives from them via Config.worktreePath)
```

| origin | cwd is… | who made it | archive does | board placement |
|--------|---------|-------------|--------------|-----------------|
| `.worktree` | `Config.worktreePath(repo,branch)` | Orchestra (`git worktree add`) | `git worktree remove` — **guarded** by sibling refcount + dirty-guard; keeps branch | workflow column (plan/impl/review) |
| `.scratch` | `~/.orchestra/scratch/<id>` | Orchestra (`mkdir`) | `rm -rf cwd` — **unconditional** (truly scratch) | freeform region |
| `.borrowed` | a dir the user chose | nobody / pre-existing | **nothing** — never delete | freeform region |

The run dir is just `cwd` (no `effectiveCwd` helper). `origin` is itself the card-kind
classification, so code switches on it directly — no separate `workdir`/`Workdir` type (that would
be an isomorphic restatement of `origin`). And the git tree path is just `cwd` too: for a `.worktree`
card `cwd` *is* the worktree root (set at spawn, never diverges), so the archive `remove` and the
sibling refcount use `t.cwd` directly — no `worktreePath` helper, no re-derivation from `repo+branch`
(which would even be *wrong* if a branch were ever renamed, while `cwd` stays correct).
`Config.worktreePath(repo,branch)` is still used at **spawn** to decide where to create the tree.

**Rule of thumb:** *Orchestra deletes only directories Orchestra made* (`.worktree`, `.scratch`);
borrowed dirs are never touched. `origin` makes illegal states (`owned=false & isWorktree=true`)
unrepresentable and, as an enum, forces the archive switch to handle the `.borrowed → don't delete` case.

### Why this schema (decision trail)

- **`cwd` total, not `cwd ?? worktree`.** Splitting the run dir across two fields forced an
  `effectiveCwd` helper and left a footgun (12 call sites read `t.worktree` and would silently break
  for freeform cards). With one total `cwd` there is no wrong field to read.
- **`worktree` string removed.** Of ~14 reads, 12 are "the run dir" (→ `cwd`); the 2 worktree-specific
  ones (sibling refcount, `worktrees.remove`) use `cwd` or re-derive `Config.worktreePath(repo,branch)`.
  The string carries zero unique information.
- **`origin` enum, not two bools.** The three card kinds are a 3-way choice; an enum beats
  `isWorktree: Bool` + `orchestraOwned: Bool` (which has an impossible 4th combo).

## 3. Mechanism A — read-only Inspect (no new card)

For "observe a worktree another card owns," do **not** create a card. Cards already have auxiliary
shell tabs (`Commands.swift` `shell`/`exec`/`closeShell`, `App/Views/ShellTabsView.swift`) that open
tmux windows already `cd`'d into the worktree. A **button on the inspector sidebar** opens such a shell
and launches a read-only `claude` in it.

**Read-only recipe (no plan mode):**

```
claude --session-id <id> \
  --disallowedTools "Edit" "Write" "MultiEdit" "NotebookEdit" \
  --settings <readonly.json>
```

`readonly.json`:
```json
{ "permissions": { "deny": ["Edit","Write","MultiEdit","NotebookEdit"] },
  "sandbox":     { "filesystem": { "denyWrite": ["<worktree>", "<repo>/.git/worktrees/<name>"] } } }
```

> **Shipped as THREE layers (2026-06-29), not two.** `ReadOnlyLaunch.swift` hardened this into defense
> in depth: (1) the tool denies below; (2) a **strict** sandbox — `denyWrite` *plus*
> `allowUnsandboxedCommands:false` + `failIfUnavailable:true`, so `dangerouslyDisableSandbox` is a no-op;
> (3) an **auto-mode classifier policy** (`autoMode.hard_deny:[<prose "deny any mutation" rule>]`) — a
> semantic mutation detector chosen over a brittle Bash deny-list. The two-lock framing below is the
> original design; the third (classifier) layer was added in commits `98c685d`/`5614c6d`.

- **Two independent locks.** `--disallowedTools` removes the edit tools from context (the model can't
  call what it doesn't have). The OS sandbox `denyWrite` blocks the Bash escape hatch (`sed -i`, `tee`,
  `>`, `python -c 'open(...,"w")'`) at the kernel — string-matching Bash deny patterns is whack-a-mole.
  Need both: the sandbox doesn't cover the Edit/Write tools; the tool denies don't cover Bash.
- **No plan mode.** `--permission-mode plan` forces a "produce a plan, approve to exit" framing and is
  escapable non-interactively. We want a normal conversational agent that simply can't write.
- **No Orchestra hooks.** The shell inherits `ORCHESTRA_TASK_ID`; if it ran with the orchestra
  `--settings` hooks file its tool events would be misattributed to the owner card (polluting its
  ctxPct/status). Launch plain so it stays invisible — correct for an untracked, ephemeral peek.
- **Tracking:** none. No status pill / recovery / board slot. It lives and dies with the shell tab; if
  the owner card is archived (worktree removed), the tab dies with it. That is the desired behavior.
- The `git` dir wrinkle: a worktree's git data lives in `<repo>/.git/worktrees/<name>/` (outside the
  worktree dir), so add it to `denyWrite` to make `git commit` a no-op too.

## 4. Mechanism B — freeform cards (borrowed + scratch)

A **tracked** card (real board citizen: status, recovery, report hooks) whose `cwd` is set and whose
`origin` is `.borrowed` or `.scratch`. Lives in a **standalone freeform region**, not the
plan/impl/review columns (those are owned-worktree *lifecycle stages*; freeform cards have no such
lifecycle).

### 4.1 cwd selection & trust

- **Free path under the sandbox (no allowlist).** The user picks/types any directory; the OS sandbox
  (already in auto-allow) confines writes to that dir + temp. Trust = the sandbox, not a pre-registered
  allowlist. This deliberately relaxes the `resolver.assertAllowed` gate that `repo` spawns enforce —
  freeform is meant to be friction-light, and the sandbox is the boundary everywhere else anyway.
- **Scratch convenience.** A "Scratch" choice creates a fresh `~/.orchestra/scratch/<id>` dir
  (parallel to `~/.orchestra/worktrees/`), sets `cwd`, `origin = .scratch`. No path picking; throwaway.

### 4.2 access (read-only freeform)

`access` defaults `.readWrite`. A `.readOnly` freeform card (the "inspect `main`, no owning card" case)
launches via the same read-only recipe as Mechanism A — but at the **adapter** level (the launch argv
in `ClaudeCodeAdapter.start/resume`), and it **keeps** the orchestra hooks (it *is* a tracked card, so
its reports are wanted). Reuse the `readonly.json` asset introduced in PR1.

### 4.3 lifecycle & archive

- **`.borrowed`** → archive deletes nothing.
- **`.scratch`** → archive `rm -rf cwd`, **unconditional** (no dirty-guard; the user moves out anything
  useful before finishing). No refcount — each scratch dir is per-`id`, never shared. The dangerous
  `rm` is gated on `origin == .scratch` (an explicit fact), with a defense-in-depth `assert` that the
  path is under the scratch root.
- **Orphan sweep:** on daemon start, remove `~/.orchestra/scratch/<id>` dirs with no matching live card
  (covers a scratch card that died without a clean archive).

### 4.4 board region

Standalone region, **independent of axis-1 (configurable columns).** Freeform cards are a card
*category*, not a workflow stage; routing them through user-configurable columns would conflate the two
and chain this work to a much larger feature. If user-defined columns later land, the freeform region
stays its own thing. (Soft exception: only pay the axis-1 dependency if the region must be
reorderable/collapsible *exactly* like columns — not worth it now.)

## 5. Archive / ownership logic (the one real behavior change)

Generalize the current `archive` block (shipped at `OrchestraService.swift:194-229`, was an unconditional
`worktrees.remove`) into a switch on `origin`:

```swift
if removeWorktree {                              // existing param now gates ALL workdir reclaim
  switch t.origin {
  case .worktree:
    let siblings = await store.all().filter {    // co-located .worktree cards share a tree
      $0.id != id && !$0.archived && $0.origin == .worktree && $0.cwd == t.cwd
    }
    if siblings.isEmpty {
      do { try worktrees.remove(worktree: t.cwd, force: false) }   // cwd == worktree root
      catch OrchestraError.worktreeDirty { /* keep dirty tree */ }
    }
  case .scratch:
    assert(t.cwd.hasPrefix(Config.scratchRoot + "/"))   // never rm -rf outside the scratch root
    try? FileManager.default.removeItem(atPath: t.cwd)
  case .borrowed:
    break
  }
}
```

## 6. Multi-card-per-worktree refcount + badge — ~~keep, rescoped~~ **NOW SLATED TO RETIRE (2026-06-29)**

> **Superseded.** This section's original conclusion — *keep* the refcount guard + `SharedWorktreeBadge`,
> rescoped to `.worktree` — was reversed on 2026-06-29 by the **enforced-1:1** decision in
> [[../stacked-branches-and-guardian-handoff|stacked-branches & guardian hand-off]] §1. The "future
> alternative (not now)" at the bottom of this section became the chosen direction. Kept below for the
> decision trail; the current target is the *retire* path.

What shipped (refcount guard + `worktreeSiblings`/`worktreeSiblingsHelp` + `SharedWorktreeBadge` +
`SharedWorktreeList` + footer count badge) was the *make-N:1-safe* machinery. The reversal's reasoning:
**git forbids the same branch in two worktrees**, so every N:1 case is two writers on one branch — a
footgun with no safe form. The safe co-location patterns we actually want (read-only Inspect §3,
freeform/borrowed §4) **don't share a worktree at all**, so once spawn enforces 1:1 (refuse-and-jump, or
auto-branch — open) the entire refcount/badge layer has nothing left to babysit and should be removed.

- **Refcount guard** (`OrchestraService.swift:200-210`) → **retire**; with 1:1 enforced, a `.worktree`
  card is always the sole owner, so archive removes its tree unconditionally (still dirty-guarded).
- **Badge + siblings helpers** (`BoardModel.swift:72-83`, `InspectorView.swift:251-313`,
  `CardView.swift:148-158`) → **retire**; there are no co-located worktree cards to surface.
- **Keep regardless (unrelated to worktree sharing):** the no-prompt lifecycle fixes that rode in with
  the same plan — spawn `.waiting` for provisional cards; restart-fresh recovery for never-prompted
  cards (`Recovery.swift:22-25`). These stay.

**Original (now-superseded) conclusion**, for the record: *keep both, rescoped to `.worktree`, because
the system still permits incidental N:1 via the idempotent `worktrees.ensure`.* The 1:1-enforcement
decision closes that incidental path at spawn, which is what makes retirement safe.

## 7. Call-site reroute (the `worktree` → `cwd` plumbing, PR2) — ✅ shipped

> Completed in PR2; the line numbers below are the pre-PR map and are now stale. Every run-dir read
> routes through `Task.cwd` in current `main`.

Run-dir reads → `t.cwd`:
- `OrchestraService.openShell` `:180` (`newShellWindow(cwd:)`), `:181`
- `OrchestraService.exec` `:191-192` (`assertAllowed` relaxes for non-`.worktree`; `Proc.run(cwd:)`)
- `OrchestraService` AdapterContext `:203`; Recovery `:62 / :111 / :155`
- `SessionManager.ensure` tmux `-c` `:55`
- `CardSessions` `:208`; `CLIRunner` print `:115`
- `InspectorView` breadcrumb `:284` / copy `:345`; `RecoveryView` `:43 / :56 / :58`

Worktree-specific (also `cwd`, since `cwd` == worktree root for `.worktree` cards):
- archive refcount `:160`; `BoardModel.worktreeSiblings` `:65`; `worktrees.remove` (archive)

Migration: `init(from:)` backfills `cwd = worktree`, `origin = .worktree` for existing persisted cards.

## 8. PR / branching plan — ✅ all four shipped

> PR1–PR4 all landed on `main` (2026-06-29). The stack below is the historical build order; see
> `docs/09-design-decisions.md` for the shipped-PR summary table.

```
main ─┬─ PR1  read-only-inspect        (independent; no schema change)
      └─ PR2  schema-cwd-origin         (independent base; behavior-neutral refactor)
              └─ PR3  freeform-cards     (needs PR2: .borrowed + region + access)
                      └─ PR4  scratch-cards   (needs PR3: .scratch lifecycle)
```

| PR | Scope | Depends on | Notes |
|----|-------|-----------|-------|
| **1** | Read-only `claude` + inspector "Inspect" button launching it in a card shell. Drop the reusable `readonly.json` asset. | — | No `Task` change. High value, self-contained. |
| **2** | `Task`: add `cwd` (total) + `origin` (define all 3 cases, construct only `.worktree`); remove `worktree` string; reroute §7 call sites; migration; fold refcount into the archive switch. | — | **Pure refactor — behavior unchanged.** Verify by "all existing tests pass." `access` NOT here. |
| **3** | Freeform cards (`.borrowed`): free-path spawn under sandbox; standalone freeform region; `access` field + read-only borrowed launch (adapter-level, keeps hooks); rescope badge to `.worktree`. | PR2 | Independently useful (Case 1 + Case 2b). Region is **not** axis-1-dependent. |
| **4** | Scratch cards (`.scratch`): "Scratch" spawn option; create `~/.orchestra/scratch/<id>`; unconditional `rm -rf` on archive; startup orphan sweep. | PR3 | Smallest increment. |

**Flow:** PR1 + PR2 off `main` (either order, no shared code). PR3 off `main` after PR2 merges; PR4
off `main` after PR3. Merge-then-branch keeps diffs small. (Stack `PR2 ← PR3 ← PR4` only if developing
3/4 before 2 lands.)

## 9. Non-goals / open items

- **No coordination/locking** between agents sharing a dir — stays the user's responsibility (sandbox
  confines writes; that's the only guarantee). *(Note: under enforced 1:1, the only `cwd`-sharing left
  is borrowed/scratch cards intentionally co-located in a free dir — never two `.worktree` cards.)*
- **No axis-1 (configurable columns) work** here; freeform region is standalone.
- **Resolved (shipped):** the freeform region landed as a **resizable, collapsible docked bottom panel**
  (`BoardView.FreeformRegionView`), full board width, adaptive card grid.
- **Still open:** whether the read-only Inspect button also offers a writable "Shell here" variant;
  final glyphs for the freeform/borrowed/read-only card states.
