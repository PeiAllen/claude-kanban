# Support multiple cards (agents) on the same worktree

## Context

Orchestra intentionally allows more than one card/agent to run against the same git
worktree (same `repo + branch`). This is already *mostly* supported because the whole
system is keyed by `Task.id` (UUID), not by worktree path: tmux sessions are
`orchestra-<id>`, status reports route via `ORCHESTRA_TASK_ID`, recovery uses a
per-card `recovering: Set<UUID>`, and all app/UI state (`selectedId`, shell state) is
UUID-keyed. `WorktreeManager.ensure` is idempotent — if the worktree dir already exists
it returns early (`WorktreeManager.swift:26-28`), so a second card with the same
repo+branch silently **reuses** the existing worktree rather than erroring.

There is **one** place where multi-card-per-worktree state goes wrong, plus a usability
gap:

1. **Bug — archive deletes a shared worktree.** `OrchestraService.archive`
   (`OrchestraService.swift:148-152`) calls `worktrees.remove(t.worktree)`
   unconditionally, deleting the entire worktree directory. If a sibling card still runs
   on that worktree, archiving the first card pulls the filesystem out from under the
   second (breaks its `exec`/`shell`/terminal). This is the only state-handling hazard.

2. **Usability — no signal that cards share a worktree.** The user is responsible for
   ensuring co-located agents don't clobber each other's work, so they need to *see* when
   a worktree is shared and jump between the co-located cards.

We are **not** adding coordination/locking between co-located agents — that stays the
user's responsibility, per the feature intent. We only (a) make state handling safe and
(b) add a passive indicator.

**Related regression (merged from `main`, commit a4eb971 "optional initial prompt").**
That commit lets a card spawn with **no initial prompt** (drop into the agent, name it off
the first prompt). Two issues fall out of it, independent of the indicator work but worth
fixing in the same pass:

- A never-prompted card has **no transcript on disk** (`~/.claude/projects/<cwd-slug>/<sid>.jsonl`
  is not written until the first turn), so `isResumable` (`OrchestraService+Recovery.swift:147`)
  returns `false`. On daemon restart/reboot, `recoverSessions` then marks it `.dead`
  (`rebootUnrevived`) — the just-opened card you stepped away from becomes a dead card.
- It is created `status: .running` (`OrchestraService.swift:83`) while actually idle awaiting
  input; it should spawn `.waiting`.

The multi-card story itself is unaffected by the no-prompt change: each card keeps a unique
`agentSessionId`, reports route by `ORCHESTRA_TASK_ID`, and co-located cards write distinct
`<sid>.jsonl` files into the shared cwd-slug dir, so resume stays correct. The only
worktree-shared resolver, `ClaudeCodeAdapter.discover(cwd:)` (newest `.jsonl` by mtime), is
ambiguous across co-located cards but is only a fallback for a `nil` `agentSessionId`, which
orchestra-spawned cards never have — add a clarifying comment, no behavior change.

## Scope decisions (confirmed with user)

- Indicator appears **both** in the card's inspector sidebar **and** as a small count
  badge on the board card.
- "Other agents on the same worktree" = **all other non-archived cards** sharing the
  same `worktree` path (any status: running/waiting/done/dead), which mirrors the archive
  refcount guard exactly.

## Non-goals / accepted behavior

- **Duplicate card titles are fine.** Two no-prompt cards on the same branch share the
  branch-name placeholder title until a first prompt re-titles them. Nothing keys off the
  title (tmux session, Claude `--session-id`, and task id are all UUID-unique; `ref`
  resolves by `shortId`), so this is purely cosmetic. The shared-worktree indicator's hover
  (sibling `shortId` + title) is the intended disambiguator — do **not** auto-number or
  inject ids into the title.

## Change 1 — State safety: refcount the worktree on archive

File: `Sources/OrchestraCore/OrchestraService.swift`, `archive(_:source:removeWorktree:)`
(~lines 145-157).

Only remove the worktree when **no other non-archived card** references the same
worktree path. Replace the `if removeWorktree { … }` block with:

```swift
if removeWorktree {
    let others = await store.all().filter {
        $0.id != id && !$0.archived && $0.worktree == t.worktree
    }
    if others.isEmpty {
        // Keep the branch; never silently delete a dirty tree — keep the dir if dirty.
        do { try worktrees.remove(worktree: t.worktree, force: false) }
        catch OrchestraError.worktreeDirty { /* keep the worktree on archive */ }
    }
    // else: a sibling card still lives on this worktree — leave it in place.
}
```

Notes:
- `archive` is the **only** caller of `worktrees.remove` — confirm with
  `grep -rn "worktrees.remove\|\.remove(worktree" Sources` during implementation; no other
  recovery/restart path removes worktrees.
- The branch is always kept (existing behavior), so leaving the dir in place is consistent.
- No new persisted state needed — the refcount is derived live from `store.all()`.

## Change 2 — Shared-worktree helper on BoardModel

File: `App/BoardModel.swift`. Add one derivation so both the card and inspector compute
siblings identically (avoid duplicating the filter):

```swift
/// Other non-archived cards that share this card's worktree (any status). The user is
/// responsible for keeping co-located agents from clobbering each other; this just
/// surfaces them. Sorted oldest-first for a stable list.
func worktreeSiblings(of task: Task) -> [Task] {
    tasks.filter { $0.worktree == task.worktree && $0.id != task.id }
         .sorted { $0.createdAt < $1.createdAt }
}
```

(`tasks` already excludes archived cards.)

## Change 3 — Inspector sidebar badge

File: `App/Views/InspectorView.swift`, inside `TerminalHeader` (~lines 157-187). After
`Text(task.branch)` and before `Spacer`, insert the badge (only when siblings exist):

- New `private struct SharedWorktreeBadge: View` taking `let task: Task`, with
  `@EnvironmentObject var model` + `@Environment(\.theme)` and `@State private var showList = false`.
- Renders nothing when `model.worktreeSiblings(of: task).isEmpty`.
- Otherwise a small chip styled like the existing repo/branch chips
  (`theme.chip`, `RoundedRectangle(cornerRadius: 5)`, `F.mono`): a glyph
  (`Image(systemName: "arrow.triangle.branch")` or `person.2.fill`) + the sibling count.
- `.help(...)` with the hover summary — one line per sibling: `"<shortId>  <title>"` (reuse
  `Task.shortId`), e.g. `"Also on this worktree:\na1b2c3  Fix parser\nd4e5f6  Add tests"`.
- Wrap as a `Button { showList.toggle() }` with `.popover(isPresented: $showList, arrowEdge: .bottom)`
  showing a small list (pattern: `ActivityPopover.swift:65-67` / `DonePopover.swift:27-32`):
  each sibling is a row `Button { model.selectedId = sib.id; showList = false }` showing a
  status dot + `shortId` + title. Clicking opens that sibling's inspector (selection drives
  the inspector via `model.selected`).

`TerminalHeader` must become an `@EnvironmentObject var model: BoardModel` consumer (it
currently only takes `theme` + `task`) so the badge can read siblings; it's already inside
the inspector hierarchy where `BoardModel` is in the environment.

## Change 4 — Board card count badge

File: `App/Views/CardView.swift`, in the `footer` (~lines 116-128, repo · branch row).
Add a tiny trailing badge when `model.worktreeSiblings(of: task)` is non-empty:

- Reuse the same glyph + count, sized to match the footer (`F.mono(10.5)`, `theme.text3`).
- Place at the trailing edge of the footer row (alongside / near the model name). Keep it
  passive on the card — `.help(...)` with the same sibling summary is enough; the
  click-to-jump interaction lives in the inspector badge (the board card already selects
  itself on tap). `CardView` already has `@EnvironmentObject var model`.

## Change 5 — No-prompt card spawns `.waiting`, not `.running`

File: `Sources/OrchestraCore/OrchestraService.swift`, `spawn` (~line 79-85). The card is
created `status: .running` unconditionally; for a no-prompt card it's idle awaiting the
first user prompt, so:

```swift
status: provisional ? .waiting : .running,
```

(`provisional` is already computed just above for the title.) A real-prompt card keeps
`.running`. When the user types their first prompt, `report` already flips `.waiting →
.running` (`OrchestraService+Report.swift:55-56`).

## Change 6 — Recovery: never-prompted card restarts fresh instead of dying

File: `Sources/OrchestraCore/OrchestraService+Recovery.swift`, `recoverSessions` (~lines
16-23). A never-prompted card has no transcript, so `isResumable` is `false` and it's
currently marked `.dead`. Instead, restart it fresh (new blank session, `.waiting`):

```swift
for t in tasks {
    if aliveNames.contains(sessions.sessionName(t.id)) { continue }
    if isResumable(t) {
        toRevive.append(t.id)
    } else if t.titleProvisional {
        // Never-prompted (or freshly restarted/cleared) — no current-session work to lose.
        // Relaunch a blank session rather than killing the card.
        toRestart.append(t.id)
    } else {
        await markDead(t.id, reason: .rebootUnrevived, detail: nil, source: .daemon)
    }
}
```

Discriminator rationale: `titleProvisional` is the "no real prompt has landed in the
current session" flag — set at spawn for no-prompt cards and by `restart`/`/clear`, and
cleared permanently by the first user prompt (`Report.swift:51-53`). A card that *was*
worked on but whose transcript is gone has `titleProvisional == false`, so it still
correctly falls to `markDead` (matches the chosen behavior).

Process `toRestart` through the same windowed task group that paces `toRevive`, calling
`restart(id, source: .daemon)` (`:94`) instead of `resume`. Generalize the existing
iterator-of-ids loop (`:30-38`) to an array of async thunks `[() async -> Void]` so both
resume and restart share the concurrency cap (`config.maxConcurrentRevivals`).

Also add a one-line comment at `ClaudeCodeAdapter.discover(cwd:)` (`:108`) noting it is
ambiguous when multiple cards share a worktree and is therefore only safe as the
`agentSessionId == nil` fallback (orchestra-spawned cards always have a tracked id).

## Critical files

- `Sources/OrchestraCore/OrchestraService.swift` — archive refcount (Change 1) + no-prompt
  spawn status (Change 5)
- `App/BoardModel.swift` — `worktreeSiblings(of:)` helper (Change 2)
- `App/Views/InspectorView.swift` — `SharedWorktreeBadge` + `TerminalHeader` wiring (Change 3)
- `App/Views/CardView.swift` — footer count badge (Change 4)
- `Sources/OrchestraCore/OrchestraService+Recovery.swift` — restart-fresh for never-prompted
  cards (Change 6)
- `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift` — clarifying comment on `discover` (Change 6)

Reused patterns: chip styling in `TerminalHeader`/`InspectorView.swift`; popover +
tap-to-select in `ActivityPopover.swift` / `DonePopover.swift`; `Task.shortId` for ids;
`.help()` tooltips (e.g. `ToolbarView.swift:118`).

## Verification

State safety (core library — covered by SwiftPM, no Xcode needed):
1. Add/extend a unit test for `archive`: create two `Task`s with the **same** `worktree`,
   archive one, assert the worktree dir is **not** removed and the sibling still resolves;
   archive the second, assert the worktree **is** removed (refcount falls to zero). Use the
   existing `WorktreeManaging` test double / mock if present (check
   `Tests/OrchestraCoreTests` for an existing fake worktree manager) so no real git runs.
2. No-prompt lifecycle unit tests (use the existing `SessionManaging`/`WorktreeManaging`
   test doubles so nothing real launches):
   - `spawn` with an empty prompt → card is `titleProvisional == true` **and** `status ==
     .waiting`; with a real prompt → `.running`.
   - `recoverSessions` with a `titleProvisional` card whose tmux session is dead and which
     has no transcript → it is **restarted** (fresh `agentSessionId`, `status == .waiting`),
     not `.dead`. A non-provisional card with no transcript → still `.dead`.
   - First-prompt empirical check (manual, confirms the premise): spawn a no-prompt card,
     then before typing verify `~/.claude/projects/<cwd-slug>/<sid>.jsonl` does **not** yet
     exist; type a prompt and verify it appears. (If it already exists pre-prompt, Change 6
     is harmless but the regression it fixes wouldn't trigger.)
3. `swift build && swift test` (per the Orchestra build env: package builds offline).

UI (macOS app — requires Xcode build per `scripts/build-app.sh`):
4. Build + launch the app (background driving / screenshot-by-window-id per project memory).
5. Spawn two cards on the same `repo + branch` (the second reuses the worktree). Confirm:
   both cards show the count badge in the footer; opening either card's inspector shows the
   shared-worktree badge; hover shows the other card's shortId + title; clicking a row in
   the popover switches the inspector to the sibling.
6. Archive one of the two co-located cards; confirm the other card's terminal/exec still
   works (worktree dir intact) and its badge count drops to zero (badge disappears).
7. Archive the last card on that worktree; confirm the worktree directory is removed as
   before (unless dirty).
