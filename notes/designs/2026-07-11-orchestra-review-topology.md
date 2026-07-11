# Orchestra multi-card review workflow — bounded reviews + periodic review card

**Status: DRAFT — awaiting Allen's approval.** No workflow file (`~/.claude/CLAUDE.md`, project
`CLAUDE.md`, delegation skill) is modified until this design is approved. The exact prepared diffs
live in [[2026-07-11-orchestra-review-topology-diffs]].

## 1. Problem — measured on card-lifecycle-convergence

The lifecycle project (plan approval → final merge) took **~41 wall-clock hours** for ~4.3k lines of
`Sources/` change, with **8.9k lines of reviewed planning prose**. Reconstructed from git:

- 10 PR cards; **8 of 10 ran strictly serially** (stacked branches; only PR5 ⇉ PR6a overlapped).
- **Per-PR pre-code overhead was 1–2.5 h** — the gap between the previous PR's merge and the next
  PR's first code commit is entirely "write a task plan, dual-review it until clean": PR2 63 min,
  PR3b 112 min, PR6b 158 min. Roughly **10–15 h of the 41 h**.
- The single largest gap (4h22m, PR4b's post-impl review round) spans 22:42→03:04 — partly
  overnight idle, but only *possible* because the workflow is fully serial: nothing else could
  proceed while one review round sat open.
- Plan sizes: 333–983 lines per PR plan (median ~630). PR3a spent a 451-line dual-reviewed plan on
  "add three timeout knobs" whose implementation took two commits in ~2 minutes.

The standing workflow (global CLAUDE.md §"Orchestra — my standard workflow") mandates, per PR card,
two **unbounded** "reviewed by Claude + GPT until no more complaints" loops (plan + implementation).
Those loops are the dominant overhead.

## 2. Evidence — what the review rounds actually caught

Before cutting anything, I counted. Round-by-round yields are recorded inside the lifecycle plan
files themselves ("Review round N — resolutions" sections) and in the impl-review fix commits.

### Plan reviews, by round

| PR | R1 | R2 | R3+ |
|----|----|----|-----|
| PR1 | 1 BLOCKER (reentrancy rev-skew) + 2 MAJOR | **2 BLOCKERs** (2nd `subscribe()` consumer; Write would silently delete 29 existing tests) + 3 MAJOR | R3: "no blockers/majors remain" — mechanical minors only |
| PR3a | substantive (test covered 1 of 3 add sites) | Opus SHIP; GPT: 1 minor **in the plan's own verification grep** | — |
| PR3b | substantive | **1 BLOCKER** (concurrent-spawn rollback race) | — |
| PR4b | architectural findings | **4 substantive** (spawnBase persistence, teardown duty list, conservative-mode lifetime, BA test rule) | — |
| PR5 | 1 blocker (debounce regresses rev on crash) | real equivalence bugs (cache-evict ≠ off-actor hop; cache-hit skipped nil-session cards) | — |
| PR6a | multiple (spawn TOCTOU, subscribe gap, lock deadlock) | 1 new MAJOR; confirmed R1 fixes | R3: real (barrier failure-open); **R4: critical deadlock introduced by the R3 fix itself** |

### Implementation reviews

~8 impl-review fix commits across the project (~420 inserted lines), all real: PR2's spawn
false-kill race, PR3b's three worktree-safety hardenings (owned-roots sweep guard, fail-safe borrow
persistence, rollback restore), PR4b's four bugs (epoch-fence adoption, boot-window watch-registry
clobber, reopen decode, poll-interval wiring — 189 lines), PR5's bounded `branch -D`, PR7's
final-review findings. The one recorded 4th-round impl finding (PR "GPT 4th finding") resolved as
**docs-only, no logic change**.

### Honest conclusions (this is partial pushback on the raw proposal)

1. **Round 1 is high-yield** — conceptual/architectural races. Keep it, full strength.
2. **Round 2 is NOT noise.** It caught real blockers in at least 4 of 10 PRs — characteristically
   *implementation-reality* findings (existing tests that a `Write` would delete, exact
   blast-radius, a second consumer of an API being changed). A bare "one pass, no follow-up"
   contract would have shipped several of these.
3. **Rounds 3+ are mostly polish** — with one glaring exception: PR6a's R4 caught a **critical
   deadlock that the R3 fix introduced**. The distinctive risk late in the loop is not
   "reviewer finds pre-existing bug", it is "**the fix itself is wrong**".
4. Therefore the right bound is not "one pass, take what you get" and not "loop until silence":
   it is **one full pass + fix everything + one *scoped* verification of the fixes** (only when
   the pass raised blockers/majors). That keeps R1's yield, converts R2's yield into a cheap
   targeted check, addresses the fix-introduces-bug failure mode directly, and deletes the
   unbounded tail. What a single pass still misses becomes the periodic review card's job.

## 3. The new per-PR review contract (bounded)

Per PR card, **plan** and **implementation** each get:

1. **One simultaneous dual review pass**: a Claude reviewer and a Codex reviewer launched at the
   same time as **read-only cards** (mechanics in §6), each reviewing independently.
2. **Fix every confirmed finding** from both reviewers (resolution **(a)** of the ambiguity —
   see §7). Findings the PR card believes are wrong get a recorded one-line rebuttal in the plan
   file instead of a fix (superpowers `receiving-code-review` discipline — verify, don't comply
   performatively).
3. **Scoped fix-verification, severity-gated**: iff the pass raised any BLOCKER/MAJOR, send the
   fix diff (just the delta, not the whole artifact) back to the reviewer pair for **one**
   confirm/deny turn. No new full review; new findings raised during verification are recorded
   for the periodic review card unless they are themselves blockers.
4. **Hard stop.** No third contact. The PR proceeds (plan → implement, or impl → merge-request).

**Plan depth scales with PR risk** (this is where PR3a's 451 lines go away):

| Tier | Criteria (any) | Plan artifact |
|------|---------------|---------------|
| **S** | ≤ ~150 LOC expected, no schema/wire/state-machine change, no shared-file hotspot | 10–30 line task list in the PR card seed; **plan review skipped entirely** — the impl review pass covers it |
| **M** | default | ≤ ~150-line plan; full contract above |
| **L** | flag-day PRs (defined in §8), on-disk/wire format changes, concurrency-bearing design | full task plan; full contract above |

Worked example: in the lifecycle project this would have made PR3a and PR7 tier S, most PRs tier M,
and PR2/PR4b tier L — eliminating ~2–4 review round-trips per PR and 300–800 lines of prose each.

## 4. The periodic review card

A dedicated deep-review card, replacing the per-PR "until no complaints" tail **and** subsuming the
old stage-4 final review.

- **Trigger**: after each wave of PRs merges (§8), or after **≥3 PRs** have merged since the last
  review card, whichever comes first — and always **once before the orchestrator branch merges to
  main** (this last one is the old final review, unchanged in role).
- **Scope**: the orchestrator branch's cumulative diff since the last reviewed snapshot (or since
  the branch base for the first one), plus the deferred minor findings the bounded per-PR passes
  recorded.
- **Depth**: Claude + Codex review pairs, iterating **until no more complaints, hard-capped at 3
  pair-passes**. Pass 1 is the read-only finding phase on the quiesced post-wave tree (§5); fixes
  are applied by a writing fix card (or the orchestrator inline, for trivia); passes 2–3 run on the
  fixed tree, doubling as fix verification. Stop early when a pass comes back clean. The whole card
  overlaps the next wave's planning phase (§5) — it blocks merges, not work.
- **Merge-back**: the fix card's work merges into the orchestrator branch via the normal
  `merge-request` → owning-agent squash-merge path, before the next wave spawns.

## 5. The concurrency question — reasoned answer

**Question:** can the periodic review card run concurrently with in-flight PR cards, or must it be
a barrier?

**Answer: the review card runs at the barrier, on the quiesced tree — and the wall-clock is
recovered by overlapping it with the *next* wave's pre-code phase, not the previous wave's tail.**
(Amended 2026-07-11 after design dialogue with Allen; the original recommendation — concurrent
pinned find during the previous wave's tail — survives only as a narrow opt-in, below.) Neither a
naive barrier nor a fully-concurrent fixing card survives contact with the mechanics. Grounding
(verified against `docs/` + `notes/designs/parent-card-branch-linking/`):

- **Pinning is real — but only via a worktree card.** `spawn` with `base: <orchestrator-branch>`
  cuts the card's own branch at the orchestrator's tip commit **at spawn time**; that branch does
  not move when the orchestrator advances (the daemon only flips treeStat to `stale` and the `↓N`
  badge counts the drift — restack is always agent-initiated, never automatic). A **freeform**
  reviewer pointed at the orchestrator's cwd would instead watch a **moving working tree** as PRs
  merge beneath it — precisely the "silently reviews the wrong tree" failure. There is **no
  commit-pin spawn parameter** and a read-only card **cannot `git checkout`** to pin itself
  (readOnly's classifier layer denies all git state mutation). So: concurrent reviewers MUST be
  **read-only worktree cards spawned with `base` = the orchestrator branch**.
- **Merge-back cannot race at the git level** — the owning-agent rule means only the orchestrator's
  own agent advances the orchestrator branch, and it processes merge-requests serially from its
  inbox. The race is **semantic**, not mechanical: fixes computed against snapshot X conflict with,
  or are obsoleted by, PRs that merged after X.

### The three topologies

| | Full barrier | Fully concurrent (fixing card) | **Split: concurrent read-only find + barrier fix** |
|---|---|---|---|
| Correctness | Reviews exact final tree | Reviews snapshot X; **fixes land against tip ≠ X** | Reviews consistent snapshot X; fixes re-validated against tip |
| Wall-clock | Whole review (2–4 h at 3 passes) on the critical path | Fully overlapped | Only fix-application (~minutes–1 h) on the critical path |
| Conflict surface | None | **High** — same hotspot files as in-flight PRs (`OrchestraService.swift` was the reason fan-out was rejected); repeated stale→merge→re-validate churn as each PR lands | Confined to the fix step at the barrier, when nothing is in flight |
| Staleness of findings | None | Findings AND fixes go stale mid-flight | Findings may go stale; **explicit re-validation step**; `↓N` badge quantifies drift |
| Failure mode | Slow | **Worst**: a fix silently reverts or collides with a just-merged PR; merge-request ping-pong | A stale finding gets dropped with a note (fail-safe: nothing lands unvalidated) |

*(The table analyzes the three original candidates. The adopted topology is a refinement of the
barrier column: it keeps the barrier's correctness — find and fix on the quiesced tree — and
removes its wall-clock cost by overlapping the review card with the next wave's pre-code phase
instead of the previous wave's tail. The split column survives only as the narrow opt-in below.)*

Fully-concurrent-fixing is **rejected** outright. Between the other two, the deciding facts:

- The **token cost of the find pass is identical** in both topologies (same diff, same reviewers);
  concurrency only moves it earlier. What it adds is a **staleness waste channel** — findings on
  regions an in-flight PR is rewriting are discarded spend — and that waste is proportional to the
  hotspot overlap between the reviewed diff and the in-flight PRs, which the lifecycle evidence
  shows is **high** in exactly the projects this workflow serves.
- The pinned concurrent reviewer sees **less**, not more: PRs merging after its pin aren't covered
  by this pass at all and wait a full cycle. The valuable cross-PR view (interactions across the
  merged wave) is a property of the periodic card in *any* topology — concurrency adds nothing
  to it.
- The overlap that is actually free is the **next wave's pre-code phase** (the measured 1–2.5 h/PR
  of planning + plan review), which conflicts with nothing on the tree.

So the rule:

> **When the wave drains, spawn the review card on the quiesced tip AND spawn the next wave's PR
> cards at the same time — they plan (and plan-review) while the review card finds and fixes. The
> orchestrator merges the review card's fixes FIRST, before the wave's first PR merge; in-flight
> cards restack over the fixes via the normal stale/restack nudges. Hold *merges*, not work; hold
> the next wave's *spawn* only if the review reports blockers on code it builds on.**
>
> *Opt-in narrow case:* a concurrent pinned find during the previous wave's tail is allowed when
> the tail is long AND the in-flight PRs don't touch the files under review — then the staleness
> discipline below is mandatory.

**Nobody polls.** Reviewers `send` findings, which wakes the orchestrator's inbox; the barrier is
an event the orchestrator itself produces (all merges serialize through its own agent under the
owning-agent rule), so "waiting for the barrier" is just holding findings until it processes the
wave's last merge-request; next-wave cards get one daemon nudge per stale/restack edge. The loop
is event-driven end to end.

### Staleness discipline (mandatory whenever find-tree ≠ fix-tree)

In the default topology the review card finds and fixes on the same quiesced tree, so this rarely
triggers. It is mandatory for the opt-in concurrent case, and any time something merges between
find and fix. Every finding is recorded as `{pinned commit X, file, symbol, description,
severity}`. Before applying, the fix card (or orchestrator, for trivial fixes): (1) re-locates the
symbol at the current tip; (2) if anything merged after X touched that region, re-verifies the
finding still applies; (3) fixes it, or drops it with a one-line note ("obsoleted by PR-N").
Findings are never applied blind to a tree they weren't found on.

## 6. Both backends, symmetric, degrading gracefully

The reviewer pair must work for Claude **and** Codex (project rule: design for the general agent
contract). Verified mechanics:

- **Launch**: `batch-spawn` two read-only cards off the same `base` pin — `agent: claude-code` and
  `agent: codex`. readOnly is enforced identically for both (Codex maps it to its native
  `--sandbox read-only -a never`). The seed carries: pinned commit, diff range to review, output
  contract ("send findings to <orchestrator> via `send`, then conclude").
- **Await**: findings need *content*, so the return channel is **`send`-only** — each reviewer
  `send`s its findings to the requester and concludes. Per the delegation skill's one-channel rule,
  the requester does **not** also `wait` on those reviewers (double-channel gives two notices in
  either order). Messages coalesce in the durable inbox; the requester stays chattable.
- **Degradation** (a missing backend must not hang the wave):
  - Spawn of one backend errors (agent not installed, launch abort) → proceed **single-reviewer**,
    record "single-reviewer pass (codex unavailable)" in the plan/merge-request.
  - One reviewer's findings arrive but the other's don't: check the straggler with `status` — if
    it is dead, proceed single-reviewer; if alive, nudge once via `send`; if still nothing by the
    requester's next wake, proceed single-reviewer and archive the straggler. (`wait` has **no
    timeout** — verified gap — so this discipline can't be delegated to the daemon today.)
  - **Never** silently skip both: zero completed reviews blocks the PR from advancing.

## 7. Resolving the "no need to run until no complaints" ambiguity

Reading **(a)** — one pass, **fix every finding**, no full re-review — is adopted, strengthened by
the severity-gated scoped verification (§3.3). Reading (b) ("take what you get") is rejected on the
evidence: in a linear or wave-stacked build, an early defective PR propagates into everything
stacked on it, and the lifecycle data shows single passes leave real blockers on the table (§2).
The scoped-verify gate also answers "should early/foundational PRs be treated differently" without
a special case: foundational PRs raise more blockers/majors, so they get the verification exchange
more often; leaf/S-tier PRs mostly don't trigger it. **Flagged for Allen at approval: confirm
(a)+scoped-verify is the intent.**

## 8. Waves instead of a chain (the bigger wall-clock lever)

8 of 10 PRs serialized is itself the largest cost; full fan-out was rejected for conflict storms in
`OrchestraService.swift`. The middle ground, now that branch-tree lineage exists:

- The planning stage's PR tree must include a **touched-files/hotspot column** per PR (the
  lifecycle tree already effectively had this; make it mandatory output).
- PRs whose primary surfaces are disjoint form a **wave**: spawned in parallel off the same base
  (`spawn --base`), merged in a **declared order**. After each merge the owning-agent machinery
  already nudges siblings to restack (`stale`/`restackNeeded` → `synced`) — restack cost is paid
  by the *waiting* card off the critical path, not by the merged one.
- **Flag-day PRs** — PRs that make one breaking change atomically across the whole codebase, where
  every call site must flip in the same commit and the change can't be staged incrementally — run
  **solo between waves**: because they touch everything, they conflict with everything, so they are
  irreducible barriers by nature. Lifecycle had exactly two: PR2 (the `status`-field removal sweep,
  every consumer at once) and PR4b (the ~30-file test migration); the PR tree itself called them
  "irreducible flag-days by design".
- The periodic review card slots at wave boundaries (§4), overlapping the next wave's planning
  phase (§5).

Lifecycle counterfactual: {PR3a ⇉ PR3b-prep}, {PR5 ⇉ PR6a ⇉ parts of PR7's fixture} and the
already-parallel pair suggest a 10-PR chain compressing to ~6 sequential slots. Combined with
bounded reviews (~5–8 h saved) and pre-code overhead cuts, a realistic estimate is **41 h → low
20s** for a project of this shape — without giving up the review yield documented in §2.

## 9. What changes where (prepared, not applied)

Exact diffs in [[2026-07-11-orchestra-review-topology-diffs]]:

1. **`~/.claude/CLAUDE.md`** §"Orchestra — my standard workflow": per-PR steps 3.2/3.4 replaced
   with the bounded contract; stage 4 replaced by the periodic review card; wave guidance + plan
   tiers added.
2. **Project `CLAUDE.md`**: no mandatory change (the workflow is Allen-global; the mechanics live
   in the delegation skill every card receives). An optional 4-line pointer is prepared if Allen
   wants the contract visible repo-locally.
3. **`orchestra-delegation` skill** — the vendored sources cards actually receive
   (`Sources/OrchestraCore/Resources/delegation-skill.md` for Claude **and**
   `delegation-agents.md` for Codex, keeping backend parity), plus the user-level copy
   `~/.claude/skills/orchestra-delegation/SKILL.md` resynced: a new "Review pairs" section with
   the spawn/await/degrade recipe (§6) and the pinned-snapshot rule (§5).

No daemon/code change is required — the design deliberately composes existing primitives
(`spawn --base` + `access: readOnly` + `wait`/`watcher` + `merge-request`). Two follow-ups worth
separate cards later, **not** blockers: a `wait` deadline option (§6 wedge case), and a
commit-pin spawn parameter (would let freeform reviewers pin without a worktree).

## 10. Open items for Allen at approval

1. Confirm ambiguity resolution **(a) + severity-gated scoped verify** (§7).
2. Confirm the **S/M/L plan tiers** and the S-tier "skip plan review entirely" rule (§3).
3. Confirm the periodic trigger constant (**≥3 merged PRs** / per-wave) (§4).
4. OK to adopt **waves** as the default topology with the touched-files column mandatory in PR
   trees (§8)?
5. Optional project-CLAUDE.md pointer — include or skip (§9.2)?
