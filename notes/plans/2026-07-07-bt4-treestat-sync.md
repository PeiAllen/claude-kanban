# BT4 — TreeStat maintenance + sync nudges + `synced` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the live "am I behind my parent?" machinery — daemon-maintained `TreeStat` per child card, a transition-only stale nudge, the `synced` command, and card badges — on top of BT1's lineage core.

**Architecture:** `recomputeTreeStat` derives a child's state (`inSync`/`stale`/`restackNeeded`) from its git-config parent link against local git, persisting + emitting only on change — a twin of the existing `recomputeDiffStat`. A per-card debounce (`scheduleTreeStat`) coalesces recomputes off the normalized `report()` funnel; the funnel also fans out to a moved parent's live children. The `inSync→stale` edge (only) enqueues an inbox nudge + wake. `synced` records the parent tip as the new base. Desktop + iOS card footers render a `↓N` / restack badge off `task.treeStat`.

**Tech Stack:** Swift 6, swift-testing (`#expect`/`@Test`), `Proc.run` git calls, SwiftUI (App + App-iOS), the `OrchestraService` actor.

## Global Constraints

- Branch is based on `plan/parent-card-branch-linking` (already reset). **Never** merge; the orchestrator merges. Never touch `main` or the plan branch.
- **Additive edits only** — BT2 (CommandCatalog/Registry/spawn) and BT3 (`+Diff` baseline) run in parallel; keep changes to one new catalog entry, one new registry entry, one new CLI case, a new debounce dict, new methods in `+Tree.swift`, and the single funnel line. The orchestrator resolves conflicts.
- Design for **both Claude and Codex** — nothing here branches on agent type (the funnel is adapter-agnostic; wake already dispatches per `wakeTransport`).
- `TreeStat` scope is **local parents only**. `parentIsRemote` stays `false` (BT6 wires remote tip resolution); the `parentMerged` state is produced by BT5's `shipped`, not here. `recomputeTreeStat` derives state from git alone.
- `swift test` must pass cleanly.
- Scratch work under `./.scratch/`.

---

## File Structure

**Modify:**
- `Sources/OrchestraCore/OrchestraService+Tree.swift` — add `recomputeTreeStat`, `scheduleTreeStat`, `scheduleChildTreeStats`, `synced`, and private git helpers (`treeTip`/`treeBehind`/`treeBaseIsAncestor`, `computeTreeStat`).
- `Sources/OrchestraCore/OrchestraService.swift` — add the `treeStatDebounce` dict next to `diffStatDebounce`.
- `Sources/OrchestraCore/OrchestraService+Report.swift` — the funnel hook (schedule self + children) at `:139`.
- `Sources/OrchestraKit/CommandCatalog.swift` — the `synced` schema.
- `Sources/OrchestraCore/CommandRegistry.swift` — the `synced` handler.
- `Sources/orchestra/CLIRunner.swift` — the `synced` CLI case.
- `App/Views/CardView.swift` — desktop `treeBadge` in the footer.
- `App-iOS/Views/BoardCardCell.swift` — iOS `treeBadge` in the footer.

**Test (create):**
- `Tests/OrchestraCoreTests/TreeStatTests.swift` — compute cases + shared fixtures + `synced` round-trip.
- `Tests/OrchestraCoreTests/StaleNudgeTests.swift` — transition-only nudge + funnel fan-out.

**Test (modify):**
- `Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift` — add `"synced"` to the hardcoded catalog list.

### Reference: existing patterns to clone
- `recomputeDiffStat` / `scheduleDiffStat` / `clearDiffStatDebounce` — `OrchestraService+Diff.swift:31-67` (idempotent persist+emit + debounce).
- `diffStatDebounce` dict — `OrchestraService.swift:75`.
- Funnel hook site — `OrchestraService+Report.swift:139` (`if saved.origin == .worktree { scheduleDiffStat(id) }`).
- `concludeCard` enqueue+wake idiom — `OrchestraService+Wake.swift:70-71`.
- `setParent` / `tree` service methods — `OrchestraService+Tree.swift` (same file, guard/emit/emitActivity idioms).
- `BranchLineage` API — `Sources/OrchestraCore/BranchLineage.swift` (`read`/`updateBase`/`children`).
- `TreeStat` / `TreeState` model — `Sources/OrchestraKit/Model.swift:160-171` (already present; `Task.treeStat` at `:221`).
- Service test harness — `TestEnv.make()`, `TestEnv.repo(base)`, `env.svc.spawn(SpawnInput(...))`, `env.svc.inboxPeek`, `pollUntil`, `EventCollector` (`DiffServiceTests.swift`, `MoveNotifyTests.swift`, `LineageSpawnTests.swift`).
- `theme.amber` / `theme.red` `SemColor` (dot/text/tint) — `Sources/OrchestraUI/Theme.swift:95-99`.

---

## Task 1: TreeStat compute + debounce

Derive a child's `TreeStat` from its lineage link against local git, persist+emit only on change, and add the coalescing debounce. No nudge yet (Task 2).

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add debounce dict near `:75`)
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift` (add methods + git helpers)
- Test: `Tests/OrchestraCoreTests/TreeStatTests.swift` (create)

**Interfaces:**
- Consumes: `BranchLineage.read(repo:branch:) -> ParentLink?`, `store.get(_:)`, `store.update(_:_:)`, `emit(.taskUpserted(_:))`, `Proc.run`, `TreeStat`/`TreeState` (Model).
- Produces:
  - `func recomputeTreeStat(_ id: UUID) async` — internal; idempotent; persists `Task.treeStat` + emits only on change.
  - `func scheduleTreeStat(_ id: UUID)` — internal; 750ms coalescing debounce.
  - `var treeStatDebounce: [UUID: _Concurrency.Task<Void, Never>]` — internal.
  - private `computeTreeStat(repo:link:) -> TreeStat`, `treeTip(repo:_:) -> String?`, `treeBehind(repo:base:tip:) -> Int`, `treeBaseIsAncestor(repo:base:tip:) -> Bool`.

- [ ] **Step 1: Write the failing tests** — create `Tests/OrchestraCoreTests/TreeStatTests.swift`

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("TreeStat compute — child lineage state vs a real parent branch")
struct TreeStatTests {

    // MARK: shared fixtures (also used by StaleNudgeTests)

    /// A real repo on `main` (one base commit) with a `parent` branch at the same tip. Returns the path.
    static func repoWithParent(_ base: String) throws -> String {
        let repo = TestEnv.repo(base)
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "config", "user.email", "t@t")
        try git(repo, "config", "user.name", "t")
        try write(repo, "a.txt", "0\n")
        try git(repo, "add", "-A")
        try git(repo, "commit", "-q", "-m", "base")
        try git(repo, "branch", "parent")
        return repo
    }

    /// Add `n` commits to `parent` (leaves `main` checked out afterwards). Returns the new `parent` tip.
    @discardableResult
    static func advanceParent(_ repo: String, _ n: Int) throws -> String {
        try git(repo, "checkout", "-q", "parent")
        for i in 0..<n {
            try write(repo, "p\(i)-\(UUID().uuidString).txt", "x")
            try git(repo, "add", "-A")
            try git(repo, "commit", "-q", "-m", "p\(i)")
        }
        let tip = try git(repo, "rev-parse", "parent")
        try git(repo, "checkout", "-q", "main")
        return tip
    }

    @discardableResult
    static func git(_ repo: String, _ a: String...) throws -> String {
        let r = try Proc.run(["git", "-C", repo] + a)
        #expect(r.ok, "git \(a.joined(separator: " ")): \(r.stderr)")
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func write(_ repo: String, _ rel: String, _ s: String) throws {
        try s.write(toFile: repo + "/" + rel, atomically: true, encoding: .utf8)
    }

    /// Spawn a `.worktree` card on `child` linked to `parent` with the given recorded base.
    static func linkedChild(_ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
                            repo: String, base recorded: String) async throws -> Task {
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: recorded))
        return card
    }

    private func treeStat(_ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
                          _ id: UUID) async -> TreeStat? {
        await env.svc.list().first { $0.id == id }?.treeStat
    }

    // MARK: compute cases

    @Test("base == parent tip ⇒ inSync, behind 0")
    func inSync() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let tip = try Self.git(repo, "rev-parse", "parent")
        let card = try await Self.linkedChild(env, repo: repo, base: tip)
        await env.svc.recomputeTreeStat(card.id)
        let ts = try #require(await treeStat(env, card.id))
        #expect(ts.state == .inSync)
        #expect(ts.behind == 0)
    }

    @Test("parent 2 commits ahead of the recorded base ⇒ stale, behind 2")
    func staleBehindTwo() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let base0 = try Self.git(repo, "rev-parse", "parent")
        let card = try await Self.linkedChild(env, repo: repo, base: base0)
        try Self.advanceParent(repo, 2)
        await env.svc.recomputeTreeStat(card.id)
        let ts = try #require(await treeStat(env, card.id))
        #expect(ts.state == .stale)
        #expect(ts.behind == 2)
    }

    @Test("recorded base no longer an ancestor (amended parent) ⇒ restackNeeded")
    func restackOnAmend() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        try Self.advanceParent(repo, 1)
        let base1 = try Self.git(repo, "rev-parse", "parent")      // record this tip
        let card = try await Self.linkedChild(env, repo: repo, base: base1)
        // Rewrite the parent's tip so base1 is orphaned (no longer an ancestor).
        try Self.git(repo, "checkout", "-q", "parent")
        try Self.write(repo, "amended.txt", "y")
        try Self.git(repo, "add", "-A")
        try Self.git(repo, "commit", "-q", "--amend", "-m", "amended")
        try Self.git(repo, "checkout", "-q", "main")
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id)?.state == .restackNeeded)
    }

    @Test("parent branch deleted ⇒ restackNeeded")
    func restackOnDeletedParent() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let tip = try Self.git(repo, "rev-parse", "parent")
        let card = try await Self.linkedChild(env, repo: repo, base: tip)
        try Self.git(repo, "branch", "-D", "parent")               // main is already checked out
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id)?.state == .restackNeeded)
    }

    @Test("a card with no parent link stays treeStat nil")
    func noLinkNoStat() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "solo", repo: repo, branch: "solo"))
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TreeStatTests`
Expected: FAIL — `recomputeTreeStat` is not a member of `OrchestraService`.

- [ ] **Step 3: Add the debounce dict** — `Sources/OrchestraCore/OrchestraService.swift`, immediately after the `diffStatDebounce` declaration (`:75`)

```swift
    // Per-card coalescing debounce for the TreeStat recompute (branch-tree, BT4). Twin of
    // `diffStatDebounce` — a one-shot per activity burst off the `report()` funnel, not a poll.
    var treeStatDebounce: [UUID: _Concurrency.Task<Void, Never>] = [:]
```

- [ ] **Step 4: Add compute + debounce to `+Tree.swift`** — append inside the `extension OrchestraService` in `Sources/OrchestraCore/OrchestraService+Tree.swift` (before the final closing brace)

```swift
    // MARK: - TreeStat maintenance (BT4)

    /// Recompute the card's `TreeStat` from its lineage link; persist + emit **only when it changed**
    /// (idempotent — safe to call freely from the report funnel), exactly like `recomputeDiffStat`. A
    /// card with no parent link resolves to `nil`. Local parents only (BT4 scope); `parentMerged`
    /// (BT5 `shipped`) and remote tips (BT6) are layered on later.
    func recomputeTreeStat(_ id: UUID) async {
        guard let t = await store.get(id), t.origin == .worktree else { return }
        let link = await lineage.read(repo: t.repo, branch: t.branch)
        let old = t.treeStat
        let new = link.map { computeTreeStat(repo: t.repo, link: $0) }
        guard new != old else { return }                       // no delta → no persist, no emit
        guard let saved = try? await store.update(id, { $0.treeStat = new }) else { return }
        emit(.taskUpserted(saved))
    }

    /// Coalescing per-card trigger for `recomputeTreeStat` — a one-shot debounce off the report funnel,
    /// twin of `scheduleDiffStat`.
    func scheduleTreeStat(_ id: UUID) {
        treeStatDebounce[id]?.cancel()
        treeStatDebounce[id] = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .milliseconds(750))
            if _Concurrency.Task.isCancelled { return }
            await self?.recomputeTreeStat(id)
            await self?.clearTreeStatDebounce(id)
        }
    }

    private func clearTreeStatDebounce(_ id: UUID) { treeStatDebounce[id] = nil }

    /// Derive a child's `TreeStat` from its lineage link using only local git. Parent tip gone
    /// (branch deleted / bad ref) or an empty recorded base ⇒ `restackNeeded`. Otherwise `behind` =
    /// commits in `base..tip`; if the base is no longer the tip's ancestor (parent rewrote/rebased) ⇒
    /// `restackNeeded`, else `inSync` (behind 0) / `stale` (behind > 0).
    private func computeTreeStat(repo: String, link: ParentLink) -> TreeStat {
        guard !link.base.isEmpty, let tip = treeTip(repo: repo, link.parent) else {
            return TreeStat(state: .restackNeeded)
        }
        let behind = treeBehind(repo: repo, base: link.base, tip: tip)
        if !treeBaseIsAncestor(repo: repo, base: link.base, tip: tip) {
            return TreeStat(state: .restackNeeded, behind: behind)
        }
        return TreeStat(state: behind == 0 ? .inSync : .stale, behind: behind)
    }

    /// `git rev-parse --verify --quiet <ref>` — nil when the ref can't be resolved (parent deleted).
    private func treeTip(repo: String, _ ref: String) -> String? {
        guard let r = try? Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref]),
              r.ok else { return nil }
        let oid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return oid.isEmpty ? nil : oid
    }

    /// Commit count in `base..tip` (how far the parent advanced past the recorded base). 0 on error.
    private func treeBehind(repo: String, base: String, tip: String) -> Int {
        guard let r = try? Proc.run(["git", "-C", repo, "rev-list", "--count", "\(base)..\(tip)"]),
              r.ok, let n = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
        return n
    }

    /// True iff `base` is an ancestor of `tip` (exit 0). Exit 1 = not an ancestor; any other failure is
    /// treated as not-an-ancestor so a broken base surfaces as `restackNeeded` rather than silently inSync.
    private func treeBaseIsAncestor(repo: String, base: String, tip: String) -> Bool {
        guard let r = try? Proc.run(["git", "-C", repo, "merge-base", "--is-ancestor", base, tip]) else {
            return false
        }
        return r.ok
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter TreeStatTests`
Expected: PASS (5 tests). (`synced` round-trip is added in Task 4.)

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/OrchestraService+Tree.swift Tests/OrchestraCoreTests/TreeStatTests.swift
git commit -m "feat(bt4): recomputeTreeStat compute core + debounce"
```

---

## Task 2: Stale nudge on the inSync→stale transition

Fire an inbox nudge + wake exactly once, only on the `inSync→stale` edge — never per-commit, never `stale→stale`.

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift` (extend `recomputeTreeStat`)
- Test: `Tests/OrchestraCoreTests/StaleNudgeTests.swift` (create)

**Interfaces:**
- Consumes: `inbox.enqueue(_:_:) throws`, `wake(_:) async`, `saved.shortId`, `ParentLink.parent`.
- Produces: `recomputeTreeStat` now nudges on transition (same signature).

- [ ] **Step 1: Write the failing test** — create `Tests/OrchestraCoreTests/StaleNudgeTests.swift`

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Stale nudge — inSync→stale transition only")
struct StaleNudgeTests {

    @Test("inSync → stale enqueues exactly one nudge; stale → stale is silent")
    func transitionOnly() async throws {
        let env = TestEnv.make()
        let repo = try TreeStatTests.repoWithParent(env.base)
        let base0 = try TreeStatTests.git(repo, "rev-parse", "parent")
        let card = try await TreeStatTests.linkedChild(env, repo: repo, base: base0)  // .running card

        await env.svc.recomputeTreeStat(card.id)                    // inSync established — no nudge
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)

        try TreeStatTests.advanceParent(repo, 1)                    // parent moves
        await env.svc.recomputeTreeStat(card.id)                    // inSync → stale ⇒ nudge
        let after1 = try await env.svc.inboxPeek(card.id)
        #expect(after1.count == 1)
        #expect(after1.first?.text.contains("moved ahead") == true)
        #expect(after1.first?.text.contains("orchestra synced") == true)

        try TreeStatTests.advanceParent(repo, 1)                    // parent moves again
        await env.svc.recomputeTreeStat(card.id)                    // stale → stale (behind changes) — silent
        #expect(try await env.svc.inboxPeek(card.id).count == 1)    // still exactly one
    }

    @Test("first-ever compute landing on stale does NOT nudge (transition edge only)")
    func noNudgeWithoutInSyncPredecessor() async throws {
        let env = TestEnv.make()
        let repo = try TreeStatTests.repoWithParent(env.base)
        let base0 = try TreeStatTests.git(repo, "rev-parse", "parent")
        let card = try await TreeStatTests.linkedChild(env, repo: repo, base: base0)
        try TreeStatTests.advanceParent(repo, 1)                    // parent already ahead at first compute
        await env.svc.recomputeTreeStat(card.id)                    // nil → stale, no inSync predecessor
        #expect(await env.svc.list().first { $0.id == card.id }?.treeStat?.state == .stale)
        #expect(try await env.svc.inboxPeek(card.id).isEmpty)       // no nudge without the inSync→stale edge
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter StaleNudgeTests`
Expected: FAIL — `transitionOnly` finds an empty inbox after the parent moves (no nudge wired yet).

- [ ] **Step 3: Add the nudge to `recomputeTreeStat`** — in `Sources/OrchestraCore/OrchestraService+Tree.swift`, extend the method body added in Task 1: after `emit(.taskUpserted(saved))`, append

```swift
        // Stale nudge: fire ONCE, only on the inSync → stale edge (never per-commit, never stale→stale,
        // never on a first compute that lands on stale). Enqueue + wake — the `concludeCard` idiom.
        if old?.state == .inSync, new?.state == .stale, let parent = link?.parent {
            try? await inbox.enqueue(id, "parent \(parent) moved ahead — merge it down, then run "
                + "`orchestra synced \(saved.shortId)`")
            await wake(id)
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter StaleNudgeTests`
Expected: PASS (2 tests). Also re-run `swift test --filter TreeStatTests` — still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Tree.swift Tests/OrchestraCoreTests/StaleNudgeTests.swift
git commit -m "feat(bt4): stale nudge on inSync->stale transition"
```

---

## Task 3: Funnel hook — schedule self + live children

Wire the report funnel: every worktree card report schedules its own TreeStat recompute and, via `lineage.children`, each of its live child cards (a moved parent stales its children).

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift` (add `scheduleChildTreeStats`)
- Modify: `Sources/OrchestraCore/OrchestraService+Report.swift` (`:139` hook)
- Test: `Tests/OrchestraCoreTests/StaleNudgeTests.swift` (add funnel case)

**Interfaces:**
- Consumes: `lineage.children(repo:of:) -> [String]`, `store.all()`.
- Produces: `func scheduleChildTreeStats(repo:of:) async` — internal.

- [ ] **Step 1: Write the failing test** — add to `StaleNudgeTests.swift`

```swift
    @Test("a parent card's report fans out ⇒ its live child recomputes, goes stale, and is nudged")
    func funnelStalesLiveChild() async throws {
        let env = TestEnv.make()
        let repo = try TreeStatTests.repoWithParent(env.base)
        let base0 = try TreeStatTests.git(repo, "rev-parse", "parent")
        // A live parent card owning branch "parent", plus the linked child.
        let parentCard = try await env.svc.spawn(SpawnInput(prompt: "p", repo: repo, branch: "parent"))
        let child = try await TreeStatTests.linkedChild(env, repo: repo, base: base0)
        await env.svc.recomputeTreeStat(child.id)                   // inSync baseline
        try TreeStatTests.advanceParent(repo, 1)                    // parent tip moves in git

        // The parent card reports activity → funnel schedules the child's TreeStat recompute.
        try await env.svc.report(parentCard.id, StatusReport(desc: "did work", status: .running))
        try await pollUntil {
            (try? await env.svc.inboxPeek(child.id))?.isEmpty == false
        }
        #expect(try await env.svc.inboxPeek(child.id).first?.text.contains("moved ahead") == true)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter StaleNudgeTests.funnelStalesLiveChild`
Expected: FAIL — `pollUntil` times out; the funnel doesn't schedule children yet.

- [ ] **Step 3: Add `scheduleChildTreeStats`** — append to the `extension OrchestraService` in `Sources/OrchestraCore/OrchestraService+Tree.swift`

```swift
    /// Schedule a TreeStat recompute for each LIVE child card of `branch` — a card whose branch records
    /// `branch` as its parent. Called from the report funnel: a parent card's activity may have advanced
    /// its tip, staling its children.
    func scheduleChildTreeStats(repo: String, of branch: String) async {
        let childBranches = await lineage.children(repo: repo, of: branch)
        guard !childBranches.isEmpty else { return }
        let active = await store.all().filter { !$0.archived && $0.origin == .worktree }
        for child in childBranches {
            if let card = active.first(where: { $0.repo == repo && $0.branch == child }) {
                scheduleTreeStat(card.id)
            }
        }
    }
```

- [ ] **Step 4: Wire the funnel hook** — `Sources/OrchestraCore/OrchestraService+Report.swift:139`, replace the single line

```swift
        if saved.origin == .worktree { scheduleDiffStat(id) }
```

with

```swift
        if saved.origin == .worktree {
            scheduleDiffStat(id)
            scheduleTreeStat(id)                                    // this card's own parent may have moved
            await scheduleChildTreeStats(repo: saved.repo, of: saved.branch)  // a moved parent stales children
        }
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter StaleNudgeTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Tree.swift Sources/OrchestraCore/OrchestraService+Report.swift Tests/OrchestraCoreTests/StaleNudgeTests.swift
git commit -m "feat(bt4): report-funnel hook schedules self + live children"
```

---

## Task 4: `synced` command (service + catalog + registry + CLI)

The agent's "I merged the parent down" report: record the parent tip as the new base and recompute (→ inSync).

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift` (add `synced`)
- Modify: `Sources/OrchestraKit/CommandCatalog.swift` (schema after `tree`)
- Modify: `Sources/OrchestraCore/CommandRegistry.swift` (handler after `tree`)
- Modify: `Sources/orchestra/CLIRunner.swift` (case after `tree`)
- Modify: `Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift` (add `"synced"` to the hardcoded list)
- Test: `Tests/OrchestraCoreTests/TreeStatTests.swift` (add round-trip case)

**Interfaces:**
- Consumes: `resolveRef(_:)`, `lineage.read`, `lineage.updateBase(repo:branch:oid:) throws`, `treeTip` (private helper from Task 1 — reused within `+Tree.swift`), `recomputeTreeStat`, `emitActivity`.
- Produces: `public func synced(ref:source:) async throws -> Task`; catalog `"synced"` schema; registry `"synced"` handler; CLI `"synced"` case.

- [ ] **Step 1: Write the failing tests**

Add to `TreeStatTests.swift`:

```swift
    @Test("synced records the parent tip as the base ⇒ back to inSync, base advanced")
    func syncedRoundTrip() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let base0 = try Self.git(repo, "rev-parse", "parent")
        let card = try await Self.linkedChild(env, repo: repo, base: base0)
        let tip2 = try Self.advanceParent(repo, 2)                  // parent 2 ahead
        await env.svc.recomputeTreeStat(card.id)
        #expect(await treeStat(env, card.id)?.state == .stale)

        _ = try await env.svc.synced(ref: card.ref())              // "I merged the parent down"
        #expect(await treeStat(env, card.id)?.state == .inSync)
        #expect(await treeStat(env, card.id)?.behind == 0)
        let link = try #require(await BranchLineage().read(repo: repo, branch: "child"))
        #expect(link.base == tip2)                                 // recorded base advanced to parent tip
    }

    @Test("synced on a card with no parent link throws invalidParams")
    func syncedNoLink() async throws {
        let env = TestEnv.make()
        let repo = try Self.repoWithParent(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "solo", repo: repo, branch: "solo"))
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.synced(ref: card.ref())
        }
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TreeStatTests.syncedRoundTrip`
Expected: FAIL — `synced` is not a member of `OrchestraService`.

- [ ] **Step 3: Add the `synced` service method** — append to `extension OrchestraService` in `Sources/OrchestraCore/OrchestraService+Tree.swift`

```swift
    /// `synced` — the agent's "I merged/restacked the parent down" report: record the parent's current
    /// tip as the new recorded base and recompute (→ `inSync`). Idempotent.
    @discardableResult
    public func synced(ref: String, source: ActivitySource = .daemon) async throws -> Task {
        let t = try await resolveRef(ref)
        guard t.origin == .worktree else {
            throw OrchestraError.invalidParams("only worktree cards have a parent to sync")
        }
        guard let link = await lineage.read(repo: t.repo, branch: t.branch) else {
            throw OrchestraError.invalidParams("card has no parent link to sync")
        }
        guard let tip = treeTip(repo: t.repo, link.parent) else {
            throw OrchestraError.invalidParams("parent ref not found: \(link.parent)")
        }
        try await lineage.updateBase(repo: t.repo, branch: t.branch, oid: tip)
        await recomputeTreeStat(t.id)
        emitActivity(.command, t, source, "synced parent \(link.parent)")
        return (await store.get(t.id)) ?? t
    }
```

- [ ] **Step 4: Add the catalog schema** — `Sources/OrchestraKit/CommandCatalog.swift`, immediately after the `"tree"` `CommandSchema` (`:117-123`)

```swift
        CommandSchema(name: "synced",
                      summary: "Report that this card merged/restacked its parent down: record the "
                          + "parent's current tip as the sync base and clear the stale/behind signal.",
                      params: schema(["ref": refProp()], required: ["ref"])),
```

- [ ] **Step 5: Add the registry handler** — `Sources/OrchestraCore/CommandRegistry.swift`, immediately after the `"tree"` handler (`:147-151`)

```swift
            "synced": { svc, p, src in
                let updated = try await svc.synced(ref: try p.string("ref"), source: src)
                return try JSONValue(encodable: updated)
            },
```

- [ ] **Step 6: Add the CLI case** — `Sources/orchestra/CLIRunner.swift`, immediately after the `"tree"` case (`:112-117`)

```swift
            case "synced":
                let ref = flags.positional(0) ?? flags.require("ref")
                let task = try await client.call("synced", .object(["ref": .string(ref)]))
                printRef(task)
```

- [ ] **Step 7: Update the pairing test's hardcoded list** — `Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift`, in `testCatalogHasAllCommands`, change the trailing `"set-parent", "tree",` to

```swift
            "set-parent", "tree", "synced",
```

- [ ] **Step 8: Run to verify it passes**

Run: `swift test --filter TreeStatTests` then `swift test --filter CommandRegistryCatalogTests`
Expected: PASS — round-trip + no-link throw pass; the catalog/registry pairing (all three pairing tests) covers `synced`.

- [ ] **Step 9: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Tree.swift Sources/OrchestraKit/CommandCatalog.swift Sources/OrchestraCore/CommandRegistry.swift Sources/orchestra/CLIRunner.swift Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift Tests/OrchestraCoreTests/TreeStatTests.swift
git commit -m "feat(bt4): synced command (service + catalog + registry + CLI)"
```

---

## Task 5: Card badges (desktop + iOS)

Render a `↓N` (stale/behind) or restack indicator in both card footers, driven by `task.treeStat`, styled like the diffstat pill. No unit test — logic is trivial view code; verified by the manual visual pass.

**Files:**
- Modify: `App/Views/CardView.swift` (add `treeBadge`, place in footer)
- Modify: `App-iOS/Views/BoardCardCell.swift` (add `treeBadge`, place in footer)

**Interfaces:**
- Consumes: `task.treeStat` (`TreeStat`/`TreeState`), `theme.amber` / `theme.red` (`SemColor`), desktop `F.ui`/`F.mono`.

- [ ] **Step 1: Add the desktop badge** — `App/Views/CardView.swift`, place `treeBadge` in the footer HStack right after `worktreeBadge` (`:157`)

```swift
            worktreeBadge
            treeBadge
```

Then add the view, next to `worktreeBadge` (after `:177`):

```swift
    /// Lineage status: `↓N` when the parent advanced past the recorded base (stale), a restack glyph when
    /// the branch needs re-basing (parent rewrote/shipped). Styled like the diffstat pill; hidden when
    /// in-sync or untracked (`treeStat == nil`).
    @ViewBuilder private var treeBadge: some View {
        if let ts = task.treeStat {
            switch ts.state {
            case .stale:
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down").font(F.ui(8.5))
                    Text("\(ts.behind)").font(F.mono(10, .medium))
                }
                .foregroundStyle(theme.amber.text)
                .help("Parent is \(ts.behind) commit\(ts.behind == 1 ? "" : "s") ahead — merge it down, then run `orchestra synced`")
            case .restackNeeded, .parentMerged:
                Image(systemName: "arrow.triangle.2.circlepath").font(F.ui(8.5))
                    .foregroundStyle(theme.red.text)
                    .help("Parent history changed — restack this branch")
            case .inSync:
                EmptyView()
            }
        }
    }
```

- [ ] **Step 2: Add the iOS badge** — `App-iOS/Views/BoardCardCell.swift`, place `treeBadge` in the footer HStack right after the `pathLabel` `Text(...)` block, before `Spacer(minLength: 6)` (`:77-78`)

```swift
                .truncationMode(.middle)
            treeBadge
            Spacer(minLength: 6)
```

Then add the view, after the `meta` view (`:109`):

```swift
    /// Lineage status: `↓N` when the parent advanced (stale), a restack glyph when a restack is needed.
    /// Mirrors the desktop `treeBadge`; hidden when in-sync / untracked.
    @ViewBuilder private var treeBadge: some View {
        if let ts = task.treeStat {
            switch ts.state {
            case .stale:
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down")
                    Text("\(ts.behind)")
                }
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(theme.amber.text)
            case .restackNeeded, .parentMerged:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(theme.red.text)
            case .inSync:
                EmptyView()
            }
        }
    }
```

- [ ] **Step 3: Build both targets to verify they compile**

Run: `swift build` (Core/Kit/CLI), then the desktop app build per `scripts/build-app.sh` if available. iOS: typecheck per the iOS build script (`notes`/memory: `ios-app-build-and-dev-transport`). At minimum, `swift build` must succeed; app targets must compile.
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add App/Views/CardView.swift App-iOS/Views/BoardCardCell.swift
git commit -m "feat(bt4): stale/restack card badges (desktop + iOS)"
```

---

## Task 6: Full verification

- [ ] **Step 1: Full test suite**

Run: `swift test`
Expected: PASS cleanly (all suites, including the new TreeStat/StaleNudge suites and the untouched Lineage/Diff/Command suites).

- [ ] **Step 2: Manual visual pass (badges)** — per memory `orchestra-ui-visual-check` / `ios-app-isolated-verification`

Drive an isolated instance with a seeded stale child card and capture the footer badge (desktop `scripts/orch-ui-shot.sh`; iOS seeded-daemon screenshot). Confirm `↓N` renders amber and the restack glyph renders red. This is a check, not a gate for CI.

- [ ] **Step 3: Commit any fixups, then proceed to the review phase** (move card to review; `superpowers:requesting-code-review` over the diff vs `plan/parent-card-branch-linking`).

---

## Self-Review notes (coverage vs 04-tests.md)

- `TreeStat` compute (inSync / stale behind=2 / restackNeeded amended / parent deleted) → Task 1 (+ no-link nil).
- Stale transition nudge (inSync→stale once, stale→stale silent, enqueue) → Task 2; funnel fan-out → Task 3.
- `synced` (base := tip, back to inSync) → Task 4 (+ no-link throw).
- Catalog/registry pairing auto-covers `synced` → Task 4 (hardcoded-list update included).
- Card badges → Task 5 (manual visual per 04-tests "UI = manual shot pass").
- **Out of scope (deferred, per plan constraints):** `parentMerged` state production (BT5 `shipped`), remote tip resolution + `parentIsRemote` (BT6), `set-parent move` (BT5), diff-baseline switch (BT3), tree grouping/jump-to-parent (BT7).
- **Coordination:** the only shared-file edits are additive — one `CommandCatalog` schema, one `CommandRegistry` handler, one CLI case, one debounce dict, the one funnel line, and the pairing-test list. BT2/BT3 conflicts (if any) are orchestrator-resolved.
