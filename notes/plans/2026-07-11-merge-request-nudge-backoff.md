# Merge-request re-nudge backoff + give-up cap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the merge-request re-nudge loop from prodding the parent card every 300s forever — back it off geometrically, cap it at 8 reminders, and land the child in a visible, persisted `mergeStalled` state instead of nudging silently for eternity.

**Architecture:** The reminder count is persisted on the card (`TreeStat.nudges`), so the timer Task holds **no state of its own**: each tick reads the count from the store, sleeps `nudgeDelay(base:attempt:)`, sends the reminder, writes the count back. That is what makes the cap real — `rebuildMergeRequestNudges()` re-arms every pending card at daemon start, so an in-memory counter would reset on every restart and the cap would never fire. On the capped tick the child flips to `TreeState.mergeStalled`, which is sticky, terminal, survives restart, and renders as a red badge on both card faces plus a `.warning` activity entry.

**Tech Stack:** Swift 6, swift-testing (`@Test`/`#expect`), SwiftUI (macOS + iOS card faces), actor-isolated `OrchestraService`.

**Design doc:** `notes/designs/2026-07-11-merge-request-nudge-backoff.md` — read it first.

## Global Constraints

- **Restack before Task 3.** This branch is stacked on `fix/nudge-leak-cooperative-pool-starvation`, which rewrites `startMergeRequestNudge` (weak-self-per-hop + service teardown). Tasks 1–2 are additive and safe now. **Do not edit `OrchestraService+MergeRequest.swift` until that branch lands and this branch is restacked onto it** (`git merge refs/heads/fix/nudge-leak-cooperative-pool-starvation` → `orchestra synced 5c0a1e`). Task 3's loop code below is written in the **post-fix** form; if the parent's landed form differs, take theirs verbatim and layer only the backoff/cap onto it.
- **This is not a starvation fix.** Never describe backoff as fixing (or helping) the cooperative-pool deadlock — it dilutes it, which is worse. That fix lives on the parent branch.
- **No new notification pipeline.** No `NotifyTrigger`, no `AttentionReason`, no `AttentionTracker` change. `plan/live-wake-delivery`'s B5b owns that seam; `mergeStalled` joins it later. Badge + activity entry only.
- **Backoff ceiling is a multiple of the base, never an absolute duration** — tests inject a 20ms base and must stay fast.
- **Agent-agnostic** (`CLAUDE.md`): this path never branches on `agentId`. Sanity-check against Claude *and* Codex before calling it done.
- Full-suite command: `swift test`. Single suite: `swift test --filter <SuiteName>`.

---

### Task 1: Persist the reminder count + the terminal state (model layer)

Additive, no behaviour change. Safe to do before the parent branch lands.

**Files:**
- Modify: `Sources/OrchestraKit/Model.swift:340-351` (the `TreeState` enum + `TreeStat` struct)
- Test: `Tests/OrchestraCoreTests/MergeRequestBackoffTests.swift` (create)

**Interfaces:**
- Produces: `TreeState.mergeStalled`; `TreeState.isMergePending: Bool` (true for `.mergeRequested` and `.mergeStalled`); `TreeStat.nudges: Int` (defaults to 0, decodes leniently); `TreeStat.init(state:behind:parentIsRemote:nudges:)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrchestraCoreTests/MergeRequestBackoffTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

@Suite("merge-request re-nudge — model")
struct MergeRequestBackoffModelTests {

    @Test("a TreeStat persisted before this change decodes with nudges == 0")
    func legacyTreeStatDecodesWithZeroNudges() throws {
        let legacy = #"{"state":"mergeRequested","behind":0,"parentIsRemote":false}"#
        let ts = try JSONDecoder().decode(TreeStat.self, from: Data(legacy.utf8))
        #expect(ts.state == .mergeRequested)
        #expect(ts.nudges == 0)
    }

    @Test("nudges round-trips through Codable")
    func nudgesRoundTrips() throws {
        let ts = TreeStat(state: .mergeStalled, nudges: 8)
        let back = try JSONDecoder().decode(TreeStat.self, from: JSONEncoder().encode(ts))
        #expect(back == ts)
        #expect(back.nudges == 8)
    }

    @Test("isMergePending covers both waiting and stalled, and nothing else")
    func isMergePendingCoversBoth() {
        #expect(TreeState.mergeRequested.isMergePending)
        #expect(TreeState.mergeStalled.isMergePending)
        #expect(!TreeState.inSync.isMergePending)
        #expect(!TreeState.stale.isMergePending)
        #expect(!TreeState.restackNeeded.isMergePending)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter MergeRequestBackoffModelTests`
Expected: FAIL — compile error, `mergeStalled` / `nudges` / `isMergePending` do not exist.

- [ ] **Step 3: Implement**

In `Sources/OrchestraKit/Model.swift`, replace the enum at `:340` and the struct at `:344-351`:

```swift
public enum TreeState: String, Codable, Sendable {
    case inSync, stale, restackNeeded, mergeRequested, mergeStalled

    /// A merge-request is outstanding on this card — either still being nudged (`mergeRequested`) or
    /// given up on (`mergeStalled`). Both badges are STICKY: the tree-stat funnel must not clobber them
    /// while the child waits, and both are cleared by the same verbs (shipped / synced / set-parent).
    public var isMergePending: Bool { self == .mergeRequested || self == .mergeStalled }
}

/// Per-child tree status for the card face (the `↓N` badge + restack signal). Small + persisted on
/// `Task`, exactly like `DiffStat`.
public struct TreeStat: Codable, Sendable, Equatable {
    public var state: TreeState
    public var behind: Int            // commits the parent is ahead of the recorded base (the ↓N badge)
    public var parentIsRemote: Bool
    /// Re-nudge reminders sent so far for a pending merge-request — NOT counting the t=0 request itself.
    /// Persisted (not held in the timer Task) precisely because `rebuildMergeRequestNudges()` re-arms the
    /// loop on every daemon start: an in-memory counter would reset each restart and the give-up cap would
    /// never fire. The loop is stateless — it reads this, sleeps `nudgeDelay(base:attempt:)`, writes back.
    public var nudges: Int

    public init(state: TreeState, behind: Int = 0, parentIsRemote: Bool = false, nudges: Int = 0) {
        self.state = state; self.behind = behind; self.parentIsRemote = parentIsRemote
        self.nudges = nudges
    }

    // Hand-rolled decode for ONE reason: `nudges` is new, and `Task` decodes `treeStat` with
    // `decodeIfPresent` (Model.swift:536) — which rethrows a nested `keyNotFound` rather than swallowing
    // it. A synthesized decode would therefore make every card persisted before this change fail to load.
    // Same lenient-default discipline `Task.init(from:)` already uses (Model.swift:514).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.state = try c.decode(TreeState.self, forKey: .state)
        self.behind = try c.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        self.parentIsRemote = try c.decodeIfPresent(Bool.self, forKey: .parentIsRemote) ?? false
        self.nudges = try c.decodeIfPresent(Int.self, forKey: .nudges) ?? 0
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter MergeRequestBackoffModelTests`
Expected: 3 tests PASS. Both card-face `switch`es will now fail to compile — **that is expected and is fixed in Task 5**; to keep the build green meanwhile, the SwiftUI targets are not built by `swift test` (they are Xcode targets), so the package suite passes on its own. Verify with `swift build`.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraKit/Model.swift Tests/OrchestraCoreTests/MergeRequestBackoffTests.swift
git commit -m "feat(tree): persist TreeStat.nudges + add the terminal mergeStalled state"
```

---

### Task 2: The backoff schedule (pure function + injectable cap)

Still additive — no loop edits. Safe before the parent branch lands.

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift:66-68` (nudge state)
- Modify: `Sources/OrchestraCore/OrchestraService+MergeRequest.swift:118-120` (test-support section only — **not** the loop)
- Test: `Tests/OrchestraCoreTests/MergeRequestBackoffTests.swift` (append a suite)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `OrchestraService.nudgeDelay(base:attempt:) -> Duration` (static, pure, internal); `OrchestraService.mergeRequestNudgeCap: Int` (default 8); `setMergeRequestNudgeCap(_ n: Int)`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/OrchestraCoreTests/MergeRequestBackoffTests.swift`:

```swift
@Suite("merge-request re-nudge — backoff schedule")
struct NudgeDelayTests {
    private let base = Duration.seconds(300)

    @Test("the delay doubles from the base until it hits the 12x ceiling")
    func doublesThenCeilings() {
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 0) == .seconds(300))   // 1x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 1) == .seconds(600))   // 2x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 2) == .seconds(1200))  // 4x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 3) == .seconds(2400))  // 8x
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 4) == .seconds(3600))  // 12x ceiling
        #expect(OrchestraService.nudgeDelay(base: base, attempt: 5) == .seconds(3600))  // held
    }

    @Test("the ceiling is relative to the base, so an injected fast base stays fast")
    func ceilingIsBaseRelative() {
        let fast = Duration.milliseconds(20)
        #expect(OrchestraService.nudgeDelay(base: fast, attempt: 9) == .milliseconds(240))  // 12 x 20ms
    }

    @Test("a corrupt or absurd persisted count neither traps nor sleeps forever")
    func absurdAttemptIsClamped() {
        #expect(OrchestraService.nudgeDelay(base: base, attempt: Int.max) == .seconds(3600))
        #expect(OrchestraService.nudgeDelay(base: base, attempt: -5) == .seconds(300))
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter NudgeDelayTests`
Expected: FAIL — `nudgeDelay` does not exist.

- [ ] **Step 3: Implement**

In `Sources/OrchestraCore/OrchestraService.swift`, beside the existing nudge state at `:66-68`:

```swift
    var mergeRequestNudgeInterval: Duration = .seconds(300)
    /// Reminders to send before giving up and flipping the child to `mergeStalled`. With the 300s base
    /// and the 12x ceiling that is 5m/10m/20m/40m/1h/1h/1h/1h — roughly 5¼ hours of prodding.
    var mergeRequestNudgeCap: Int = 8
```

In `Sources/OrchestraCore/OrchestraService+MergeRequest.swift`, add above the `// MARK: - test-support` section:

```swift
    /// Delay before reminder `attempt` (0-based): doubles from the base, ceilinged at **12x the base**.
    /// The ceiling is base-relative, not absolute, so tests injecting a 20ms base get a 240ms ceiling.
    /// The shift operand is clamped BEFORE shifting — an unclamped `1 << attempt` overflows and traps on a
    /// large persisted count (a hand-edited or corrupted card), which is a crash, not a long sleep.
    static func nudgeDelay(base: Duration, attempt: Int) -> Duration {
        base * min(1 << min(max(attempt, 0), 8), 12)
    }
```

and in the test-support section:

```swift
    func setMergeRequestNudgeCap(_ n: Int) { mergeRequestNudgeCap = n }
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter NudgeDelayTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/OrchestraService+MergeRequest.swift Tests/OrchestraCoreTests/MergeRequestBackoffTests.swift
git commit -m "feat(merge-request): geometric nudge backoff with a base-relative ceiling"
```

---

### Task 3: Rewrite the loop — stateless, backed off, capped

**BLOCKED until `fix/nudge-leak-cooperative-pool-starvation` lands and this branch is restacked.** See Global Constraints.

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+MergeRequest.swift:64-96` (`startMergeRequestNudge` + `reNudgeMergeRequest`)
- Test: `Tests/OrchestraCoreTests/MergeRequestBackoffTests.swift` (append a suite)

**Interfaces:**
- Consumes: `TreeStat.nudges`, `TreeState.mergeStalled` (Task 1); `nudgeDelay(base:attempt:)`, `mergeRequestNudgeCap`, `setMergeRequestNudgeCap` (Task 2).
- Produces: `nudgesSent(_ id: UUID) async -> Int`; the give-up flip to `.mergeStalled` + its `.warning` activity.

- [ ] **Step 1: Write the failing test**

Append to `Tests/OrchestraCoreTests/MergeRequestBackoffTests.swift`. (The env/spawn/lineage setup mirrors `RebuildMergeRequestNudgesTests.swift:16-25` verbatim — reuse it exactly.)

```swift
@Suite("merge-request re-nudge — give-up cap")
struct MergeRequestCapTests {

    private func treeStat(_ svc: OrchestraService, _ id: UUID) async -> TreeStat? {
        await svc.list().first { $0.id == id }?.treeStat
    }

    /// Poll until `check` holds or we run out of patience — the loop ticks on its own schedule.
    private func eventually(_ check: () async -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if await check() { return true }
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("after the cap, the loop gives up: child goes mergeStalled, timer stops, warning is emitted")
    func capFiresAndStalls() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let parentCard = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))

        // Subscribe BEFORE arming — activity items are ephemeral events, not stored state, so a collector
        // started after the flip would miss the warning entirely (the `LadderTests.swift:63-64` pattern).
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())

        await env.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await env.svc.setMergeRequestNudgeCap(3)
        _ = try await env.svc.mergeRequest(ref: child.ref())

        #expect(try await eventually { await treeStat(env.svc, child.id)?.state == .mergeStalled })

        // Exactly 1 original request + exactly 3 reminders — the cap is a hard stop, not a slow drip.
        let msgs = try await env.svc.inboxPeek(parentCard.id).map(\.text)
        #expect(msgs.filter { $0.contains("reminder") }.count == 3)
        #expect(msgs.filter { $0.hasPrefix("merge-request:") }.count == 1)
        #expect(await treeStat(env.svc, child.id)?.nudges == 3)

        // The loop is torn down for good, and the give-up is visible in the activity feed.
        #expect(try await eventually { await env.svc.mergeRequestNudgeActive(child.id) == false })
        try await _Concurrency.Task.sleep(for: .milliseconds(50))   // let the ephemeral event land
        let warns = await collector.activities.filter {
            $0.kind == .warning && $0.text.contains("merge-request stalled")
        }
        #expect(warns.count == 1)   // fires ONCE on the flip, not on every subsequent tick

        // Terminal: it stays stalled and stays silent (no further reminders after the flip).
        try await _Concurrency.Task.sleep(for: .milliseconds(120))
        #expect(await treeStat(env.svc, child.id)?.state == .mergeStalled)
        let after = try await env.svc.inboxPeek(parentCard.id).filter { $0.text.contains("reminder") }.count
        #expect(after == 3)
    }

    @Test("the backoff resumes across a daemon restart — the count comes from the store, not the Task")
    func backoffResumesAcrossRestart() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let parentCard = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)          // the daemon dies mid-budget

        // 2 of the 3 reminders were already sent before the crash — persisted on the card.
        _ = try await env.svc.store.update(child.id) { $0.treeStat?.nudges = 2 }

        let svcB = TestEnv.remake(base: env.base)              // restart over the SAME on-disk store
        await svcB.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await svcB.svc.setMergeRequestNudgeCap(3)
        await svcB.svc.rebuildMergeRequestNudges()

        #expect(try await eventually { await treeStat(svcB.svc, child.id)?.state == .mergeStalled })
        // The restart did NOT reset the budget: exactly ONE more reminder was owed, not three.
        let reminders = try await svcB.svc.inboxPeek(parentCard.id).filter { $0.text.contains("reminder") }
        #expect(reminders.count == 1)
        #expect(await treeStat(svcB.svc, child.id)?.nudges == 3)
    }

    @Test("a fresh merge-request on a stalled child resets the budget and re-arms the loop")
    func reSendResetsTheBudget() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        let parentCard = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        await env.svc.setMergeRequestNudgeInterval(.milliseconds(20))
        await env.svc.setMergeRequestNudgeCap(2)
        _ = try await env.svc.mergeRequest(ref: child.ref())
        #expect(try await eventually { await treeStat(env.svc, child.id)?.state == .mergeStalled })

        // The human re-sends. A stalled child is NOT deduped (`alreadyPending` tests `.mergeRequested`),
        // so the request is re-enqueued, the parent re-woken, and the whole budget re-armed from zero.
        await env.svc.setMergeRequestNudgeCap(99)   // keep it pending so we can observe the reset
        _ = try await env.svc.mergeRequest(ref: child.ref())

        #expect(await treeStat(env.svc, child.id)?.state == .mergeRequested)
        #expect(await treeStat(env.svc, child.id)?.nudges == 0)
        #expect(await env.svc.mergeRequestNudgeActive(child.id) == true)
        let requests = try await env.svc.inboxPeek(parentCard.id).filter { $0.text.hasPrefix("merge-request:") }
        #expect(requests.count == 2)   // the original + the re-send
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter MergeRequestCapTests`
Expected: FAIL — the child never reaches `.mergeStalled`; reminders keep arriving forever (the current loop has no cap). `capFiresAndStalls` times out in `eventually`.

- [ ] **Step 3: Implement**

Replace `startMergeRequestNudge` + `reNudgeMergeRequest` in `Sources/OrchestraCore/OrchestraService+MergeRequest.swift`:

```swift
    /// (Re)start the per-child re-nudge loop: while the child stays `mergeRequested`, re-enqueue the
    /// request to the parent card on a **geometric backoff** (`nudgeDelay`) — and after
    /// `mergeRequestNudgeCap` unanswered reminders, **give up**: flip the child to the terminal
    /// `mergeStalled` badge so a human can see it, and stop. A parent that ignored 8 reminders will not
    /// act on the 9th; prodding it forever just buries the signal.
    ///
    /// The loop is **stateless** — the count lives on the card (`TreeStat.nudges`), so the backoff resumes
    /// at the right point after a daemon restart re-arms it (`rebuildMergeRequestNudges`), rather than
    /// starting the budget over. Stops as soon as the child leaves the waiting state (shipped / synced /
    /// set-parent cleared it), the parent card is gone, or the cap is reached.
    func startMergeRequestNudge(childId: UUID) {
        mergeRequestNudge[childId]?.cancel()
        mergeRequestNudge[childId] = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                guard let sent = await self?.nudgesSent(childId),
                      let base = await self?.mergeRequestNudgeInterval else { return }
                try? await _Concurrency.Task.sleep(for: OrchestraService.nudgeDelay(base: base, attempt: sent))
                if _Concurrency.Task.isCancelled { return }
                guard let stop = await self?.reNudgeMergeRequest(childId) else { return }
                if stop { break }   // no longer pending / parent gone / gave up
            }
            await self?.clearMergeRequestNudge(childId)
        }
    }

    /// Reminders already sent for this child — read from the store each tick (see `startMergeRequestNudge`).
    private func nudgesSent(_ id: UUID) async -> Int { (await store.get(id))?.treeStat?.nudges ?? 0 }

    /// One re-nudge tick. Returns `true` when the loop should STOP (child no longer waiting / parent gone /
    /// cap reached).
    private func reNudgeMergeRequest(_ childId: UUID) async -> Bool {
        guard let child = await store.get(childId), !child.archived, child.origin == .worktree,
              child.treeStat?.state == .mergeRequested,
              let link = await lineage.read(repo: child.repo, branch: child.branch) else { return true }
        let active = await store.all()
        guard let parentCard = derivedCard(repo: child.repo, branch: link.parent, among: active) else {
            // Review B#3: the parent card vanished without shipping — clear the sticky waiting badge so it
            // doesn't linger; the child recomputes its true state (the archive path also nudged it).
            _ = try? await store.update(childId) { if $0.treeStat?.state == .mergeRequested { $0.treeStat = nil } }
            await recomputeTreeStat(childId)
            return true
        }
        let sent = (child.treeStat?.nudges ?? 0) + 1
        let cap = mergeRequestNudgeCap
        try? await inbox.enqueue(parentCard.id,
            "reminder \(sent)/\(cap) — merge-request still pending: squash-merge \(child.branch) "
            + "(\(child.shortId)) into \(link.parent), then `orchestra shipped \(child.shortId)`")
        await wake(parentCard.id)

        // Persist the count (and, at the cap, the give-up) in ONE update, against the value the closure
        // observes — a concurrent shipped/synced that already cleared the badge must not be resurrected.
        var gaveUp = false
        if let (saved, rev) = try? await store.update(childId, { t in
            guard t.treeStat?.state == .mergeRequested else { return }   // cleared under us — leave it alone
            t.treeStat?.nudges = sent
            if sent >= cap { t.treeStat?.state = .mergeStalled; gaveUp = true }
        }) {
            emit(.taskUpserted(saved), rev: rev)
        }
        if gaveUp {
            emitActivity(.warning, child, .daemon,
                "merge-request stalled — \(sent) reminders unanswered; \(link.parent) never merged "
                + "\(child.branch). Merge it yourself, or re-send with "
                + "`orchestra merge-request \(child.shortId)` to re-arm the reminders.")
        }
        return gaveUp
    }
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter MergeRequestCapTests`
Expected: 3 tests PASS.

Then the pre-existing suites, which exercise the same loop and must not regress:
Run: `swift test --filter MergeRequestTests && swift test --filter RebuildMergeRequestNudgesTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+MergeRequest.swift Tests/OrchestraCoreTests/MergeRequestBackoffTests.swift
git commit -m "feat(merge-request): give up after N unanswered reminders instead of nudging forever"
```

---

### Task 4: Make `mergeStalled` sticky and clearable (tree-stat funnel)

Without this the recompute funnel overwrites the new badge on the next tree-stat pass, and `synced` fails to clear it.

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift:194` (the `synced` clear), `:424` and `:435` (the two sticky guards)
- Test: `Tests/OrchestraCoreTests/MergeRequestBackoffTests.swift` (append a suite)

**Interfaces:**
- Consumes: `TreeState.isMergePending` (Task 1); `.mergeStalled` flip (Task 3).

- [ ] **Step 1: Write the failing test**

Append:

```swift
@Suite("merge-request re-nudge — mergeStalled is sticky and clearable")
struct MergeStalledStickinessTests {

    private func treeState(_ svc: OrchestraService, _ id: UUID) async -> TreeState? {
        await svc.list().first { $0.id == id }?.treeStat?.state
    }

    /// Arm a child, force it straight to the terminal state (no waiting for the cap).
    private func stalledChild(_ env: TestEnv, _ repo: String, _ parentTip: String) async throws -> Task {
        let child = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "c", repo: repo, branch: "child"))
        try await BranchLineage().set(repo: repo, branch: "child",
                                      link: ParentLink(parent: "parent", base: parentTip))
        _ = try await env.svc.mergeRequest(ref: child.ref())
        await env.svc.stopMergeRequestNudge(child.id)
        _ = try await env.svc.store.update(child.id) {
            $0.treeStat = TreeStat(state: .mergeStalled, nudges: 8)
        }
        return child
    }

    @Test("a tree-stat recompute does not clobber the stalled badge")
    func recomputeKeepsStalled() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await stalledChild(env, repo, parentTip)

        await env.svc.recomputeTreeStat(child.id)
        #expect(await treeState(env.svc, child.id) == .mergeStalled)   // survives the funnel
    }

    @Test("synced clears the stalled badge (the merge finally happened)")
    func syncedClearsStalled() async throws {
        let env = TestEnv.make()
        let (repo, parentTip) = try ShipChoreoTests.repoWithChild(env.base)
        _ = try await TestEnv.spawnAndAwaitLive(
            env.svc, SpawnInput(id: UUID(), prompt: "p", repo: repo, branch: "parent"))
        let child = try await stalledChild(env, repo, parentTip)

        _ = try await env.svc.synced(ref: child.ref())
        #expect(await treeState(env.svc, child.id) != .mergeStalled)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter MergeStalledStickinessTests`
Expected: FAIL — `recomputeKeepsStalled` finds the badge overwritten (the guards only protect `.mergeRequested`); `syncedClearsStalled` finds it still `.mergeStalled` (the clear only nils `.mergeRequested`).

- [ ] **Step 3: Implement**

Three one-line edits in `Sources/OrchestraCore/OrchestraService+Tree.swift`.

At `:194` (inside `synced`) — clear either merge-pending badge:

```swift
        _ = try? await store.update(t.id) { if $0.treeStat?.state.isMergePending == true { $0.treeStat = nil } }
```

At `:424` (the cheap no-op filter):

```swift
        if current0?.state.isMergePending == true, new?.state != .restackNeeded { return }
```

At `:435` (inside the `store.update` closure — the authority):

```swift
            // O2: the merge-request badges (`mergeRequested` waiting, `mergeStalled` gave-up) are sticky —
            // the funnel must not clobber them while the child waits on its parent. Only a genuine
            // `restackNeeded` (parent history changed) supersedes them.
            if cur?.state.isMergePending == true, new?.state != .restackNeeded { return }
```

`set-parent` (`:24`) and `shipped` (`:355`) need no change: both nil `treeStat` outright rather than testing the state.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter MergeStalledStickinessTests`
Expected: 2 tests PASS.
Run: `swift test --filter TreeStatTests`
Expected: PASS — the funnel's existing behaviour is unchanged for the other three states.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Tree.swift Tests/OrchestraCoreTests/MergeRequestBackoffTests.swift
git commit -m "feat(tree): mergeStalled is sticky against the funnel and cleared by synced"
```

---

### Task 5: Surface it — the badge on both card faces

Both `switch`es over `TreeState` are exhaustive, so the compiler names every consumer. There are exactly two.

**Files:**
- Modify: `App/Views/CardView.swift:215-233` (macOS badge)
- Modify: `App-iOS/Views/BoardCardCell.swift:94-115` (iOS badge)

**Interfaces:**
- Consumes: `TreeState.mergeStalled` (Task 1).

- [ ] **Step 1: Confirm the compiler names the consumers**

Run: `swift build 2>&1 | grep -c "must be exhaustive"` — the package targets build clean (the SwiftUI card faces are Xcode targets). Then run the app build, which is where the two switches actually fail:
Run: `scripts/build-app.sh 2>&1 | grep "must be exhaustive"`
Expected: exactly 2 errors — `App/Views/CardView.swift:215` and `App-iOS/Views/BoardCardCell.swift:94`. These are the two sites to fix; there are no others.

- [ ] **Step 2: Add the macOS case**

In `App/Views/CardView.swift`, directly after the `.mergeRequested` arm (`:227-230`):

```swift
            case .mergeStalled:
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").font(F.ui(8.5))
                    .foregroundStyle(theme.red.text)
                    .help("Merge-request went unanswered — \(ts.nudges) reminders sent and the parent "
                          + "card never merged this. Merge it yourself, or re-send the merge-request.")
```

- [ ] **Step 3: Add the iOS case**

In `App-iOS/Views/BoardCardCell.swift`, directly after the `.mergeRequested` arm (`:108-112`):

```swift
            case .mergeStalled:
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(theme.red.text)
                    .accessibilityLabel("Merge-request unanswered after \(ts.nudges) reminders — "
                                        + "the parent card never merged this")
```

- [ ] **Step 4: Build both apps**

Run: `scripts/build-app.sh`
Expected: builds clean, no exhaustiveness errors.

- [ ] **Step 5: Commit**

```bash
git add App/Views/CardView.swift App-iOS/Views/BoardCardCell.swift
git commit -m "feat(ui): red mergeStalled badge on the Mac + phone card faces"
```

---

### Task 6: Verify end-to-end, then document

**Files:**
- Modify: `docs/` (regenerated), `notes/designs/2026-07-11-merge-request-nudge-backoff.md` (status line)

- [ ] **Step 1: Full suite**

Run: `swift test`
Expected: green, and it **terminates** — which it only does thanks to the parent branch's fix. Report the wall-clock.

- [ ] **Step 2: Drive it in a real isolated daemon (never the live board)**

Per the `orchestra-isolated-testing` memory, use `scripts/orch-test.sh`: spawn a parent card and a child card on a branch parented to it, `orchestra merge-request <child>` with a short injected interval + cap, and watch the child's badge go amber → red while the parent's inbox collects exactly `cap` reminders and then goes quiet. Tear the instance down afterwards.

- [ ] **Step 3: Sanity-check both agent backends**

`CLAUDE.md` requires it. The nudge path never branches on `agentId`, so this is a confirmation that nothing regressed: run the isolated check above once with a `claude-code` parent card and once with a `codex` one.

- [ ] **Step 4: Update the design doc status + commit**

Set `**Status:** implemented` in `notes/designs/2026-07-11-merge-request-nudge-backoff.md`.

```bash
git add notes/designs/2026-07-11-merge-request-nudge-backoff.md
git commit -m "docs: mark the merge-request backoff design implemented"
```

- [ ] **Step 5: Review, then file the merge-request**

Use `superpowers:requesting-code-review` — cost-efficient Claude **and** GPT, iterating until neither has complaints — then `superpowers:verification-before-completion`, then file the merge-request up the tree with `orchestra merge-request 5c0a1e`.

---

## Follow-up (not this branch)

`plan/live-wake-delivery`'s **B5b** owns the stuck-surfacing seam (`AttentionReason` + `NotifyTrigger` +
the `AttentionTracker` one-shot). A message has been sent to that card asking it to record that
`TreeState.mergeStalled` rides the same seam — one extra `NeedsYouQueue.reason(for:)` case and one extra
`NotifyTrigger`. **Do not build that here**; it would be a second, competing stuck-surfacing stack
colliding in three shared enums.
