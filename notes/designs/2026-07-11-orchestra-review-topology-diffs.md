# Review-topology redesign — diffs (APPLIED 2026-07-11)

Companion to [[2026-07-11-orchestra-review-topology]]. Allen approved the design 2026-07-11;
Diffs 1 and 3 are applied, Diff 2 was **skipped** by his decision (global CLAUDE.md + the injected
skill already reach every card; a repo copy would drift).

---

## Diff 1 — `~/.claude/CLAUDE.md`, §"Orchestra — my standard workflow for big developments"

Replace numbered items **2, 3 (incl. sub-items), and 4** of the stage list (item 1 "Research" and
item 5 "ends in the Review column" are unchanged).

### Old

```markdown
2. **Plan** — once the idea is solid, launch a **planning card on a new branch** on the smartest
   available model (xhigh), using **`/layered-plan`** + superpowers. Output: the change **split into
   many PRs with a PR tree** showing the order in which the PRs must be created.
3. **Orchestrate** — after I approve the plan, **replace the planning card with an orchestrator**
   card on a **cost-efficient model** (using superpowers) that fans out **PR cards** (cost-efficient
   models) and manages their lifecycles. Each PR card:
   1. Starts in **planning**: use superpowers to write a plan for its PR, informed by its prompt, the
      layered plan & research, and the plans/implementations of prior PRs already merged onto the
      orchestrator branch.
   2. Plan is **reviewed by cost-efficient Claude + GPT** until no more complaints (superpowers).
   3. **Implements** the change using superpowers (**high** effort).
   4. Implementation is **reviewed by cost-efficient Claude + GPT** until no more complaints (superpowers).
   5. PR card **asks the orchestrator to merge**.
4. **Final review** — once all PRs are merged, the orchestrator runs a review by **cost-efficient
   Claude + GPT** until no more complaints (superpowers).
```

### New

```markdown
2. **Plan** — once the idea is solid, launch a **planning card on a new branch** on the smartest
   available model (xhigh), using **`/layered-plan`** + superpowers. Output: the change **split into
   many PRs with a PR tree** that also (a) lists each PR's **touched files / hotspots**, (b) groups
   PRs into **waves** — PRs whose primary surfaces are disjoint run in parallel off the same base,
   with a declared merge order; **flag-day PRs** (one breaking change that must flip every call
   site atomically — a codebase-wide sweep that can't be staged, so it conflicts with everything)
   run solo between waves — and (c) assigns each PR a **plan tier**: **S** (≤ ~150 LOC expected,
   no schema/wire/state-machine change, no shared hotspot), **M** (default), **L** (flag-day /
   on-disk or wire format / concurrency-bearing).
3. **Orchestrate** — after I approve the plan, **replace the planning card with an orchestrator**
   card on a **cost-efficient model** (using superpowers) that fans out **PR cards** (cost-efficient
   models) **wave by wave** (`spawn --base` off the orchestrator branch; siblings restack via the
   tree nudges as each merges) and manages their lifecycles. Each PR card:
   1. Starts in **planning**, scaled to its tier: **S** = a 10–30-line task list in the card seed,
      **no plan review** (the impl review covers it); **M** = a plan ≤ ~150 lines; **L** = a full
      task plan. Informed by its prompt, the layered plan & research, and prior merged PRs.
   2. Plan (tiers M/L): **one simultaneous bounded review pass** — a cost-efficient Claude reviewer
      **and** a Codex reviewer launched together as read-only cards (see the orchestra-delegation
      skill §"Review pairs" for the spawn/pin/degrade recipe). **Fix every confirmed finding**
      (record a one-line rebuttal for anything rejected). **Iff** the pass raised a BLOCKER/MAJOR,
      send the fix diff back to the same reviewers for **one** scoped confirm/deny turn. Then
      **stop** — no further rounds; leftover minors are recorded for the periodic review card.
   3. **Implements** the change using superpowers (**high** effort).
   4. Implementation review: the **same bounded contract as 3.2** — one simultaneous Claude + Codex
      pass, fix everything, one scoped fix-verification iff blockers/majors, hard stop.
   5. PR card **asks the orchestrator to merge**.
4. **Periodic review card** — a **streaming reviewer that rides each wave**: spawn it when the
   wave starts, as a normal write-mode child card based on the orchestrator branch. Each PR merge
   fires the daemon's stale nudge → it merges the parent + `synced` and reviews the new increment
   on a real checkout, scoped to **integration seams** (how the just-merged PR composes with the
   already-merged wave) plus the deferred per-PR minors — NOT a solo re-review of the PR, which
   already had its bounded pass — fixing on its own branch as it goes. When the wave drains, it
   runs a **Claude + Codex review pair over the accumulated wave diff, until no more complaints,
   hard-capped at 3 pair-passes**, then `merge-request`s. The orchestrator merges it, **then**
   launches the next wave — planning starts on a reviewed, fixed foundation. Escape hatch: if the
   post-drain residual exceeds ~one planning cycle, launch the next wave anyway and let the fixes
   merge-request in (in-flight cards restack via the normal nudges). Run one final review card
   this way before the orchestrator branch merges to main.
```

*(The "Model & effort defaults" block below the list is unchanged.)*

---

## Diff 2 (OPTIONAL) — project `CLAUDE.md` (claude-kanban)

Append after the "Design for every agent" section. Skip entirely if Allen prefers the single
global source of truth (recommended default: **skip**; the global workflow + injected skill
already reach every card).

### New section

```markdown
## Multi-card reviews — bounded, dual-backend
PR-card plan/impl reviews follow the bounded contract in the global workflow: **one** simultaneous
Claude + Codex read-only review pass, fix every confirmed finding, one scoped fix-verification only
when blockers/majors were raised — no "until no complaints" loops. Deep looped review happens on
the **periodic review card** (capped at 3 pair-passes) at wave boundaries. Design + evidence:
`notes/designs/2026-07-11-orchestra-review-topology.md`.
```

---

## Diff 3 — orchestra-delegation skill (all three copies)

Insert the section below **after "## The four moves — when to use each"** (i.e. between it and
"## Cards vs. native subagents…") in:

1. `Sources/OrchestraCore/Resources/delegation-skill.md` (Claude cards — vendored SSOT)
2. `Sources/OrchestraCore/Resources/delegation-agents.md` (Codex cards — same text; it is
   backend-agnostic)
3. `~/.claude/skills/orchestra-delegation/SKILL.md` (resync of the user-level copy)

### New section (identical in all three)

```markdown
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
- **Degrade, don't hang:** if one backend fails to spawn, proceed **single-reviewer** and say so
  in your plan/merge-request. If one reviewer's findings arrive and the other's don't: `status`
  the straggler — dead → proceed single-reviewer; alive → nudge once via `send`, and if still
  silent by your next wake, archive it and proceed. **Zero** completed reviews = do not advance.
```

### Consistency note

The vendored resources are what cards actually receive: `DelegationDocs.install` writes the
per-agent variant into each card's `.claude/skills/orchestra-delegation/SKILL.md` /
`CODEX_HOME/AGENTS.md` at launch (`Sources/OrchestraCore/Agents/DelegationDocs.swift`), so editing
the two resource files is sufficient for all future cards; the `~/.claude/skills` copy only serves
sessions launched outside Orchestra. `Tests/OrchestraCoreTests/DelegationDocsTests.swift` anchors
on existing phrases (none removed by this insertion) — run
`swift test --filter DelegationDocsTests` after applying to confirm.
