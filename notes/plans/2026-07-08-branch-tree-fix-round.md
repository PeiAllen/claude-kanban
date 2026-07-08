# Branch-Tree Fix Round — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development for every S1/S2 fix. Steps use checkbox (`- [ ]`) syntax for tracking. This plan is the durable state for card `d0503f`; commits are keyed to finding IDs.

**Goal:** Implement every finding, overhaul, test-gap, and doc-drift item in `notes/designs/2026-07-08-branch-tree-deep-review.md` (THE SPEC) so `fix/branch-tree-review-round` is mergeable into `plan/parent-card-branch-linking`.

**Architecture:** The spec's overhauls reshape the fixes: **O1** pushes a canonical→resolvable ref seam down onto `ParentLink.resolvableRef` and routes every daemon git verb through it (fix-shape for S1-1, S3-6, S3-7); **O2** makes the merge request/response pair first-class (`merge-request` op + `mergeRequested` state) and hardens `shipped`/`synced` (S1-3, S2-1, S2-2); **O3** owns the bare-parent borrow lifecycle via daemon `borrow`/`release` ops (agent still merges); **O4** generalizes the remote name off hardcoded `origin` via `git remote`. Daemon **never mutates refs** — borrow/release create worktrees, not commits.

**Tech Stack:** Swift 6 (strict concurrency, actors), Swift Testing (`@Suite`/`@Test`/`#expect`), real-git fixtures (no mocking), SwiftUI (App + App-iOS). MCP/CLI verbs on `OrchestraService`.

## Global Constraints

- **Daemon never mutates refs.** Every `Proc` git verb audited to config/rev-parse/merge-base/rev-list/ls-remote/fetch/worktree-add only. `borrow`/`release` create/sweep worktrees, never commits. (Spec §d)
- **Design for BOTH Claude and Codex.** No `if agent == "claude"` in shared code; use the capability/adapter seam. Skill guidance substance must be equal for both; mirror `.claude/commands/ship.md` fixes into repo-root `AGENTS.md`. (CLAUDE.md, S1-4)
- **Wire-safe schema changes only.** New `Codable` fields get defaults so old payloads decode (docs/03). `TreeNode.base`, new `TreeState` cases, etc. must default.
- **Preserve the spec §(d) "what's good — don't touch" list.** git-config SSOT, derived parent card, tree-not-DAG, core git model (merge-down/`rebase --onto`/squash-at-ship + recorded base OID), "daemon never touches refs", RemoteParents hardening, detection-ladder epistemics, restart durability, fail-safe degradation, cycle guard, parent-relative diffs, the test suite. Changes must not regress these verified properties.
- **The report wins** where it and the brief conflict. Flag spec ambiguities resolved, in the final summary.
- **Test discipline:** every S1/S2 fix lands with the test the report says is missing; real-git fixtures; `swift test` clean. The two real-tmux suites may flake with `"fork failed: Device not configured"` — ignore ONLY that signature.
- **iOS-touch rule:** if a task touches `App-iOS/` (or shared iOS kit), run `scripts/typecheck-kit-ios.sh` + `scripts/typecheck-ios-ui.sh` UNSANDBOXED under the default Xcode toolchain before marking it done.
- **Scratch** in `./.scratch/`. Never touch `main`, `mobile-impl-orchestration`, or `plan/parent-card-branch-linking`. Disposable isolated daemons only.
- **Commit per checklist step, early and often**, messages keyed to finding IDs (`fix(s1-1): …`, `feat(o2): …`).

---

## File Structure (what each touched file owns)

**Daemon core (`Sources/OrchestraCore/`)**
- `BranchLineage.swift` — `ParentLink` struct (gains `resolvableRef`, O1); git-config CRUD; `set` partial-write restore (S4); `classify` deleted (O4/S4).
- `OrchestraService+Tree.swift` — `setParent`, `recordSpawnBase`, `synced`, `shipped`, `tree`, `recomputeTreeStat`, `computeTreeStat`, `treeTip`/`mergeBaseOID` helpers. Bulk of S1-1, S1-2, S1-3, S2-1, S2-2, S2-4, S2-7, S2-9, S3-1, S3-5, S3-6, S3-7.
- `OrchestraService+MergeRequest.swift` — **new**; `mergeRequest`, re-nudge timer, dedup (O2/S2-5).
- `OrchestraService+Borrow.swift` — **new**; `borrow`/`release` ops + orphan prune (O3).
- `OrchestraService+Remote.swift` — watch-loop, `remoteMergeStep`, `applyRemoteRedirect`; S1-5 (async gh gating), S2-8, S3-1, S4 (redirect watch, comment drift).
- `OrchestraService+ParentRef.swift` — `resolvedParentRef` becomes an O1 forwarder.
- `OrchestraService.swift` — spawn base validation + rollback (S2-3); archive tree-awareness + debounce cancel (S2-5, S3-5); borrow prune on startup/archive (O3).
- `GhProbe.swift` / new `GhActor` — async `GhClient` off the service actor (S1-5).
- `RemoteParents.swift` — threaded remote name (O4).
- `RemoteParentRef.swift` — remote-name generalization + disjoint pr/branch namespaces (O4, S4).
- `WorktreeManager.swift` — borrow-path worktree at canonical `orch-borrow-*` (O3).

**Model (`Sources/OrchestraKit/Model.swift`)** — `TreeNode.base` (S2-4); `TreeState.mergeRequested` wired, `parentMerged` wired/dropped (S1-3/O2/S4).

**CLI (`Sources/orchestra/`)** — `CLIHelp.swift` (`shipped`, `set-parent --watch/--mode`, `merge-request`, `borrow`/`release` — S4); arg wiring for new verbs.

**UI (`App/`, `App-iOS/`)** — `SpawnSheet.swift` ×2 (S3-2); `CardView.swift`/`BoardCardCell.swift` (S3-3 badge legend/labels, chip select-only); `DiffInspectorView.swift`/`CardDetailModel.swift` (S3-3 "Parent (branch)" label); waiting badge for `mergeRequested` (O2).

**Docs** — `.claude/commands/ship.md`, `.claude/skills/**/tree-skill.md`, `tree-agents.md`, repo-root `AGENTS.md`, `CODEX_HOME/AGENTS.md` (S1-2, S1-4, S3-4, O3 conflict guidance); `TreeDocs.forAgent` composer if guidance is generated. Layered docs `notes/designs/parent-card-branch-linking/0{1,2,3,4}-*.md` (doc-drift pass).

**Tests (`Tests/OrchestraCoreTests/`)** — extend `TreeStatTests`, `ShipChoreoTests`, `SpawnRaceTests`, `RedirectMechanicsTests`, `SetParentRemoteTests`, `LadderTests`, `RemoteWatchLoopTests`, `TreeCommandTests`; new `MergeRequestTests`, `BorrowLifecycleTests`, `RemoteRecomputeTests`.

---

## Task 0: Baseline — confirm green before touching anything

- [ ] **Step 1:** Run the full suite to confirm the reported 631/0 baseline in this worktree.
  Run: `swift test 2>&1 | tail -30`
  Expected: 0 failures (real-tmux suites may flake only with `fork failed: Device not configured`).
- [ ] **Step 2:** No commit (baseline only). Record the count in the final summary.

---

## Checklist Step 1 — S1-1 remote resolution in TreeStat/`synced`, as O1

### Task 1a: O1 — `ParentLink.resolvableRef` + `resolvedParentRef` forwarder

**Files:**
- Modify: `Sources/OrchestraCore/BranchLineage.swift` (`ParentLink`)
- Modify: `Sources/OrchestraCore/OrchestraService+ParentRef.swift`
- Test: `Tests/OrchestraCoreTests/LineageModelTests.swift` (add cases)

**Interfaces:**
- Produces: `ParentLink.resolvableRef: String` — local → `refs/heads/<parent>`, remote → `RemoteParentRef.parse(parent)!.privateRef`. Pure, no I/O.
- Produces: `OrchestraService.resolvedParentRef(_:Task) -> String?` — forwarder returning the same mapping from `task.parentBranch` (now yields `refs/heads/<b>` for local, closing S3-6 tag-shadowing for diff consumers too).

- [ ] **Step 1: Write the failing test** in `LineageModelTests.swift`:
```swift
@Test("resolvableRef maps local → refs/heads and remote → private ref")
func resolvableRef() {
    #expect(ParentLink(parent: "feature-a", base: "x").resolvableRef == "refs/heads/feature-a")
    #expect(ParentLink(parent: "pr#7", base: "x").resolvableRef == "refs/orch/parents/pr-7")
    #expect(ParentLink(parent: "origin/feature-b", base: "x").resolvableRef == "refs/orch/parents/feature-b")
}
```
- [ ] **Step 2: Run to verify it fails** (`resolvableRef` undefined).
  Run: `swift test --filter LineageModelTests 2>&1 | tail -15`
- [ ] **Step 3: Implement** `resolvableRef` on `ParentLink`:
```swift
/// The concrete git ref every daemon git verb resolves against (O1). Local parents pin
/// `refs/heads/<name>` (defeats tag shadowing, S3-6); remote parents map to the fetched private
/// ref. The canonical `parent` string stays storage/display-only.
public var resolvableRef: String {
    RemoteParentRef.parse(parent)?.privateRef ?? "refs/heads/\(parent)"
}
```
- [ ] **Step 4:** Rewrite `resolvedParentRef` as a forwarder using the same rule (drop the raw-name return):
```swift
func resolvedParentRef(_ task: Task) -> String? {
    guard let pb = task.parentBranch, !pb.isEmpty else { return nil }
    return RemoteParentRef.parse(pb)?.privateRef ?? "refs/heads/\(pb)"
}
```
- [ ] **Step 5: Run tests** — `LineageModelTests` pass; then `swift test --filter Diff` to confirm diff consumers still baseline correctly against `refs/heads/<b>`.
- [ ] **Step 6: Commit** — `fix(o1): ParentLink.resolvableRef seam; resolvedParentRef forwarder`

### Task 1b: S1-1 — route TreeStat + `synced` + local git helpers through `resolvableRef`

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift` (`computeTreeStat:317`, `synced:128`, `treeTip`, `mergeBaseOID` callers, `set-parent move` existence check `:48`, adopt `mergeBaseOID :66`)
- Test: new `Tests/OrchestraCoreTests/RemoteRecomputeTests.swift` (**the missing S1-1 test — write FIRST**)

**Interfaces:**
- Consumes: `ParentLink.resolvableRef` (Task 1a).

- [ ] **Step 1: Write the failing test** `RemoteRecomputeTests.swift` (real bare origin via `RemoteParentTests.makeOriginWithPR`, `TestEnv.makeReal`):
```swift
@Test("recompute on a pr# parent card resolves the private ref → inSync, parentIsRemote true")
func remoteParentRecomputeInSync() async throws {
    let (svc, _, _, base) = TestEnv.makeReal()
    let repo = base + "/repos/app"
    _ = try RemoteParentTests.makeOriginWithPR(repoDir: repo)
    let card = try await svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
    await svc.recomputeTreeStat(card.id)                 // the funnel's ~750ms recompute
    let ts = try #require(await svc.list().first { $0.id == card.id }?.treeStat)
    #expect(ts.state == .inSync)                          // was .restackNeeded (false red) before the fix
    #expect(ts.parentIsRemote == true)                   // was dropped before the fix
}

@Test("synced on a pr# parent card records the private-ref tip (no 'parent ref not found')")
func syncedRemoteParent() async throws {
    // spawn pr#7 child; advance the private ref by re-fetch is out of scope — just assert synced succeeds
    // and records merge-base(child, refs/orch/parents/pr-7). See Task 6a for the merge-base assertion.
    ...
}
```
- [ ] **Step 2: Run to verify it fails** — `restackNeeded` / `parent ref not found: pr#7`.
  Run: `swift test --filter RemoteRecomputeTests 2>&1 | tail -20`
- [ ] **Step 3: Implement.** In `computeTreeStat(repo:link:)` use `link.resolvableRef` for the tip lookup:
```swift
guard !link.base.isEmpty, let tip = treeTip(repo: repo, link.resolvableRef) else {
    return TreeStat(state: .restackNeeded, parentIsRemote: RemoteParentRef.parse(link.parent) != nil)
}
...
// set parentIsRemote on EVERY constructed TreeStat in this function
let isRemote = RemoteParentRef.parse(link.parent) != nil
if !treeBaseIsAncestor(...) { return TreeStat(state: .restackNeeded, behind: behind, parentIsRemote: isRemote) }
return TreeStat(state: behind == 0 ? .inSync : .stale, behind: behind, parentIsRemote: isRemote)
```
- [ ] **Step 4:** In `synced`, resolve via `link.resolvableRef` (drop the `link.parent` bare pass); this also lets `synced` run for `pr#N`. (The merge-base recording is Task 6a — for now just resolve the ref.)
- [ ] **Step 5:** Pin `set-parent move` existence check + adopt `mergeBaseOID` to `refs/heads/` (S3-6). For `move`: `treeTip(repo: t.repo, "refs/heads/\(p)")`; for adopt/move `mergeBaseOID`, pass `"refs/heads/\(t.branch)"` and `"refs/heads/\(p)"`.
- [ ] **Step 6: Run** `swift test --filter RemoteRecomputeTests` + `--filter TreeStat` + `--filter SetParent` — all pass.
- [ ] **Step 7: Commit** — `fix(s1-1,s3-6): resolve remote+local parents via resolvableRef in TreeStat/synced/move`

---

## Checklist Step 2 — S1-2 root-ship retarget fallback + docs call `shipped`

### Task 2: S1-2 — unconditional retarget with default-branch fallback

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift` (`shipped:155,174`)
- Modify: `.claude/commands/ship.md`, `.claude/skills/**/tree-skill.md`, repo-root `AGENTS.md` (main path calls `shipped` when children exist)
- Test: `Tests/OrchestraCoreTests/ShipChoreoTests.swift`

**Interfaces:**
- Consumes: a `defaultBranch(repo:)` helper — reuse existing if present (grep `defaultBranch`/`symbolic-ref`), else add one reading `git symbolic-ref --short refs/remotes/origin/HEAD` with a `main`/`master` fallback.

- [ ] **Step 1: Write the failing test** — `main → A → B`, A ships to main (A has no parent link), B must leave `inSync`-forever:
```swift
@Test("root ship retargets children onto the default branch (goal-4)")
func rootShipRetargetsChildren() async throws {
    // build main→A→B with real branches + lineage; A has NO parent link (root)
    // call svc.shipped(A); expect B's lineage parent is now the default branch (or link cleared)
    // and B's treeStat is restackNeeded, NOT inSync-forever.
}
```
- [ ] **Step 2: Run to verify it fails.** Run: `swift test --filter ShipChoreo 2>&1 | tail -20`
- [ ] **Step 3: Implement.** Make retarget unconditional; when the shipped card has no link, use the default branch as grandparent, and **clear** children's links (they become plain default-branch cards — the truth):
```swift
let defaultBr = defaultBranch(repo: child.repo)
let grandparent = link?.parent ?? defaultBr
let clearingToDefault = (link?.parent == nil)   // root ship → children become plain main-based
// in the retarget loop: if clearingToDefault, lineage.clear(gcBranch) + parentBranch=nil + treeStat=nil;
// else repoint to grandparent as today.
```
  Guard the retarget on `grandparent` being resolvable; when clearing, still set `treeStat` to reflect reality (nil, recompute later).
- [ ] **Step 4:** Stop `shipped` warning "no recorded parent link" as an anomaly (S3-1 overlap) — downgrade to `.info` or omit when retargeting proceeded.
- [ ] **Step 5:** Edit ship.md main path (step 2) + tree-skill main path: "if `orchestra tree` shows children, run `orchestra shipped <you>` so they get retargeted" (previously "Do not call `orchestra shipped`"). Mirror into repo-root `AGENTS.md`.
- [ ] **Step 6: Run** `swift test --filter ShipChoreo` — pass.
- [ ] **Step 7: Commit** — `fix(s1-2): root ship retargets/clears children; docs call shipped when children exist`

---

## Checklist Step 3 — S1-3 notify+wake the shipped child; skip parent echo

### Task 3: S1-3 — tell the shipped child its merge landed (folded into O2 in Step 6b)

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift` (`shipped` step (a), (c))
- Test: `Tests/OrchestraCoreTests/ShipChoreoTests.swift`

- [ ] **Step 1: Write the failing test** — assert the CHILD gets an inbox enqueue + wake, and the parent card is NOT echoed when the `shipped` caller is the parent:
```swift
@Test("live-parent ship notifies+wakes the child, skips the parent self-echo")
func shippedNotifiesChild() async throws {
    // main→P→C, P is a live card, C is a live card. Parent P calls shipped(C).
    // expect: C's inbox gains "your branch landed in P — verify and archive"; C is woken.
    // expect: P (the caller/parent) is NOT enqueued a "child merged into you" echo.
}
```
- [ ] **Step 2: Run to verify it fails.** Run: `swift test --filter ShipChoreo 2>&1 | tail -20`
- [ ] **Step 3: Implement.** Add step (d): `inbox.enqueue(child.id, "your branch landed in \(parent) — verify and archive yourself")` + `await wake(child.id)`, BEFORE clearing the child's lineage. Skip the parent echo (step (a)) when the caller is the parent — thread a `caller` hint or compare the resolved caller card. Minimal: detect "caller is the parent card" by whether `source` carries the parent's identity; if not available, gate the echo on `parentCard.id != <shipped-invoker>` — resolve via a new optional `by: UUID?` param on `shipped` that the parent's skill flow passes (`orchestra shipped <child>` run from the parent card injects the parent card id via the RPC session). If threading the caller is heavy, fall back to: still notify child (d); keep parent notify but reword to not read as a wasted wake. **Decision to confirm at impl: prefer the `by:` caller param.**
- [ ] **Step 4:** Surface a "merge pending/landed" state on the child — deferred to O2 Task 6b (`mergeRequested`/`parentMerged`).
- [ ] **Step 5: Run** `swift test --filter ShipChoreo` — pass.
- [ ] **Step 6: Commit** — `fix(s1-3): shipped notifies+wakes child, skips parent self-echo`

---

## Checklist Step 4 — S1-4 repo-root AGENTS.md tree-aware ship

### Task 4: S1-4 — mirror ship.md step 2 into repo-root `AGENTS.md`

**Files:** Modify: repo-root `AGENTS.md` (Codex `/ship` recipe).

- [ ] **Step 1:** Read repo-root `AGENTS.md`; find the unconditional "**Merge to main**" ship recipe.
- [ ] **Step 2:** Insert ship.md's step-2 logic: resolve the parent; if the parent is another branch (stacked child), send the merge-request to the parent instead of merging to main; only main-parent cards take the merge-to-main flow. Keep wording consistent with the Codex tree *section* (resolve the contradiction the report flags).
- [ ] **Step 3:** Verify the two Codex-visible instructions (`AGENTS.md` recipe + tree section, and `CODEX_HOME/AGENTS.md`) now agree.
- [ ] **Step 4: Commit** — `fix(s1-4): repo-root AGENTS.md gets the tree-aware ship recipe (Codex)`

---

## Checklist Step 5 — S1-5 async GhClient off the service actor

### Task 5: S1-5 — make `GhClient` async + gate `gh pr view` on movement

**Files:**
- Modify: `Sources/OrchestraCore/GhProbe.swift` (protocol → async; probe runs on its own actor / detached)
- Modify: `Sources/OrchestraCore/OrchestraService+Remote.swift` (`remoteMergeStep` awaits; gate `gh pr view` on `moved || tip == .gone`)
- Modify: `Tests/OrchestraCoreTests/LadderTests.swift` (`FakeGh` async), `RemoteWatchLoopTests.swift`
- Test: extend `LadderTests` — assert `gh pr view` is NOT consulted when the tip didn't move and isn't gone.

**Interfaces:**
- Produces: `protocol GhClient: Sendable { var available: Bool { get }; func prState(...) async -> PrState?; func prNumber(...) async -> Int?; func editBase(...) async -> Bool }`.
- `GhProbe` methods become `async` and run their blocking `Proc.run` via `Task.detached`/a dedicated `actor GhActor` so they never block the `OrchestraService` actor.

- [ ] **Step 1: Write the failing test** in `LadderTests` — a `CountingFakeGh` that records `prState` call count; drive `remoteMergeStep` on a card whose tip did NOT move and is not gone; assert `prState` was NOT called.
- [ ] **Step 2: Run to verify it fails** (today gh runs every tick). Run: `swift test --filter Ladder 2>&1 | tail -20`
- [ ] **Step 3: Implement** async protocol; move `Proc.run` off the actor (detached). Update `FakeGh` to async. In `remoteMergeStep`, only enter tier (a) when `moved || tip == .gone` (also enter (a) on first tick if `fetchedTip == nil`? — keep PR detection working: PR heads don't move on merge, so tier (a) MUST still run for PR cards each tick. **Resolve:** gate `gh pr view` on `moved || tip == .gone || link.prNumber != nil` — i.e. PR cards still poll (that's the only merge signal), branch cards only on movement. This preserves S1-5's traffic-halving for `origin/<b>` cards without breaking PR detection.)
- [ ] **Step 4:** Confirm no `await gh.*` executes inside a held-actor hot path (list/spawn/send unaffected). Add a note in the summary.
- [ ] **Step 5: Run** `swift test --filter Ladder --filter RemoteWatch` — pass.
- [ ] **Step 6: Commit** — `fix(s1-5): async GhClient off the service actor; gate gh pr view on movement/PR`

---

## Checklist Step 6 — S2-1 merge-base, S2-2 sanity gate, S2-9 debounce cancel (O2)

### Task 6a: S2-1 — `synced` records merge-base, not the parent tip

**Files:** Modify: `OrchestraService+Tree.swift` (`synced:131`). Test: `TreeStatTests`/`RemoteRecomputeTests`.

- [ ] **Step 1: Write the failing test** — parent advances between merge and `synced`; assert recorded base == `merge-base(child-HEAD, resolvable-parent)`, NOT the parent tip (so a later parent move is not silently swallowed):
```swift
@Test("synced records merge-base(child,parent) — an over-eager tip isn't over-recorded")
func syncedRecordsMergeBase() async throws {
    // child merged parent@base0 down; parent then advanced to base1 BEFORE synced is called.
    // synced must record merge-base(child, parent) == base0-side, so treeStat stays stale (behind>0),
    // not falsely inSync.
}
```
- [ ] **Step 2: Run to verify it fails.** Run: `swift test --filter TreeStat 2>&1 | tail -20`
- [ ] **Step 3: Implement:** replace `updateBase(oid: tip)` with `oid: mergeBaseOID(repo: t.repo, "refs/heads/\(t.branch)", link.resolvableRef)`. After an honest merge-down this equals the merged tip; after a racy/bogus call it equals the true sync point.
- [ ] **Step 4: Run** — pass; confirm the existing `syncedRoundTrip` still passes (honest merge ⇒ base == tip).
- [ ] **Step 5: Commit** — `fix(s2-1): synced records merge-base, not the unverified parent tip`

### Task 6b: S2-2 sanity gate + S1-3 child notify — folded into O2 `merge-request`

**Files:**
- Create: `Sources/OrchestraCore/OrchestraService+MergeRequest.swift`
- Modify: `Sources/OrchestraKit/Model.swift` (`TreeState.mergeRequested`; wire `parentMerged`)
- Modify: `OrchestraService+Tree.swift` (`shipped` gate + clear mergeRequested)
- Modify: `Sources/orchestra/*` (CLI verb), MCP tool registration
- Test: new `Tests/OrchestraCoreTests/MergeRequestTests.swift`; `ShipChoreoTests`

**Interfaces (O2):**
- Produces: `func mergeRequest(child ref: String, source:) async throws -> Task` — daemon composes the canonical merge-request prose (one text, not two skill paraphrases), enqueues it to the parent card, records `mergeRequested` on both cards' `treeStat`, dedups on re-send, and arms a re-nudge timer. Cleared by `shipped`.
- Produces: `TreeState.mergeRequested` (child waiting on parent) — wired into the badge switch; `parentMerged` (S4 dead case) wired as the child's landed state or dropped.

- [ ] **Step 1: Write the failing tests** in `MergeRequestTests`:
```swift
@Test("merge-request records mergeRequested on both cards + nudges the parent")
@Test("re-sent merge-request dedups (no duplicate parent nudge)")
@Test("shipped clears the child's mergeRequested state")
@Test("shipped refuses to retarget when the parent tip has not advanced past the child's base (S2-2 gate)")
```
  For the S2-2 gate: build a tree where the parent never merged (parent tip == child recorded base); assert `shipped` does NOT retarget grandchildren / does NOT clear lineage (or requires `force: true`), and emits a warning.
- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter MergeRequest 2>&1 | tail -20`
- [ ] **Step 3: Implement** `mergeRequest` op + state. Add `TreeState.mergeRequested` (Codable — enum string case, wire-safe). Compose prose in the daemon.
- [ ] **Step 4: Implement the S2-2 gate** in `shipped`: before retarget, compute `rev-list --count <child-base>..<parentTip>` via resolvable refs; if `0` (nothing merged since last sync), refuse unless `force` — emit a warning, do NOT clear/retarget. Add a `force: Bool = false` param.
- [ ] **Step 5:** Fold S1-3's child-notify + parent-echo-skip here (supersedes Task 3's minimal form if not already landed): child gets the landed notify; `shipped` skips the parent echo when caller is the parent; clears `mergeRequested`.
- [ ] **Step 6:** Register the CLI/MCP verb; add to `CLIHelp.swift`.
- [ ] **Step 7: Run** `swift test --filter MergeRequest --filter ShipChoreo` — pass.
- [ ] **Step 8: Commit** — `feat(o2): first-class merge-request op + mergeRequested state + shipped sanity gate (s2-2,s1-3)`

### Task 6c: S2-9 — `synced` cancels its debounce slot + edges against the store value

**Files:** Modify: `OrchestraService+Tree.swift` (`synced`, `recomputeTreeStat`). Test: `TreeStatTests`.

- [ ] **Step 1: Write the failing test** — schedule a recompute (funnel), then call `synced` immediately; assert no spurious `inSync→stale` nudge lands in the child's inbox and the persisted stat is `inSync`.
- [ ] **Step 2: Run to verify it fails** (structurally — may need a deterministic trigger; use `scheduleTreeStat` then `synced` without awaiting the debounce).
- [ ] **Step 3: Implement:** in `synced`, `treeStatDebounce[t.id]?.cancel(); treeStatDebounce[t.id] = nil` before recompute (or route through `scheduleTreeStat` after cancel). In `recomputeTreeStat`, compute the nudge edge against the store value read INSIDE the `store.update` closure, not the value captured at entry.
- [ ] **Step 4: Run** `swift test --filter TreeStat` — pass.
- [ ] **Step 5: Commit** — `fix(s2-9): synced cancels its debounce slot; edge computed inside store.update`

---

## Checklist Step 7 — S2-3 spawn base validation + dangling cycle guard + rollback; S2-4 TreeNode.base

### Task 7a: S2-3 — validate/normalize base before `ensure`; dangling-link cycle guard; rollback

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (spawn, before `worktrees.ensure`)
- Modify: `Sources/OrchestraCore/BranchLineage.swift` (`ancestors`/cycle-guard treats a dangling parent as terminal)
- Test: `Tests/OrchestraCoreTests/SpawnRaceTests.swift`

- [ ] **Step 1: Write the failing tests:**
```swift
@Test("spawn with a user-supplied refs/-prefixed local base does not double-prefix (no refs/heads/refs/heads)")
@Test("dangling orchestra-parent value (branch -D'd then name reused) does not false-positive the cycle guard")
@Test("a lineage-record failure rolls back the just-created worktree + branch (no orphan)")
```
- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter SpawnRace 2>&1 | tail -20`
- [ ] **Step 3: Implement:**
  - In `spawn`, before `ensure`: strip/reject a user-supplied `refs/…` local base (remote forms already parsed). Normalize so `recordSpawnBase` resolving `refs/heads/\(base)` never becomes `refs/heads/refs/heads/foo`.
  - In `BranchLineage`'s cycle-guard walk (`ancestors`), treat a link whose parent branch no longer exists (`refs/heads/<parent>` doesn't resolve AND parent isn't remote) as dangling — stop the walk instead of extending it. (Needs repo access in `ancestors`; it already takes `repo`.)
  - On lineage-record failure (the `recordSpawnBase`/`recordSpawnRemoteBase` throws after `ensure`), roll back: `worktrees.remove(force:true)` the just-cut worktree AND delete the branch when THIS spawn created it (`ensured.branchExisted == false`).
- [ ] **Step 4: Run** `swift test --filter SpawnRace --filter Lineage` — pass.
- [ ] **Step 5: Commit** — `fix(s2-3): spawn base validation + dangling-link cycle guard + orphan rollback`

### Task 7b: S2-4 — add `TreeNode.base`, render in CLI

**Files:** Modify: `Sources/OrchestraKit/Model.swift` (`TreeNode`); `OrchestraService+Tree.swift` (`tree` builds `base`); `Sources/orchestra/*` (CLI render). Test: `TreeCommandTests`.

- [ ] **Step 1: Write the failing test** — `orchestra tree` on a linked child exposes the recorded base OID.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement:** add `public let base: String?` to `TreeNode` (default-tolerant init — new field, wire-safe); populate from `link?.base` in `tree`; render in the CLI output; document the `git config --get branch.<b>.orchestra-parent-base` fallback in the skills (folds into Step 10 doc pass).
- [ ] **Step 4: Run** `swift test --filter TreeCommand` — pass.
- [ ] **Step 5: Commit** — `fix(s2-4): TreeNode.base + CLI render — the rebase anchor is recoverable`

---

## Checklist Step 8 — S2-7 adopt/clear; S2-8 + S3-1 warning latch/copy; S3-5 archived guard

### Task 8a: S2-7 — adopt recomputes + stops watch; clear nulls treeStat

**Files:** Modify: `OrchestraService+Tree.swift` (`setParent` adopt `:66-71`, clear `:75`). Test: `SetParentRemoteTests`/new cases.

- [ ] **Step 1: Write the failing tests** — after local adopt, treeStat is recomputed (not the previous parent's stale badge) and any remote watch is stopped; after clear, `treeStat == nil`.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement:** adopt arm → `scheduleTreeStat(t.id)` + `stopRemoteWatch(t.id)`; clear arm → set `$0.treeStat = nil` in the `store.update`.
- [ ] **Step 4: Run** — pass.
- [ ] **Step 5: Commit** — `fix(s2-7): set-parent adopt recomputes+stops watch; clear nulls treeStat`

### Task 8b: S2-8 — closed-unmerged PR signal + gone-tier wording + editBase warn

**Files:** Modify: `OrchestraService+Remote.swift` (`remoteMergeStep`, `applyRemoteRedirect`). Test: `LadderTests`.

- [ ] **Step 1: Write the failing tests** (FakeGh with `state: CLOSED, merged: false`): assert an activity "parent PR closed without merging — pick a new base" is emitted; assert the gone-tier wording consults gh state (not always "likely merged"); assert `editBase` failure warns.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement:** emit on `state == CLOSED && !merged`; thread the gh state into the gone-tier wording; warn on `editBase` returning false. (These now `await gh.*` per Task 5.)
- [ ] **Step 4: Run** `swift test --filter Ladder` — pass.
- [ ] **Step 5: Commit** — `fix(s2-8): closed-unmerged PR signal; gh-aware gone wording; editBase warn`

### Task 8c: S3-1 — latch the gone warning; downgrade bare-parent notify miss

**Files:** Modify: `OrchestraService+Remote.swift` (gone warn `:48-52`); `OrchestraService+Tree.swift` (`:165-167` notify miss). Add a per-card latch set. Test: `LadderTests`/`RemoteWatchLoopTests`.

- [ ] **Step 1: Write the failing test** — two consecutive gone ticks emit the warning ONCE; latch clears on set-parent / tip reappearing.
- [ ] **Step 2: Run to verify it fails** (today re-emits every tick).
- [ ] **Step 3: Implement:** add `var warnedGone: Set<UUID>` on the service; emit only on first entry; clear on `set-parent`/tip reappear. Downgrade the bare-parent "no active card owns parent" to `.info`.
- [ ] **Step 4: Run** — pass.
- [ ] **Step 5: Commit** — `fix(s3-1): latch gone warning; downgrade bare-parent notify miss to info`

### Task 8d: S3-5 — archived-card recompute guard + cancel debounces on archive

**Files:** Modify: `OrchestraService+Tree.swift` (`recomputeTreeStat:249` guard); `OrchestraService.swift` (`archive:574` cancels both debounce slots). Test: new cases in `TreeStatTests`/archive tests.

- [ ] **Step 1: Write the failing test** — a card archived inside the 750ms debounce window gets NO post-archive treeStat rewrite / emit / nudge.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement:** add `!t.archived` to `recomputeTreeStat`'s guard; in `archive()`, `treeStatDebounce[id]?.cancel(); treeStatDebounce[id] = nil; childFanoutDebounce[id]?.cancel(); childFanoutDebounce[id] = nil`.
- [ ] **Step 4 (S2-5 minimal): archive is tree-aware** — when a worktree card archives, nudge its live child cards ("parent card archived — parent branch is now bare; re-run your ship"), so a stopped child re-evaluates instead of waiting on a rotted inbox. Add a test: archiving a parent card enqueues+wakes its live children.
- [ ] **Step 5: Run** — pass.
- [ ] **Step 6: Commit** — `fix(s3-5,s2-5): guard recompute on archived; cancel tree debounces + nudge live children on archive`

---

## Checklist Step 9 — S3-2 spawn-sheet; S3-3 labels/tooltips; S3-4 align docs; S3-6 (done in Step 1); S3-7 nudge refs

### Task 9a: S3-7 — route nudge rebase targets through resolvableRef; guard empty base + remote grandparent

**Files:** Modify: `OrchestraService+Tree.swift` (`shipped` retarget nudge `:201-203`, `move` nudge `:60`); `OrchestraService+Remote.swift` (redirect nudge). Test: `RedirectMechanicsTests`.

- [ ] **Step 1: Write the failing tests** — retarget onto a REMOTE grandparent writes `git rebase --onto <resolvable-ref> <oid>` (not `pr#N`); an empty kept base skips the command text (no malformed `rebase --onto X `).
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement:** compute the nudge `--onto` target via the grandparent link's `resolvableRef`; when `gcLink.base` is empty, emit a "re-establish your base" nudge without the `rebase` command; guard `shipped` retarget on remote grandparents so `prNumber`/`watch` are preserved in the rewritten link.
- [ ] **Step 4: Run** `swift test --filter Redirect` — pass.
- [ ] **Step 5: Commit** — `fix(s3-7): nudge rebase targets via resolvableRef; guard empty base + remote grandparent`

### Task 9b: S3-2 — spawn-sheet remote entry UX (desktop + iOS)

**Files:** Modify: `App/Views/SpawnSheet.swift`, `App-iOS/Views/SpawnSheet.swift`. **iOS-touch → run both typecheck scripts.**

- [ ] **Step 1:** Disable/annotate the local base picker while the remote text field is non-empty (make precedence visible).
- [ ] **Step 2:** Clear `remoteBase` on repo change (both platforms).
- [ ] **Step 3:** Keep the sheet OPEN on spawn failure (desktop `:317` unconditional close; iOS `:494` pre-RPC dismiss) — dismiss only on success.
- [ ] **Step 4:** Inline parse-validate the remote field (`RemoteParentRef.parse`), surfacing a syntax hint; make `pr#` parse case-insensitive (`PR#12`/`pr12` teachable — update `RemoteParentRef.parse` accordingly + a unit test in `RemoteParentRefTests`).
- [ ] **Step 5:** Typecheck: `scripts/typecheck-kit-ios.sh` + `scripts/typecheck-ios-ui.sh` (UNSANDBOXED, default toolchain). Build the desktop app if a quick `swift build` covers `App/`.
- [ ] **Step 6: Commit** — `fix(s3-2): spawn-sheet remote-entry precedence/clear/keep-open/parse-hint (+case-insensitive pr#)`

### Task 9c: S3-3 — badge/baseline legibility for the human

**Files:** Modify: `App-iOS/Views/BoardCardCell.swift` (badge tooltip/legend), `App/Views/CardView.swift` (`.help` copy `:219`, chip select-only `:188`), `App/Views/DiffInspectorView.swift`/`CardDetailModel.swift` (`:349`/`:65` "Parent (branch)" label). **iOS-touch → typecheck.**

- [ ] **Step 1:** iOS badges (`↓N`, restack glyph) gain a long-press/legend explaining the state (human-directed copy, not "run `orchestra synced`").
- [ ] **Step 2:** Desktop `.help` reworded human-directed; diff toggle shows "Parent (feature-a)" with the branch name; label the parent-relative diffstat so two adjacent cards' `+N −M` against different baselines is legible.
- [ ] **Step 3:** Desktop chip-click → select-only (match iOS's lighter behavior), not "enter the parent's terminal".
- [ ] **Step 4:** Typecheck both iOS scripts + build App.
- [ ] **Step 5: Commit** — `fix(s3-3): human-directed badge/tooltip copy + Parent(branch) diff label + select-only chip`

### Task 9d: S3-4 — align `/ship` vs tree-skill on remote parents

**Files:** Modify: `.claude/commands/ship.md`, `.claude/skills/**/tree-skill.md`.

- [ ] **Step 1:** ship.md's "remote parent out of scope; stop and report" → defer to the skill's publish flow (`git push -u`, `gh pr create --base <parentHeadRef>`).
- [ ] **Step 2:** Confirm the two instructions no longer disagree in one worktree.
- [ ] **Step 3: Commit** — `fix(s3-4): align ship.md to tree-skill's remote-parent publish flow`

---

## Checklist Step 10 — S4 debt batch + O3 + O4 + coverage gaps + doc-drift

### Task 10a: O3 — own the bare-parent borrow lifecycle

**Files:**
- Create: `Sources/OrchestraCore/OrchestraService+Borrow.swift` (`borrow`/`release`)
- Modify: `WorktreeManager.swift` (canonical `orch-borrow-*` path), `OrchestraService.swift` (orphan prune on archive/startup)
- Modify: skills (both variants) — conflict/abort guidance
- Test: new `Tests/OrchestraCoreTests/BorrowLifecycleTests.swift`

- [ ] **Step 1: Write the failing tests** — `borrow` creates/registers a throwaway worktree at a canonical `orch-borrow-<…>` path; `release` sweeps it; an orphaned `orch-borrow-*` is pruned on archive/startup; conflict/abort leaves recoverable state.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** daemon `borrow`/`release` (option (a)): daemon creates/registers/sweeps the worktree; the AGENT performs the merge inside it (daemon never commits). Orphan prune scans for `orch-borrow-*` worktrees with no owning op on archive/startup. Add conflict/abort paragraphs to both TreeDocs skill variants.
- [ ] **Step 4: Run** `swift test --filter Borrow` — pass.
- [ ] **Step 5: Commit** — `feat(o3): daemon borrow/release lifecycle + orphan prune + conflict/abort docs`

### Task 10b: O4 — generalize the remote name off hardcoded `origin`

**Files:** Modify: `RemoteParentRef.swift` (parse consults `git remote`; thread remote through), `RemoteParents.swift` (fetch/ls-remote argv use the parsed remote), delete/wire `BranchLineage.classify`. Test: `RemoteParentRefTests`, `RemoteParentTests`.

**Decision (design owner): generalize-now.** Canonical form already stores the remote name (`origin/feature-b`); parse consults the repo's `git remote` list; thread the parsed remote through fetch/ls-remote; error clearly on an unknown remote. No config migration.

- [ ] **Step 1: Write the failing tests** — `upstream/feat` (a real second remote) parses as remote and fetches from `upstream`; an unknown remote errors clearly (not a silent local degrade).
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement:** `RemoteParentRef.parse(_:remotes:)` (or a repo-aware parse) consults the remote list; `.branch` carries its remote name; `remoteSrc`/fetch/ls-remote thread it. **Delete `BranchLineage.classify`** (dead + disagrees) OR route classification through the one seam — prefer delete since `RemoteParentRef.parse` is load-bearing. Update `RemoteParentRef.privateName`/namespaces for disjoint `pr/<N>` vs `branch/<b>` (S4 namespace-collision).
- [ ] **Step 4: Run** `swift test --filter Remote` — pass.
- [ ] **Step 5: Commit** — `feat(o4): parse consults git remote; thread remote through fetch/ls-remote; delete classify; disjoint pr/branch ns`

### Task 10c: S4 debt batch (each its own micro-commit where it carries a test)

**Files:** across daemon core + `CLIHelp.swift` + `Model.swift`.

- [ ] **parentMerged/mergeRequested dead code** — wired in Task 6b; if `parentMerged` remains unused after O2, drop it. Confirm both badge switches handle the wired case.
- [ ] **TOCTOU at spawn** — record the child branch's OWN tip as the base (not the re-resolved parent tip after the worktree is cut). `OrchestraService.swift:273→291`. Test: `SpawnBaseTests`.
- [ ] **Perpetual redirect watch** — don't watch when `baseRefName` is the default branch (`OrchestraService+Remote.swift:85,114-117`). Test: `RemoteWatchLoopTests`.
- [ ] **CLI help drift** — add `shipped`, `set-parent --watch`/`--mode move`, `merge-request`, `borrow`/`release` to `CLIHelp.swift`. Test: a help-snapshot assertion if one exists.
- [ ] **remoteWatchGen entries never removed** — drop the map entry in `clearRemoteWatch`/`stopRemoteWatch`. (bytes-only; no test.)
- [ ] **Flat base-picker Menu** — make the base picker searchable / add a "spawn child" context-menu affordance. (`SpawnSheet.swift:647-674`.) **iOS-touch if shared → typecheck.**
- [ ] **Comment drift** — fix `+Tree.swift:246` ("layered on later" — they're here + wired now) and `remoteMergeStep`'s step-list (tier (c) warn-onlys, doesn't redirect).
- [ ] **`BranchLineage.set` partial-write** — restore the prior link on partial failure (or distinguish exit codes); `unset` distinguishes exit-5 from real failure so `set(watch:false)` under contention can't silently keep a merge-watch alive. `BranchLineage.swift:74-82`. Test: a fixture holding `.git/config.lock` (report says fixture-confirmable).
- [ ] **No nudge on organic `inSync→restackNeeded`** — decide: nudge the edge (parent amend/rebase with no `shipped`/`set-parent`) or document why not. **Decision: nudge it** (it's the one restack path with no other notifier). `+Tree.swift:258`. Test: `TreeStatTests`.
- [ ] **Multi-await interleave in `shipped`** — re-read the link before the step-(c) clear so a concurrent `set-parent` isn't wiped. `+Tree.swift`.
- [ ] Commit each meaningful sub-item keyed `fix(s4): …` (batch the pure comment/byte fixes into one).

### Task 10d: Coverage gaps + doc-drift pass

**Coverage gaps (04-tests.md):**
- [ ] Remote-parent recompute + `synced` test — **done in Task 1b/6a** (the one that would've caught S1-1).
- [ ] Watch-loop failure/backoff-tick test; replace the tautological GhProbe availability test.
- [ ] Assert the `wake` half of an enqueue+wake pair (at least one nudge test).
- [ ] Bare-parent borrow git mechanics — **done in Task 10a**; daemon-restart durability on a RECONSTRUCTED service instance; diamond-rejection, dirty-tree-abort, archived-parent-fallback tests.

**Doc-drift (update the doc where code is right; fix code where the doc is right):**
- [ ] `02-contract`: `BranchLineage.set` "throws `unknownBranch`" — no existence check in `set` (validation is at the service layer). Fix the doc.
- [ ] Watch loop specified on `RemoteParents`, implemented on `OrchestraService` — benign; note it.
- [ ] Contract ladder text + `remoteMergeStep` docstring say tier (c) redirects — it's warn-only. Fix the three docs (incl. `04-tests`'s "ancestry ⇒ merged/redirect").
- [ ] `shipped` (c) "mark parentMerged" → now real via O2 (or clear-to-nil) — reconcile doc + enum.
- [ ] `03-implementation` "spawn ends with `scheduleTreeStat(id)`" + `04-tests` "spawn asserts treeStat inSync" — neither exists. Fix the docs (treeStat is nil until first report).
- [ ] Skill docs' "recorded base in `orchestra tree`" — now true (Task 7b); confirm wording.
- [ ] Commit — `docs(bt): fix layered-doc drift (contract/impl/tests) to match code + coverage-gap tests`

---

## Self-Review checklist (run after drafting, before impl)

1. **Spec coverage:** every S1-1..S1-5, S2-1..S2-9, S3-1..S3-7, S4 sub-item, O1..O4, each coverage gap, each doc-drift item maps to a task above. (S2-6 1:1 precondition — see note below.)
2. **Placeholder scan:** the two `...` in Task 1b/6a test sketches are finalized at impl (real-git fixture bodies); no "TBD" fixes.
3. **Type consistency:** `resolvableRef` (ParentLink), `resolvedParentRef` (Task forwarder), `mergeRequested`/`parentMerged` (TreeState), `TreeNode.base`, `mergeRequest(child:)`, `borrow`/`release`, `force:` on `shipped` — names used consistently across tasks.

**S2-6 (1:1 precondition) — IN SCOPE, add here:** spawn refusal when a live (non-archived) card already owns the target repo+branch, with jump-to-card; at minimum make derived lookups deterministic (oldest active) + warn on multiplicity. Slot as **Task 10e**, commit `fix(s2-6): spawn refuses onto a branch with a live card (jump-to-card)`. Test: `SpawnRaceTests`.

**Ambiguities to flag in the final summary:**
- S1-5 gh gating: I resolved "gate `gh pr view` on movement" to *also* keep polling PR cards every tick (PR heads don't move on merge — the report itself says so), so the traffic halving applies to `origin/<b>` branch cards only. Report §S1-5 wording could read as gating ALL gh calls; that would break PR detection.
- S1-3 parent-echo-skip needs a caller identity; I plan a `by: UUID?` param threaded from the RPC session. If that plumbing is absent, fall back to rewording the parent notify.
