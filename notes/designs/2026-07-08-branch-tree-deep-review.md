---
project: claude-kanban
type: deep-review
subject: branch-tree feature (`plan/parent-card-branch-linking`, BT1–BT7)
base: mobile-impl-orchestration
created: 2026-07-08
reviewer: card d56eb1 (Fable), 6 dimension subagents + fixture verification in ./.scratch
---

# Branch-tree deep review — 2026-07-08

Scope: everything `plan/parent-card-branch-linking` adds over `mobile-impl-orchestration`
(~11k lines: BT1 lineage core, BT2 spawn-with-base, BT3 parent-relative diffs, BT4
TreeStat+nudges+synced, BT5 ship choreography+TreeDocs, BT6 remote tier, BT7 board tree UI, plus
the four-layer design set). Method: six parallel review passes (architecture, three correctness
slices, user-facing behavior, quality/tests/docs/perf), each finding verified against code and —
where git behavior was the question — proven with throwaway git fixtures. The full test suite was
run in this worktree: **631 tests / 126 suites, 0 failures** (both usually-flaky real-tmux suites
passed this run). Findings below are only those that survived verification; file:line references
are to this branch's HEAD (`08bfdf9`).

---

## (a) Executive verdict: **ship-with-fixes** — one focused fix round, then merge

The load-bearing skeleton is right and verified: git-config as lineage SSOT, the derived (never
stored) parent card, tree-not-DAG, and the merge-down / `rebase --onto` / squash-at-ship git model
all held up under adversarial fixture testing — including the subtle case the whole design hinges
on (the recorded-base anchor transplanting only the child's commits across a squash-merge, even
with a stale anchor). The daemon provably never mutates refs. The test suite is genuinely good
(real git fixtures, no mocking) and fully green.

But the branch is not mergeable as-is. Two subsystems have confirmed end-to-end breaks:

1. **The remote tier's status half doesn't work.** TreeStat and `synced` never learned the
   canonical→resolvable ref mapping that the diff consumers got, so every `pr#N`-parent card
   flips to a false red "restack" badge on its first activity and `orchestra synced` errors
   unrecoverably. The watch loop's own "stale badge tracks the fetched tip" contract can't
   materialize. (S1-1.)
2. **The ship choreography drops both endgames.** A shipped child under a live parent is never
   told its merge landed (zombie card forever), and a *root* card shipping to main never
   retargets its children at all — the headline goal-4 scenario. (S1-2, S1-3.) Codex agents
   additionally still have an unconditional merge-to-main `/ship` recipe (S1-4).

All of these are cheap to fix relative to the branch (a resolver call, an extra nudge, an
unconditional retarget with a fallback, one AGENTS.md edit) — none requires rearchitecting.
The one systemic *design* weakness worth acting on while this is a draft: the daemon trusts
agent reports (`synced`, `shipped`) verbatim where one-line git checks could verify them —
see the overhaul section.

---

## (b) Findings, ranked

Severity: **S1** breaks a shipped flow for a normal user · **S2** wrong/lossy behavior on a
plausible path · **S3** confusing, noisy, or latent · **S4** polish/debt. Every finding is
confirmed in code (and by fixture where marked) unless labeled *plausible*.

### S1-1 · Remote parents are never resolved by TreeStat/`synced` — false restack badge, broken `synced` (fixture-confirmed)

`Sources/OrchestraCore/OrchestraService+Tree.swift:317` (`computeTreeStat` → `treeTip(repo:,
link.parent)`) and `:128` (`synced`) pass the *canonical* lineage string straight to
`git rev-parse --verify --quiet`. The mapping seam exists — `resolvedParentRef`
(`OrchestraService+ParentRef.swift:11`) maps `pr#N`/`origin/b` → `refs/orch/parents/…` — but only
the four diff consumers use it.

- **`pr#N` parents:** `rev-parse "pr#7"` fails (fixture-verified) → `computeTreeStat` returns
  `restackNeeded` and **drops `parentIsRemote`**. The hand-set `inSync` from
  spawn/`set-parent` (`+Tree.swift:33`) survives only until the card's first report: the funnel
  (`OrchestraService+Report.swift:141`) schedules a recompute ~750 ms later. `remoteMergeStep`
  even schedules the recompute itself after a fetch (`+Remote.swift:37`, comment: "stale badge
  tracks it") — it cannot. `orchestra synced` on such a card always throws
  `parent ref not found: pr#7` (`+Tree.swift:128-130`), yet tree-skill.md tells the agent to run
  exactly that; the skill's sync step `git merge <parent>` is equally unrunnable for `pr#N`.
- **`origin/<b>` parents:** `rev-parse origin/b` resolves the *remote-tracking* ref, not the
  private ref. Fixture-verified nuance: the private-ref fetch **opportunistically updates**
  `refs/remotes/origin/<b>` in a default clone, so the two usually agree — this accident is the
  only reason the `origin/…` tier works at all. It breaks in a single-branch clone / non-default
  `remote.origin.fetch`, and any user-initiated `git fetch` advances the tracking ref
  independently of the private ref, desynchronizing TreeStat from the diff baseline.

No test recomputes TreeStat (or calls `synced`) on a remote-parent card — the exact missing case.

**Fix:** in `computeTreeStat`/`synced`, resolve via `RemoteParentRef.parse(link.parent)?.privateRef
?? "refs/heads/\(link.parent)"`, and set `parentIsRemote: RemoteParentRef.parse(…) != nil` on
every constructed TreeStat. Add remote-parent recompute + synced tests. (See overhaul O1 for the
structural version.)

### S1-2 · Root ship orphans its children — the goal-4 headline scenario doesn't work

`shipped` runs its retarget step only `if let grandparent` (`+Tree.swift:174`), i.e. only when the
shipped card *itself* has a parent link — and the main-path `/ship` never calls `shipped` at all
(`.claude/commands/ship.md` step 2: "Parent is `main` → continue with the standard main flow";
`tree-skill.md:34`: "Do not call `orchestra shipped`").

**Scenario:** `main → A → B`, A ships to main via the standard flow. Nothing retargets B: B's
lineage still names `A`, whose local branch still exists with an unchanged tip equal to B's
recorded base → `computeTreeStat` reports **inSync forever**. B never gets a restack nudge, and
B's own later `/ship` squash-merges into the dead branch `A`. 01-design.md:133 promises exactly
this case ("a parent shipping to main is the same flow with grandparent = main").

**Fix:** make the retarget unconditional with `grandparent = link?.parent ?? defaultBranch(repo)`
— or, when the fallthrough is the default branch, *clear* the children's links (they become plain
main-based cards, which is the truth). Have ship.md/tree-skill's main path call `orchestra
shipped` whenever `orchestra tree` shows children, and stop `shipped` warning "no recorded parent
link" as if it were an anomaly.

### S1-3 · Live-parent ship strands the child card — nobody ever tells it the merge landed

`tree-skill.md:32` / ship.md tell the child: send the merge-request, then **stop**. The parent's
agent squash-merges and calls `shipped <child>`. `shipped` (`+Tree.swift:149-215`) then (a)
notifies the **parent** — which just performed the merge itself, a wasted wake to read about its
own action — (b) nudges grandchildren, (c) silently clears the child's lineage. **No enqueue or
wake ever reaches the child**, a stopped agent that cannot see the `taskUpserted` event. Its
chip/badge vanish and the card sits live-looking in its column forever; tree-skill.md:40's "you
then archive as usual" is unreachable. Every live-parent ship produces a zombie card.

**Fix:** add step (d): `inbox.enqueue(child.id, "your branch landed in <parent> — verify and
archive yourself")` + `wake(child.id)`; skip the parent echo when the `shipped` caller *is* the
parent card. Consider surfacing a "merge pending/landed" state on the child while it waits —
`TreeState.parentMerged` already exists, unused (S4-3, overhaul O2).

### S1-4 · Codex never got the tree-aware ship — it merges stacked children straight to main

`.claude/commands/ship.md` gained the resolve-the-parent step, but the repo-root `AGENTS.md`
(Codex's `/ship` recipe, per its own header) still says unconditionally "**Merge to main**". A
Codex agent on a stacked child follows the explicit recipe and merges the child — including all
inherited parent commits — to main: precisely the failure the feature exists to prevent, and a
direct violation of the project's "must work for both Claude and Codex" rule on the
highest-stakes flow. (The `CODEX_HOME/AGENTS.md` tree *section* says the opposite, so the two
Codex-visible instructions also contradict each other.)

**Fix:** mirror ship.md's step 2 into repo-root `AGENTS.md`.

### S1-5 · Synchronous `gh` network calls block the entire daemon actor (up to 20 s/tick, 40 s on redirect)

`Proc.run` blocks the calling thread on a semaphore (`Proc.swift:74-84`). `GhProbe` is a plain
struct, so `gh.prState` (`+Remote.swift:41`) and `gh.prNumber`/`editBase` (`:102-103`) execute
*inside the `OrchestraService` actor* — every RPC (list/spawn/send/inspector) stalls for the
duration of a `gh` network round-trip, up to the 20 s timeout, recurring per watched-PR-card tick
(tier (a) must run every tick since `refs/pull/N/head` doesn't move on merge). The asymmetry is
telling: `ls-remote`/`fetch` were deliberately isolated on the `RemoteParents` actor; `GhProbe`
wasn't. Also, `gh pr view` runs even when `ls-remote` showed no movement — gating it on
`moved || tip == .gone` halves the network traffic.

**Fix:** make `GhClient` async and hop off the service actor (own actor, or ride `RemoteParents`).

### S2-1 · `synced` records an unverified claim — the stale signal silently corrupts

`synced` (`+Tree.swift:120-135`) sets the recorded base to the parent's tip *at report time*, with
no check the child actually contains it. (i) Parent advances between the agent's merge and its
`synced` call → base over-records → card shows `inSync` while parent work is missing, and because
the stale nudge is edge-triggered (`inSync→stale` only), the miss is silent until the parent moves
*again*. (ii) An agent that runs `synced` without merging zeroes the badge outright.
Fixture-verified that the *restack anchor* tolerates over-recording (rebase `--onto` still
excludes parent commits) — this corrupts the signal, not the surgery; but the signal is the
feature's core loop.

**Fix (one line, removes the trust dependency):** record
`merge-base(child-HEAD, resolved-parent-ref)` instead of the parent tip. After an honest
merge-down it equals the merged tip; after a racy or bogus call it equals the true sync point.

### S2-2 · `shipped` verifies nothing — an erroneous call rewires lineage toward data loss

Any agent can call `shipped <child>` (exposure `.all`). If the squash-merge never actually
happened (parent agent hit conflicts and aborted, then called it anyway; or a confused agent), the
daemon still retargets all grandchildren onto the grandparent and nudges each to
`rebase --onto <grandparent> <recorded-base>` — which (fixture-proven) **drops everything below
the recorded base** from their branches. That is only safe when the content landed in the
grandparent via the squash. The child's lineage is also cleared, destroying the state needed to
reconstruct.

**Fix:** cheap sanity gate before retargeting: refuse (or demand `--force`) when the parent tip
hasn't advanced past the child's recorded base (`rev-list --count base..parentTip == 0` ⇒ nothing
was merged since the last sync). Not airtight against all misuse, but it catches the
"called without merging at all" class. (Overhaul O2 for the fuller shape.)

### S2-3 · Spawn lineage failures fire *after* the worktree is cut: orphan worktree, then the retry silently drops the base

Two confirmed triggers, one shared failure shape. (i) `WorktreeManager.ensure` accepts any
`refs/`-prefixed base verbatim (`WorktreeManager.swift:44-50` — needed for
`refs/orch/parents/…`), but `recordSpawnBase` then resolves `refs/heads/\(base)`
(`+Tree.swift:90`) → `refs/heads/refs/heads/foo` → throws. (ii) **Dangling-value cycle-guard
false positive** (fixture-proven): `git branch -D feat-x` removes `feat-x`'s own config section
but leaves other branches' `orchestra-parent = feat-x` *values* dangling; reuse the name — spawn
`feat-x` with `base: feat-x-fix` (a former child) — and the cycle guard walks the dangling chain
and throws "would create a cycle" (`BranchLineage.swift:71`).

Both throw **after the worktree and branch were created** (`OrchestraService.swift:273→288`): the
failed spawn leaves an orphan worktree + branch and no card, and a retried spawn hits `ensure`'s
`fileExists` fast path → `branchExisted=true` → the base is *silently ignored*, spawning with no
parent link (or, in case ii, whatever stale config the reused name inherits).

**Fix:** normalize/validate `base` in `spawn` *before* `ensure` (strip or reject user-supplied
`refs/…`); in the cycle-guard walk, treat a link whose parent branch no longer exists as dangling
(ignore or prune) instead of extending the chain; on lineage-record failure roll back the
just-created worktree (+ branch when this spawn created it).

### S2-4 · The recorded rebase anchor is not recoverable as documented — `TreeNode` has no `base`

`tree-skill.md:8,24,47` / `tree-agents.md:3,19` say the anchor is "in the nudge, and in
`orchestra tree`". `TreeNode` (`OrchestraKit/Model.swift:411-426`) carries no base field, so
`orchestra tree` omits it. The nudge does inline the OID (good), but nudges are ephemeral: inbox
drained, session restarted — or, worse, the grandchild retargeted by `shipped` while it had **no
live card** (config-write only, no nudge possible); a card later spawned onto that branch sees
`restackNeeded` and a documented recovery path that dead-ends. The real fallback
(`git config --get branch.<b>.orchestra-parent-base`) is documented nowhere.

**Fix:** add `base: String?` to `TreeNode` (from `ParentLink.base` — already read at that call
site) and render it in the CLI output. Cheap, and it makes the docs true.

### S2-5 · Merge-request choreography has no failure path and no daemon-visible state

Nothing records that a merge was requested: no pending badge on either card, no dedup on
re-send, no re-nudge if the parent agent ignores it, no timeout. If the parent card **archives**
between request and merge, the message rots in an archived inbox; the parent branch is now bare
(the borrow path would apply) but the stopped child is never told to re-evaluate. `archive` is
not tree-aware (`OrchestraService.swift:574-609`).

**Fix (minimal):** on archive of a worktree card, nudge live children of its branch ("parent card
archived — parent branch is now bare; re-run your ship"). **Fix (structural):** overhaul O2.

### S2-6 · 1:1 card↔branch is assumed by every derived lookup, enforced nowhere

Every parent-card lookup is `active.first(where: repo+branch)` (`+Tree.swift:160,194,233,306`;
`BoardTree.swift:15,69`) — and the codebase still permits multiple live cards on one branch
(`BoardStore.worktreeSiblings` exists to *badge* that state). Under N:1: `shipped` notifies an
arbitrary sibling, `tree`'s `parentCardId` is arbitrary, board indentation picks an arbitrary
parent. 01-design.md:105-107 explicitly promises spawn-time refusal ("spawning onto a branch that
has a live card refuses with jump-to-card") — not implemented in this diff. (Known related work:
the enforced-1:1 design in `worktree-coupling-and-context-passing-design` — but this branch's
correctness shouldn't wait on it.)

**Fix:** add the ~5-line spawn refusal (archived cards don't count), or at minimum make lookups
deterministic (oldest active) + warn on multiplicity.

### S2-7 · `set-parent` adopt and clear leave a stale badge; adopt leaves a lingering remote watch

The local-adopt arm (`+Tree.swift:66-71`) updates lineage + `parentBranch` but neither recomputes
nor clears `treeStat` — a badge computed against the *previous* parent persists until the next
funnel event (an idle card keeps it indefinitely). The **clear** arm (`:75`) nulls `parentBranch`
but keeps `treeStat` too — compare `shipped`, which clears both (`:211`); `tree` then reports
`parent: nil` with a non-nil badge. Retargeting remote→local via adopt also skips
`stopRemoteWatch` (the loop self-heals via `shouldStopRemoteWatch`, but up to one idle interval —
5 min — later, with `remoteWatchActive` misreporting meanwhile). The remote/move arms handle
their transitions; adopt and clear are the odd ones out. **Fix:** adopt →
`scheduleTreeStat(t.id)` + `stopRemoteWatch(t.id)`; clear → `$0.treeStat = nil`.

### S2-9 · `synced` re-opens the duplicate-nudge race the code explicitly closed elsewhere

`fanOutChildTreeStats` deliberately routes through the per-card debounce slot to avoid "a direct
recompute racing the child's slot across `recomputeTreeStat`'s `lineage.read` suspension and
firing a duplicate stale nudge" (the code's own comment, `+Tree.swift:297-299`). But `synced`
(`:132`) calls `recomputeTreeStat` **directly** and never cancels `treeStatDebounce[id]`. If a
funnel-scheduled recompute is in flight when the agent calls `synced`, the in-flight pass can
compute `stale` from the pre-sync base and fire the `inSync→stale` nudge + wake — the agent is
told "parent moved ahead — merge it down" immediately after it just synced, burning a resume
turn; depending on update ordering the persisted stat may briefly stay `stale`. Structurally
confirmed (the mitigation exists; `synced` bypasses it); not stress-tested. **Fix:** cancel the
debounce slot in `synced` (or route through `scheduleTreeStat`), and compute the nudge edge
against the store value inside the `store.update` closure rather than the value captured at
entry.

### S2-8 · Closed-unmerged PR: no signal, ever — and misleading "likely merged" copy

A PR closed *without* merging is handled safely but silently: `merged` stays false (correct,
`GhProbe.swift:17`), and GitHub retains `refs/pull/N/head` after close so the tip never goes
`.gone` — the card sits `inSync`, watched forever, with no hint the parent was abandoned.
Conversely a branch deleted after a non-merge close hits tier (b)'s "gone — **likely merged**"
wording even when gh *just said* CLOSED-not-merged in the same tick. And `gh.editBase` failure
during PR-base repair is swallowed with no activity (`+Remote.swift:102-103`) — the child's
published PR keeps pointing at a deleted branch.

**Fix:** emit an activity on `state == CLOSED && !merged` ("parent PR closed without merging —
pick a new base"); consult the gh state in the gone-tier wording; warn on `editBase` failure.

### S3-1 · `warnedGone` (and friends) spam the activity feed

The gone-warning re-emits every idle tick — every 5 minutes, forever — with no once-latch
(`+Remote.swift:48-52`); the condition is persistent by nature. Related noise: the *documented
success path* of a bare-parent ship always logs `.warning` "no active card owns parent … to
notify" (`+Tree.swift:165-167`), and a re-run `shipped` warns "no recorded parent link" despite
the doc-comment calling the re-run a pure no-op. **Fix:** latch the gone warning per card
(cleared on set-parent / tip reappearing); downgrade the bare-parent notify miss to info.

### S3-2 · Spawn-sheet remote entry: silent precedence, lost form, unteachable errors

Both platforms: a non-empty remote field silently beats a selected local base while the picker
keeps displaying the ignored choice (`App/Views/SpawnSheet.swift:30-35`,
`App-iOS/Views/SpawnSheet.swift:45-50`); neither clears `remoteBase` on repo change — a `pr#12`
typed for repo A rides into repo B where it names a different PR. On failure the desktop sheet
closes unconditionally (`:317`) and iOS dismisses before the RPC returns (`:494`), so a typo'd
base costs the whole form, surfaced only as a toast. And the error can't teach: `PR#12`/`pr12`
fail the case-sensitive parse and fall into the *local* path → "base branch not found: PR#12"
with no syntax hint. **Fix:** disable/annotate the picker while remote text is present; clear
remote on repo change; keep the sheet open on failure; parse-validate inline; case-insensitive
`pr#`.

### S3-3 · Badge/baseline legibility for the human

iOS badges (`↓N`, restack glyph — `BoardCardCell.swift:89-106`) have no tooltip/long-press/legend
anywhere; desktop's `.help` speaks agent ("merge it down, then run `orchestra synced`" —
`CardView.swift:219`). The diff toggle just says "Parent" with no branch name
(`DiffInspectorView.swift:349`, `CardDetailModel.swift:65`), while the card diffstat, Zed
"View changes", and open-notes all silently became parent-relative — two adjacent cards' `+N −M`
now measure against different baselines with no indicator. Parent-relative-by-default is the
*right* call (it is "the card's own work"); it just needs labeling ("Parent (feature-a)") and
human-directed badge copy. Desktop chip-click enters the parent's *terminal*
(`CardView.swift:188`) — a heavier action than a "look at my parent" chip implies; iOS pushes the
detail view. Pick the lighter select-only behavior.

### S3-4 · `/ship` vs tree-skill disagree on remote parents (same Claude session)

ship.md: "Remote parent … out of scope for now; stop and report". tree-skill.md:35-38: full
publish path (`git push -u`, `gh pr create --base <parentHeadRef>`). Two Orchestra-authored
instructions in one worktree; which wins depends on whether the user typed `/ship` or said "ship
this". Align them (the skill's publish flow is the better answer; ship.md should defer to it).

### S3-5 · Archived cards still get recomputes, emits, and nudges

`recomputeTreeStat`'s guard (`+Tree.swift:249`) checks only existence + `origin == .worktree` —
no `!archived` (contrast `remoteMergeStep`, which checks it, `+Remote.swift:27`). `archive()`
cancels the remote watch but **not** `treeStatDebounce`/`childFanoutDebounce`
(`OrchestraService.swift:574`). A card archived inside the 750 ms debounce window (or swept up by
a parent's fan-out just before archive) gets its `treeStat` rewritten post-archive, a
`taskUpserted` emit, and — on an `inSync→stale` edge — a durable nudge enqueued into an archived
card's inbox, delivered whenever it's reopened (`wake` itself no-ops on archived). **Fix:** add
`!t.archived` to the guard; cancel both debounce slots in `archive()`.

### S3-6 · Tag shadowing in every bare-name resolution outside spawn (fixture-confirmed)

With a branch and tag both named `feature-b2`, `git rev-parse --verify --quiet feature-b2`
returns the **tag** OID. `recordSpawnBase` (`+Tree.swift:88-90`) and `WorktreeManager.ensure`
explicitly pin `refs/heads/` for exactly this reason — but `treeTip` (`:328-333`),
`mergeBaseOID` (`:352-360`), and therefore `computeTreeStat`, `synced`, and `set-parent move`'s
existence check (`:48`) don't: TreeStat measures behind/ancestry against the tag, `synced`
records the tag OID as base, and `move` accepts a parent whose branch is deleted but tag remains.
Uncommon trigger, silent wrongness. **Fix:** part of O1 — local parents resolve as
`refs/heads/<name>` everywhere.

### S3-7 · Remote-canonical strings leak into git-command nudges on off-script paths

`shipped` retargeting grandchildren onto a **remote** grandparent (reachable via `set-parent`,
off the skill script) writes nudges like `git rebase --onto pr#N <oid>` — not a rev — and drops
`prNumber`/`watch` from the rewritten links (`+Tree.swift:184-203`); an empty kept base yields a
malformed `rebase --onto X ` command. The redirect nudge's `origin/<gp>` (`+Remote.swift:96-98`)
works only via the opportunistic-tracking-update accident (see S1-1) — absent/stale in
single-branch clones. **Fix:** route every nudge's rebase target through the resolvable-ref seam;
skip the command text when the base is empty; guard `shipped` retarget on remote grandparents.

### S4 · Debt batch (each confirmed)

- **Dead code:** `TreeState.parentMerged` defined and UI-rendered but never produced
  (`Model.swift:160`; both badge switches) — wire it (it's the natural S1-3 child state) or drop
  it. `BranchLineage.classify` (`BranchLineage.swift:133-141`) has zero production callers and
  *disagrees* with the load-bearing `RemoteParentRef.parse` (consults `git remote` vs hardcoded
  `origin/`): an `upstream/feat` parent silently takes the local path with a stale tracking-ref
  baseline today. Route classification through one seam or delete `classify`.
- **Namespace collision:** `pr#7` and a branch literally named `pr-7` share
  `refs/orch/parents/pr-7` (`RemoteParentRef.swift:35-40`) — two watchers force-fetch the same
  ref from different sources and flap. Use disjoint sub-namespaces (`…/pr/<N>` vs `…/branch/<b>`).
- **TOCTOU at spawn:** the recorded base is re-resolved *after* the worktree is cut
  (`OrchestraService.swift:273→291`); a parent commit in between makes the anchor a commit not in
  the child's history. Record the child branch's own tip instead.
- **Perpetual redirect watch:** after a redirect onto `origin/main`, `watch: true` keeps a
  5-minute `ls-remote` loop running forever against a branch that can never "merge"
  (`+Remote.swift:85,114-117`). Don't watch when `baseRefName` is the default branch.
- **CLI help drift:** `orchestra --help` omits `shipped` entirely and `set-parent`'s
  `--watch`/`--mode move` (`CLIHelp.swift:14-17`) — while the skills instruct agents to run
  exactly `orchestra shipped <you>`.
- **`remoteWatchGen` entries never removed** (unbounded map, bytes only).
- **Flat base-picker `Menu`** of every branch, unsearchable, next to the fuzzy Branch combo
  (`SpawnSheet.swift:647-674`); no "spawn child" affordance on a card's context menu.
- **Comment drift:** `+Tree.swift:246` still says remote tips are "layered on later" (they're in
  this diff — and aren't wired, S1-1); `remoteMergeStep`'s step-list says tier (c) redirects
  (it deliberately warn-onlys).
- **`BranchLineage.set`'s crash-safety comment is wrong for existing links:** the
  parent-key-last ordering (`BranchLineage.swift:74-82`) makes a torn write read as "no link"
  only when there was no prior link; re-pointing an existing link that fails between the base
  write and the parent write (config-lock contention — fixture-confirmed `git config` fails on a
  held `.git/config.lock`, and a trusted card agent can run `git config` concurrently) leaves
  **old parent + new base**: a wrong rebase anchor. `unset` also swallows *all* failures, not
  just the documented exit-5 — `set(watch: false)` under contention can silently keep a
  merge-watch alive. Restore-prior-link-on-partial-failure (or distinguish exit codes) closes it.
- **No nudge on organic `inSync→restackNeeded`:** the edge-nudge fires only on `inSync→stale`
  (`+Tree.swift:258`). A parent agent amending/rebasing its branch (no `shipped`, no
  `set-parent`) flips children to `restackNeeded` silently — the one restack path with no other
  notifier (`shipped`, `move`, and the remote redirect all nudge explicitly). Looks like an
  oversight rather than scope; decide and either nudge the edge or document why not.
- **Multi-await interleave:** `shipped` reads the link then runs steps (a)–(c) across many
  suspensions; a concurrent `set-parent` on the same branch landing in between gets its fresh
  link wiped by step (c)'s unconditional clear. Human-races-agent probability; re-read before
  clear would close it.

### Test-coverage gaps (vs 04-tests.md claims)

Coverage is strong overall — real-git fixtures, substantive assertions (RedirectMechanicsTests
proves the phantom-conflict mechanics; WorktreeManagerTests covers tag shadowing). Confirmed gaps:
- **No remote-parent TreeStat recompute or `synced` test** — the one case that would have caught
  S1-1.
- 04-tests claims "ancestry ⇒ merged/redirect"; code (and its test) are warn-only — the doc is
  wrong, the code is right.
- No watch-loop failure/backoff-tick test; GhProbe availability test is a tautology
  (`available == Proc.toolExists("gh")` — the implementation expression).
- The `wake` half of every enqueue+wake pair is never asserted (all nudge tests peek the inbox
  only).
- Bare-parent borrow git mechanics are untested prose; daemon-restart durability is tested on the
  same service instance, not a reconstructed one; no diamond-rejection, dirty-tree-abort, or
  archived-parent-fallback tests.
- 03-implementation claims spawn ends with `scheduleTreeStat(id)` and 04-tests claims the spawn
  integration asserts `treeStat inSync` — neither exists (treeStat is nil until first report;
  cosmetic, but a doc-claimed behavior).

### Doc-vs-code divergences (traceability spot-check)

The layered docs are ~85% faithful; drift found: 02-contract's `BranchLineage.set` "throws
`unknownBranch`" (no branch-existence check exists in `set` — validation lives at the service
layer, so a *direct* `set` accepts a nonexistent parent); watch loop specified on `RemoteParents`,
implemented on `OrchestraService` (benign); contract ladder text + `remoteMergeStep`'s own
docstring say tier (c) redirects (warn-only in code, deliberately — update the three docs);
`shipped` (c) "mark parentMerged" → implemented as clear-to-nil (and the enum case left dead);
skill docs' "recorded base in `orchestra tree`" (S2-4); ship.md vs skill on remote parents
(S3-4); all file:line anchors in the docs predate implementation and have drifted (semantic
targets exist). Impl exceeds the contract in places (GIT_ASKPASS hardening, 20 s timeouts,
generation-token loop lifecycle).

---

## (c) Overhaul proposals (while it's still a draft)

### O1 — Push the canonical→resolvable seam down into the link (fixes S1-1's whole class)

`resolvedParentRef(Task)` hangs the mapping off `Task`, so only Task-holding consumers (diffs)
use it; everything working from a `ParentLink` (`computeTreeStat`, `synced`, both nudge
composers, `mergeBaseOID` callers) uses the raw canonical and breaks or works by accident. Give
the link itself the mapping — `ParentLink.resolvableRef` (local → `refs/heads/<b>` — which also
fixes the latent tag-shadowing the spawn path already defends against; remote →
`refs/orch/parents/…`) — and route **every** daemon git verb through it; keep the canonical
string strictly for storage/display; `resolvedParentRef` becomes a forwarder. Cost: a
one-file refactor plus touching ~6 call sites. This is the fix-shape for S1-1, S3-6, S3-7, and
the `origin/…`-works-by-accident fragility in one move, and it's much harder for the next
consumer to get wrong.

### O2 — Trust-but-verify choreography: make the request/response pair first-class

The prose choreography (skill instructs; daemon believes) is the right *delivery* mechanism —
agents act on text, and it keeps Claude/Codex symmetric. What's missing is the daemon-side noun
and the cheap verifications:

- a small `merge-request {child}` op that composes the canonical prose itself (one text instead
  of two skill paraphrases), records a `mergeRequested` state (surface it via the dead
  `parentMerged`/a new case on both cards — the child finally gets a "waiting" badge, S1-3's UX),
  enables re-nudge on timer and dedup on re-send, and is cleared by `shipped`;
- `shipped` gains the parent-tip-advanced sanity gate (S2-2) and the notify-the-child step
  (S1-3), and skips the parent echo when the caller is the parent;
- `synced` records the merge-base, not the parent tip (S2-1).

Cost: one new command + one state value + ~3 small daemon edits. Buys observability, retry,
idempotence, and an integrity floor under the least reliable hop (free-text agent compliance) —
without the daemon ever touching a ref. The full first-class-merge-op alternative (daemon
performs merges) was rightly rejected; this keeps the owning-agent rule intact.

### O3 — Own the bare-parent borrow lifecycle

The ephemeral borrow is pure prose: unspecified path, no conflict/abort guidance, no crash sweep.
A crashed borrow leaves the parent branch checked out in a stray worktree, which then blocks both
future spawns onto that branch (`branchInUse`) and the next borrow — with no recovery path short
of a human running `git worktree remove`. Options: (a) daemon `borrow`/`release` ops that
create/register/sweep the throwaway at a canonical path while the *agent* still performs the
merge inside it (preserves the trust posture; my recommendation), or (b) minimal: a
conflict/abort paragraph in both skill variants + a daemon-side prune of orphaned
`orch-borrow-*` worktrees on archive/startup. A bare branch has no owner, so daemon involvement
here doesn't violate the owning-agent rule — that rule protects owned branches.

### O4 — Decide the remote-name story before the config schema ossifies

`origin` is hardcoded in three places (`RemoteParentRef.parse`, `RemoteParents.fetch`'s argv, the
canonical stored form written into durable git config), while the dead `BranchLineage.classify`
consults `git remote` and would disagree. Either commit to origin-only explicitly (delete
`classify`, error on `<other-remote>/x` in set-parent rather than silently degrading to a stale
"local" link) or generalize now (canonical keeps the remote name; parse consults the remote list)
— retrofitting the stored canonical format later means migrating users' git config.

---

## (d) What's good — don't touch these

- **git-config as lineage SSOT.** Fixture-verified lifecycle: `git branch -m` migrates the
  `orchestra-*` keys with the section; `git branch -D` deletes them — hygiene no
  tasks.json/refs-notes/lineage-file alternative gets for free. Repo-scoped (shared across
  worktrees), plain-git debuggable, no collision with git-town/Graphite key namespaces. The
  parent key written *last* so a torn write reads as "no link" is exactly right.
- **Parent card derived, never stored.** Every consumer audited degrades sanely on a missing
  card (warning activity or durable-inbox enqueue). Composes with F3 as designed. Fix the
  uniqueness *precondition* (S2-6), not the derivation.
- **Tree, not DAG.** Multi-parent breaks merge-base diffs and `--onto` redirection; prior art is
  unanimous.
- **The core git model — merge-down sync, `rebase --onto` at re-parent, squash at ship, with a
  recorded parent-base OID.** Fixture-proven: the anchor transplants only the child's commits
  across squash-merge redirects, drops sync merge commits, tolerates even a stale anchor
  ("patch contents already upstream"), and produces no phantom conflicts. This is the
  load-bearing choice and it is right (the Graphite `parentBranchRevision` lesson, correctly
  learned).
- **"Daemon never touches refs" — honored in full.** Every `Proc` git invocation in the diff
  audited: config/rev-parse/merge-base/rev-list/ls-remote/fetch(private, force-refspec)/worktree
  add. The only branch creation is spawn's `worktree add -b` — the card-creation primitive.
- **`RemoteParents` hardening.** Tri-state `RemoteTip` (`gone` ≠ `unavailable`) is the exact
  distinction naive implementations miss — fixture-verified both arms; `GIT_TERMINAL_PROMPT=0` +
  `GIT_ASKPASS=/usr/bin/false` + 20 s timeouts on every remote call; the private namespace is
  read-only by construction and fork-PR-capable via `refs/pull/N/head`.
- **Detection-ladder epistemics.** gh authoritative; gone-before-ancestry with the correct
  stale-private-ref rationale written down; ancestry proof-positive *and* warn-only (immune to
  force-push false positives — verified reasoning); never auto-redirects on a guess. The
  generation-token watch-loop lifecycle (cancel+bump+install atomic on the actor) is careful,
  tested concurrency work.
- **`AgentsFileComposer` + `TreeDocs.forAgent`.** Marker-delimited section upsert with the
  legacy-markerless-reset shows real upgrade-path thinking; no `if agent ==` in shared code;
  genuinely equal guidance substance for Claude and Codex (modulo S1-4's repo-file gap).
- **`WorktreeManager.ensure(base:)`.** Validate-before-cut (no orphan dir on a bad base),
  `refs/heads/` pinning against tag shadowing, the `branchExisted` signal gating churn
  derivation. Small and exactly right — its tag-pinning discipline just needs to spread (O1).
- **TreeStat as a persisted Task field with debounced, change-gated recompute** — the `diffStat`
  twin; the edge-triggered stale nudge (inSync→stale only) is the correct anti-spam semantics,
  and routing the child fan-out through the child's own debounce slot to kill the duplicate-nudge
  race shows the concurrency was actually thought through (the one bypass is `synced`, S2-9).
- **Restart durability is sound.** The nudge edge is computed persisted-vs-computed: a daemon
  restart neither re-nudges (persisted `stale` stays `stale` — no edge) nor loses the signal
  (parent moved while down → first funnel recompute sees persisted `inSync` → exactly one nudge);
  nudges themselves ride the durable inbox; `rebuildRemoteWatches` restores watches from live
  cards' config honoring `watch=false`. Verified across the restart path.
- **Fail-safe degradation of broken lineage state.** A GC'd/unknown recorded base makes
  `rev-list`/`merge-base --is-ancestor` exit 128 → `restackNeeded`, never a false `inSync`
  (fixture-verified); a dangling parent link degrades to `restackNeeded`, not garbage; `children()`
  parsing is robust to `/` and `.` in branch names and the no-match exit.
- **The cycle guard is uniformly applied and atomic.** Every lineage writer routes through
  `BranchLineage.set` (both spawn arms, both set-parent modes, `shipped` retarget, remote
  redirect), and `set` has no internal awaits, so guard+write is atomic w.r.t. other lineage ops;
  concurrent `set(A→B)`/`set(B→A)` serialize with the second correctly rejected. (Its one blind
  spot is dangling values, S2-3.)
- **Parent-relative diffs.** Merge-base (not recorded-base) baseline verified correct: a parent
  advancing does not leak into the child's diff; all four consumers share the one
  `resolvedParentRef` seam. Parent-relative *by default* for stacked cards is the right product
  call.
- **The test suite itself.** 631 green, real git fixtures throughout, no git mocking, several
  genuinely subtle regression tests (regexp anchoring, tag shadowing, watch-loop generation
  race). The gaps (above) are enumerable and cheap to close.

---

## Fix-round checklist (suggested order)

1. S1-1 remote resolution in TreeStat/`synced` (+ tests) — ideally as O1.
2. S1-2 root-ship retarget fallback + ship.md/skill call `shipped` when children exist.
3. S1-3 notify+wake the shipped child; skip parent echo.
4. S1-4 repo-root AGENTS.md tree-aware ship step.
5. S1-5 async `GhClient` off the service actor; gate `gh pr view` on movement.
6. S2-1 `synced` records merge-base; S2-2 `shipped` sanity gate; S2-9 `synced` debounce cancel.
7. S2-3 base validation before `ensure` + dangling-link cycle-guard fix + rollback;
   S2-4 `TreeNode.base`.
8. S2-7 adopt/clear treeStat + watch; S2-8 + S3-1 warning latch/copy/downgrades;
   S3-5 archived-card guard.
9. S3-2 spawn-sheet fixes; S3-3 labels/tooltips; S3-4 align ship docs; S3-6 refs/heads pinning
   (with O1).
10. S4 batch + coverage gaps (remote recompute test first) + doc-drift pass.
