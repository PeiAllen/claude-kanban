# C2 · F2 wake + MergeWatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:test-driven-development, task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add `orchestra wait` + `MergeWatch` (conclusion detection from real card state) + F2 `wake` (Claude native re-invoke), so an orchestrator card can watch its spawned children and be woken when each concludes — with conclusions coalescing durably in the inbox (C1).

**Architecture:** `MergeWatch` is a **subscriber**, not a detector: it owns a continuation registry keyed on the watch set (the existing `awaitResume`/`resolveResume` pattern from `+Recovery.swift`). `OrchestraService` is the **single authority** that marks a card's *settled* terminal state and calls `concludeCard`, which (a) resolves any blocked `awaitConclusion` (the native-reinvoke wake — the CLI `orchestra wait` returns → exits → harness re-invokes), and (b) routes the conclusion into each registered watcher's durable inbox (F3, coalesces) + wakes it per `wakeTransport`. Conclusion is read from **real card state** (`.done`/archived, or a clean agent exit) — **never** `git merge-base` (the 0-commit-ancestor false positive). A transient crash (`sessionVanished`) that gets revived is **not** a conclusion.

**Tech Stack:** Swift, swift-testing (`@Suite`/`@Test`/`#expect`), actors + `CheckedContinuation`. Build/test unsandboxed via `scripts/test.sh`; typecheck via `scripts/typecheck-app.sh`.

## Global Constraints

- **Never `git merge-base` / git-ancestry for conclusion** — real card state only (0-commit-ancestor false positive).
- **MergeWatch is a subscriber** — no git poll, no FS stat, no per-card watcher; fed by the service via `conclude`.
- **Settled terminal only** — `archive`/Done + clean agent-exit conclude; `sessionVanished` (revivable crash) does NOT.
- **Additions are defaulted / behavior-preserving** — Claude suites (`ReportTests`, `RecoveryTests`, `InboxTests`) stay green.
- `USE_REAL_CLAUDE` stays unset; unit tests use `TestEnv.make()` stubs. No real vendor spawns.
- Reuse C1's `Inbox` + `StopDrain` for coalescing — do NOT add a parallel queue.

---

## File Structure

- **Create** `Sources/OrchestraCore/MergeWatch.swift` — `Conclusion` value type + `actor MergeWatch` (continuation registry: `awaitConclusion`/`conclude`/`cancel`).
- **Create** `Sources/OrchestraCore/OrchestraService+Wake.swift` — the C2 live-delivery extension: `wait`, `concludeCard`, `wake`, `registerWatch`, `isConcluded`, watch-registry state helpers.
- **Modify** `Sources/OrchestraCore/OrchestraService.swift` — add stored `let mergeWatch` + `var watchRegistry`; call `concludeCard(.done)` in `archive`.
- **Modify** `Sources/OrchestraCore/OrchestraService+Report.swift` — call `concludeCard(.exited)` on a clean agent exit (SessionEnd exit/logout/other).
- **Modify** `Sources/OrchestraCore/Commands.swift` — add the `wait` `Command` (registry → auto MCP; parity holds).
- **Modify** `Sources/orchestra/CLIRunner.swift` — add the `wait` verb (reads `$ORCHESTRA_TASK_ID` as the watcher; blocks; prints conclusion; exits → native re-invoke).
- **Modify** `Sources/orchestra/CLIHelp.swift` — one help line for `wait`.
- **Create** `Tests/OrchestraCoreTests/MergeWatchTests.swift` — pure MergeWatch unit tests.
- **Create** `Tests/OrchestraCoreTests/WakeMergeWatchTests.swift` — service-integration tests (the 6 required cases + coalesce + re-issue race).

---

## Interfaces (frozen for this plan)

```swift
// MergeWatch.swift
public struct Conclusion: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable { case done, exited }
    public let cardId: UUID
    public let ref: String
    public let kind: Kind
    public init(cardId: UUID, ref: String, kind: Kind)
}

public actor MergeWatch {
    public init()
    /// Block until ONE of `cardIds` concludes; returns that Conclusion, or nil if cancelled.
    /// SUBSCRIBER: never polls — the service feeds it via `conclude`.
    public func awaitConclusion(_ cardIds: Set<UUID>) async -> Conclusion?
    /// The service (single authority) informs the watcher a card settled terminal.
    public func conclude(_ c: Conclusion)
    /// Test/introspection: number of live waiters.
    public func waiterCount() -> Int
}

// OrchestraService+Wake.swift (on OrchestraService)
//   func wait(watcher: UUID?, refs: [UUID]) async -> Conclusion?     // real-state check → else block
//   func concludeCard(_ id: UUID, _ kind: Conclusion.Kind) async     // authority → route + resolve
//   func wake(_ id: UUID) async                                      // dispatch on wakeTransport
//   func registerWatch(_ watcher: UUID, _ children: Set<UUID>)       // durable inbox routing
//   func isConcluded(_ t: Task) -> Conclusion.Kind?                  // real card state, NOT git
```

---

### Task 1: `Conclusion` + `MergeWatch` continuation registry

**Files:**
- Create: `Sources/OrchestraCore/MergeWatch.swift`
- Test: `Tests/OrchestraCoreTests/MergeWatchTests.swift`

**Interfaces:**
- Produces: `Conclusion`, `actor MergeWatch` (see frozen block).
- Consumes: nothing (pure).

- [ ] **Step 1: Write failing tests** (`MergeWatchTests.swift`)

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("C2 · MergeWatch continuation registry (subscriber, not detector)")
struct MergeWatchTests {

    @Test("awaitConclusion resolves when the watched card concludes")
    func resolvesOnConclude() async throws {
        let mw = MergeWatch()
        let a = UUID()
        let waiting = _Concurrency.Task { await mw.awaitConclusion([a]) }
        try await pollUntil { await mw.waiterCount() == 1 }
        mw.conclude(Conclusion(cardId: a, ref: "orchestra://task/aaaaaa", kind: .done))
        let got = await waiting.value
        #expect(got?.cardId == a)
        #expect(got?.kind == .done)
        #expect(await mw.waiterCount() == 0)   // resolved waiter removed
    }

    @Test("a set watcher resolves on the FIRST of its cards to conclude")
    func firstOfSet() async throws {
        let mw = MergeWatch()
        let a = UUID(); let b = UUID()
        let waiting = _Concurrency.Task { await mw.awaitConclusion([a, b]) }
        try await pollUntil { await mw.waiterCount() == 1 }
        mw.conclude(Conclusion(cardId: b, ref: "r", kind: .exited))
        #expect(await waiting.value?.cardId == b)
    }

    @Test("conclude for an unwatched card resolves nothing")
    func unwatchedNoop() async throws {
        let mw = MergeWatch()
        let a = UUID(); let other = UUID()
        let waiting = _Concurrency.Task { await mw.awaitConclusion([a]) }
        try await pollUntil { await mw.waiterCount() == 1 }
        mw.conclude(Conclusion(cardId: other, ref: "r", kind: .done))
        try await _Concurrency.Task.sleep(for: .milliseconds(60))
        #expect(await mw.waiterCount() == 1)   // still waiting
        mw.conclude(Conclusion(cardId: a, ref: "r", kind: .done))   // cleanup
        _ = await waiting.value
    }

    @Test("cancellation unblocks awaitConclusion with nil and drops the waiter")
    func cancel() async throws {
        let mw = MergeWatch()
        let a = UUID()
        let waiting = _Concurrency.Task { await mw.awaitConclusion([a]) }
        try await pollUntil { await mw.waiterCount() == 1 }
        waiting.cancel()
        #expect(await waiting.value == nil)
        #expect(await mw.waiterCount() == 0)
    }
}

/// Poll a condition up to ~2s; fail if it never holds. Deterministic replacement for fixed sleeps.
func pollUntil(_ cond: @Sendable () async -> Bool) async throws {
    for _ in 0..<200 { if await cond() { return }; try await _Concurrency.Task.sleep(for: .milliseconds(10)) }
    #expect(Bool(false), "condition never became true")
}
```

- [ ] **Step 2: Run — expect FAIL** (`MergeWatch` undefined): `./scripts/test.sh --filter MergeWatchTests`

- [ ] **Step 3: Implement** `MergeWatch.swift`

```swift
import Foundation

/// A settled-terminal conclusion for a watched card. Conclusions ride the inbox (F3); artifacts ride git.
public struct Conclusion: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable { case done, exited }
    public let cardId: UUID
    public let ref: String
    public let kind: Kind
    public init(cardId: UUID, ref: String, kind: Kind) {
        self.cardId = cardId; self.ref = ref; self.kind = kind
    }
}

/// Conclusion-watch for the reactive fan-out (F2). A **subscriber, not a detector**: it owns NO
/// detection — no git poll, no file stat, no per-card watcher. `OrchestraService` (the single
/// authority for terminal state) feeds it via `conclude`; MergeWatch just parks a continuation keyed
/// on the watch set and resolves it when one of those cards concludes (the `awaitResume` pattern).
public actor MergeWatch {
    private var waiters: [UUID: (watch: Set<UUID>, cont: CheckedContinuation<Conclusion?, Never>)] = [:]

    public init() {}

    /// Block until ONE of `cardIds` concludes; returns that `Conclusion`, or nil if the task is
    /// cancelled (e.g. the `orchestra wait` process is killed). The caller re-issues on the remaining
    /// children — resolution is per-child, never a barrier on all N.
    public func awaitConclusion(_ cardIds: Set<UUID>) async -> Conclusion? {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Conclusion?, Never>) in
                if _Concurrency.Task.isCancelled { cont.resume(returning: nil); return }
                waiters[token] = (cardIds, cont)
            }
        } onCancel: {
            _Concurrency.Task { await self.cancel(token) }
        }
    }

    /// The authority informs the watcher a card settled terminal. Resolves EVERY waiter whose watch
    /// set contains it (each with its own copy) and drops them.
    public func conclude(_ c: Conclusion) {
        for (token, w) in waiters where w.watch.contains(c.cardId) {
            waiters.removeValue(forKey: token)
            w.cont.resume(returning: c)
        }
    }

    private func cancel(_ token: UUID) {
        if let w = waiters.removeValue(forKey: token) { w.cont.resume(returning: nil) }
    }

    public func waiterCount() -> Int { waiters.count }
}
```

- [ ] **Step 4: Run — expect PASS**: `./scripts/test.sh --filter MergeWatchTests`
- [ ] **Step 5: Commit** — `feat(c2): MergeWatch continuation registry + Conclusion (subscriber, not detector)`

---

### Task 2: Service authority — `concludeCard` / `wait` / `wake` / watch-registry

**Files:**
- Create: `Sources/OrchestraCore/OrchestraService+Wake.swift`
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add `let mergeWatch = MergeWatch()`, `var watchRegistry: [UUID: Set<UUID>] = [:]`; call `await concludeCard(id, .done)` at the end of `archive`)
- Modify: `Sources/OrchestraCore/OrchestraService+Report.swift` (call `await concludeCard(id, .exited)` on the clean-exit transition)
- Test: `Tests/OrchestraCoreTests/WakeMergeWatchTests.swift`

**Interfaces:**
- Consumes: `Inbox` (C1), `StopDrain`, `store`, `registry`, `MergeWatch`.
- Produces: `wait(watcher:refs:)`, `concludeCard(_:_:)`, `wake(_:)`, `registerWatch(_:_:)`, `isConcluded(_:)`.

- [ ] **Step 1: Write failing tests** (`WakeMergeWatchTests.swift`) — the 6 required cases + extras.

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("C2 · wake + merge-watch (real card state; subscriber; settled-terminal)")
struct WakeMergeWatchTests {

    // 1 · conclusion from real card state (archive → Done), driven off the lifecycle event.
    @Test("archive (move to Done) concludes a watched child")
    func concludesOnArchive() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.mergeWaiterCount() == 1 }
        try await env.svc.archive(child.id)
        let conc = await waiting.value
        #expect(conc?.cardId == child.id)
        #expect(conc?.kind == .done)
    }

    // 2 · 0-commit branch = NOT concluded (regression: never git merge-base).
    @Test("a live child on a 0-commit branch does NOT conclude (no git-ancestry false positive)")
    func zeroCommitNotConcluded() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        // Branch has no commits ahead of main (git merge-base would call it 'merged'); the card is alive.
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "ancestor"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.mergeWaiterCount() == 1 }
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        #expect(await env.svc.mergeWaiterCount() == 1)   // still blocked — real state, not git
        waiting.cancel(); _ = await waiting.value
    }

    // 3 · cancel.
    @Test("wait returns nil when cancelled")
    func waitCancels() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.mergeWaiterCount() == 1 }
        waiting.cancel()
        #expect(await waiting.value == nil)
    }

    // 4 · subscriber, not git-poll: resolution is driven by the service marking terminal (archive),
    //     and wait blocks until THEN even though nothing about git changed.
    @Test("watcher resolves only off the service's terminal transition, not any git state")
    func resolvesOffLifecycleEvent() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.mergeWaiterCount() == 1 }
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(await env.svc.mergeWaiterCount() == 1)          // no premature resolve
        try await env.svc.archive(child.id)                    // the single authority marks terminal
        #expect(await waiting.value?.cardId == child.id)       // now it resolves
    }

    // 5 · transient crash + revive (settled-terminal only).
    @Test("a crash (sessionVanished) that is revived does NOT conclude")
    func crashRevivedNotConcluded() async throws {
        let env = TestEnv.make(grace: 2)
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        env.adapter.writeTranscript(for: child.agentSessionId!)
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.mergeWaiterCount() == 1 }

        env.sessions.setAlive(child.id, false)
        await env.svc.reconcileLiveness()                      // → .dead sessionVanished (NOT a conclusion)
        try await _Concurrency.Task.sleep(for: .milliseconds(40))
        #expect(await env.svc.mergeWaiterCount() == 1)         // crash alone did not conclude

        // Revive it.
        async let resumed = env.svc.resume(child.id)
        try await _Concurrency.Task.sleep(for: .milliseconds(60))
        try await env.svc.report(child.id, StatusReport(sessionSource: "resume"))
        _ = try await resumed
        try await _Concurrency.Task.sleep(for: .milliseconds(40))
        #expect(await env.svc.mergeWaiterCount() == 1)         // revived → still not concluded
        waiting.cancel(); _ = await waiting.value
    }

    // 5b · a CLEAN agent exit IS a settled conclusion (.exited).
    @Test("a clean agent exit (SessionEnd exit) concludes with .exited")
    func cleanExitConcludes() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let waiting = _Concurrency.Task { await env.svc.wait(watcher: nil, refs: [child.id]) }
        try await pollUntil { await env.svc.mergeWaiterCount() == 1 }
        try await env.svc.report(child.id, StatusReport(event: EventReport(endReason: "exit")))
        #expect(await waiting.value?.kind == .exited)
    }

    // 6 · multi fan-out conclusions coalesce in the inbox (one drain, none lost).
    @Test("N children conclude → N inbox messages that drain together in one payload")
    func fanoutCoalesces() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let parent = try await env.svc.spawn(SpawnInput(prompt: "orch", repo: repo, branch: "orch"))
        let a = try await env.svc.spawn(SpawnInput(prompt: "A", repo: repo, branch: "a"))
        let b = try await env.svc.spawn(SpawnInput(prompt: "B", repo: repo, branch: "b"))
        let c = try await env.svc.spawn(SpawnInput(prompt: "C", repo: repo, branch: "c"))
        await env.svc.registerWatch(parent.id, [a.id, b.id, c.id])

        // Conclude all three while the parent is mid-turn (no active wait).
        try await env.svc.archive(a.id)
        try await env.svc.archive(b.id)
        try await env.svc.archive(c.id)

        let inbox = await env.svc.inbox
        #expect(await inbox.peek(parent.id).count == 3)          // none lost
        let payload = try #require(await env.svc.drainForStop(parent.id))
        #expect(payload.contains(a.shortId))                     // all three drain together
        #expect(payload.contains(b.shortId))
        #expect(payload.contains(c.shortId))
        #expect(await inbox.peek(parent.id).isEmpty)             // one drain cleared them
    }

    // extra · wait short-circuits on an already-concluded child (re-issue race).
    @Test("wait returns immediately if a watched child already concluded")
    func alreadyConcluded() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        try await env.svc.archive(child.id)                      // concludes before any wait
        let conc = await env.svc.wait(watcher: nil, refs: [child.id])
        #expect(conc?.cardId == child.id)
        #expect(conc?.kind == .done)
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`wait`/`mergeWaiterCount`/`registerWatch` undefined): `./scripts/test.sh --filter WakeMergeWatchTests`

- [ ] **Step 3a: Wire state into `OrchestraService.swift`.** Add stored properties near `inbox`:

```swift
    /// Conclusion-watch for the reactive fan-out (F2). Subscriber to this service's terminal
    /// transitions — the service is the single authority (see `concludeCard`).
    let mergeWatch = MergeWatch()
    /// Durable inbox routing for the fan-out: watcher card → the children it is watching. A child's
    /// conclusion enqueues into every watching parent's inbox (F3 coalesce) + wakes it (F2).
    var watchRegistry: [UUID: Set<UUID>] = [:]
```

  And at the end of `archive(...)`, AFTER the final `emitActivity(.archived, ...)`, add:

```swift
        await concludeCard(id, .done)   // moving to Done is a settled conclusion (F2/merge-watch)
```

- [ ] **Step 3b: Clean-exit conclusion in `OrchestraService+Report.swift`.** The clean-exit branch already sets `.dead`/`.agentExited` and `statusTransition = (…, .dead)`. After the function persists + emits (end of `report`), add — guarded so it only fires on the genuine exit transition and not while recovering:

```swift
        // A clean agent exit (SessionEnd exit/logout/other) is a SETTLED conclusion (.exited) — the
        // agent quit, no auto-resume. A transient crash (sessionVanished) is NOT concluded here; it may
        // still be revived (that path never runs this).
        if let tr = statusTransition, tr.to == .dead, saved.deadReason == .agentExited, !recovering.contains(id) {
            await concludeCard(id, .exited)
        }
```

  (Place this after `emit(.taskUpserted(saved))` / the activity block, using the already-bound `saved` + `statusTransition`.)

- [ ] **Step 3c: Implement** `OrchestraService+Wake.swift`

```swift
import Foundation

extension OrchestraService {

    // MARK: - F2 wake + merge-watch (C2)

    /// Register a watcher's interest in `children` so each child's conclusion routes into the watcher's
    /// durable inbox (F3, coalesces) and wakes it (F2). Idempotent (unions).
    public func registerWatch(_ watcher: UUID, _ children: Set<UUID>) {
        watchRegistry[watcher, default: []].formUnion(children)
    }

    /// Block until ONE of `refs` concludes; returns that `Conclusion` (or nil if cancelled). Backs
    /// `orchestra wait`. If `watcher` is set, its inbox coalesces every conclusion (F3) and it is woken
    /// per `wakeTransport` (F2). Reads conclusion from REAL card state — never `git merge-base`.
    public func wait(watcher: UUID?, refs: [UUID]) async -> Conclusion? {
        let children = Set(refs)
        if let watcher { registerWatch(watcher, children) }
        // Short-circuit on a child that is ALREADY settled-terminal (handles the re-issue race where a
        // child concluded between two `wait` calls). This IS the real-card-state read.
        for id in children {
            if let t = await store.get(id), let kind = isConcluded(t) {
                return Conclusion(cardId: id, ref: t.ref(), kind: kind)
            }
        }
        return await mergeWatch.awaitConclusion(children)
    }

    /// The single authority declares a card SETTLED terminal (a conclusion). Called from `archive`
    /// (Done) and a clean agent exit — NOT from a revivable crash. Routes the conclusion into every
    /// watching parent's inbox (F3) + wakes it (F2), then resolves any blocked `awaitConclusion` (the
    /// native-reinvoke wake: `orchestra wait` returns → its process exits → the harness re-invokes).
    func concludeCard(_ id: UUID, _ kind: Conclusion.Kind) async {
        guard let t = await store.get(id) else { return }
        let conc = Conclusion(cardId: id, ref: t.ref(), kind: kind)
        // F3 inbox routing + F2 wake for every registered watcher of this child.
        for (watcher, children) in watchRegistry where children.contains(id) {
            try? await inbox.enqueue(watcher, "Card \(t.shortId) concluded (\(kind.rawValue)).")
            watchRegistry[watcher]?.remove(id)
            if watchRegistry[watcher]?.isEmpty == true { watchRegistry[watcher] = nil }
            await wake(watcher)
        }
        // Resolve any active `orchestra wait` blocked on this child (per-child, first-wins).
        await mergeWatch.conclude(conc)
    }

    /// Trigger a turn on an idle card (F2), dispatched on the adapter's `wakeTransport`.
    func wake(_ id: UUID) async {
        guard let t = await store.get(id), let adapter = try? registry.get(t.agentId) else { return }
        switch adapter.capabilities.wakeTransport {
        case .nativeReinvoke:
            // No daemon push: the harness re-invokes when the card's background `orchestra wait` exits,
            // and that exit is driven by `mergeWatch.conclude` resolving the blocked wait. Nothing to
            // send. (An idle Claude card with no background wait stays inbox-durable until it next runs.)
            break
        case .sendKeys:
            break   // Codex send-keys nudge + detect-and-defer — C4 (deferred; nudge only, no content).
        case .controlChannel, .relaunch:
            break   // future transports.
        }
    }

    /// A card's conclusion kind from REAL card state, or nil if not settled-terminal. NEVER git.
    /// `.done`/archived = moved to Done; a clean agent exit (`.agentExited`) = `.exited`. A revivable
    /// crash (`sessionVanished`) is deliberately NOT terminal here.
    func isConcluded(_ t: Task) -> Conclusion.Kind? {
        if t.archived || t.status == .done { return .done }
        if t.status == .dead, t.deadReason == .agentExited { return .exited }
        return nil
    }

    /// Test/introspection: count of parked conclusion waiters.
    public func mergeWaiterCount() async -> Int { await mergeWatch.waiterCount() }
}
```

- [ ] **Step 4: Run — expect PASS**: `./scripts/test.sh --filter WakeMergeWatchTests`
- [ ] **Step 5: Run C1 + recovery regressions — expect PASS**: `./scripts/test.sh --filter "InboxTests"` and `--filter RecoveryTests` and `--filter ReportTests`
- [ ] **Step 6: Commit** — `feat(c2): OrchestraService merge-watch authority — concludeCard/wait/wake + inbox coalesce`

---

### Task 3: `wait` Command (registry → MCP) + `orchestra wait` CLI verb

**Files:**
- Modify: `Sources/OrchestraCore/Commands.swift` (add the `wait` `Command`)
- Modify: `Sources/orchestra/CLIRunner.swift` (add the `wait` verb)
- Modify: `Sources/orchestra/CLIHelp.swift` (help line)
- Test: `Tests/OrchestraCoreTests/CommandsTests.swift` (add a `wait` schema + roundtrip case) — else extend `WakeMergeWatchTests`.

**Interfaces:**
- Consumes: `svc.wait(watcher:refs:)`, `svc.resolveRef`.
- Produces: registry command `"wait"`; CLI verb `wait`.

- [ ] **Step 1: Write failing test** — add to `WakeMergeWatchTests.swift`:

```swift
    @Test("the `wait` command is registered (MCP parity) and round-trips a conclusion")
    func waitCommandRoundtrips() async throws {
        #expect(CommandRegistry().names.contains("wait"))
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let child = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let cmd = try #require(CommandRegistry().command("wait"))
        let waiting = _Concurrency.Task {
            try await cmd.run(env.svc, .object(["refs": .array([.string(child.id.uuidString)])]), .agent)
        }
        try await pollUntil { await env.svc.mergeWaiterCount() == 1 }
        try await env.svc.archive(child.id)
        let result = try await waiting.value
        #expect(result["cardId"]?.stringValue?.lowercased() == child.id.uuidString.lowercased())
        #expect(result["kind"]?.stringValue == "done")
    }
```

- [ ] **Step 2: Run — expect FAIL**: `./scripts/test.sh --filter waitCommandRoundtrips`

- [ ] **Step 3a: Add the `wait` Command** in `Commands.swift` (append inside `build()`'s array, after `send`):

```swift
            Command(name: "wait",
                    summary: "Block until one of the watched cards concludes (Done or clean exit). "
                        + "For the reactive fan-out — the caller re-issues on the remaining cards.",
                    params: schema([
                        "refs": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Card refs to watch — UUID/shortId/orchestra:// URI"),
                        ]),
                        "watcher": strProp("The watching card's ref; its inbox coalesces each conclusion "
                            + "and it is woken. Omit for a bare block-and-return."),
                    ], required: ["refs"])) { svc, p, src in
                guard let arr = p["refs"]?.arrayValue, !arr.isEmpty else {
                    throw OrchestraError.invalidParams("refs must be a non-empty array")
                }
                var ids: [UUID] = []
                for r in arr { ids.append(try await svc.resolveRef(try r.stringValue.orThrow()).id) }
                let watcher = try await p.optString("watcher").asyncMap { try await svc.resolveRef($0).id }
                guard let conc = await svc.wait(watcher: watcher, refs: ids) else {
                    return .object(["cancelled": .bool(true)])
                }
                return try JSONValue(encodable: conc)
            },
```

  > If `JSONValue` has no `stringValue.orThrow()` / `asyncMap` helpers, inline them:
  > resolve each ref via `svc.resolveRef(r.stringValue ?? "")`; resolve `watcher` with a plain
  > `if let w = p.optString("watcher") { watcher = try await svc.resolveRef(w).id }`. Keep it simple —
  > match the surrounding call sites in `Commands.swift`.

- [ ] **Step 3b: Add the CLI verb** in `CLIRunner.swift` `switch verb` (after `send`):

```swift
            case "wait":
                // Watch one or more child cards; block until one concludes, print it, and EXIT — the
                // Claude harness re-invokes the caller in-session (nativeReinvoke wake). The caller
                // re-issues `orchestra wait` on the cards that remain.
                let refs = flags.value("refs").map { $0.split(separator: ",").map(String.init) }
                    ?? flags.positionalsFrom(0)
                guard !refs.isEmpty else { die("wait needs at least one card ref") }
                var waitParams: [String: JSONValue] = ["refs": .array(refs.map { .string($0) })]
                // The watching (parent) card is this session's own id, if launched by Orchestra.
                if let self_ = ProcessInfo.processInfo.environment["ORCHESTRA_TASK_ID"], !self_.isEmpty {
                    waitParams["watcher"] = .string(self_)
                }
                let r = try await client.call("wait", .object(waitParams))
                if r["cancelled"]?.boolValue == true { print("wait cancelled") }
                else if let ref = r["ref"]?.stringValue, let kind = r["kind"]?.stringValue {
                    print("concluded: \(ref) (\(kind))")
                } else { printJSON(r) }
```

- [ ] **Step 3c: Help line** in `CLIHelp.swift` — add under the command list, e.g.:

```
  wait <ref…>            Block until a watched card concludes (reactive fan-out)
```

- [ ] **Step 4: Run — expect PASS**: `./scripts/test.sh --filter waitCommandRoundtrips`
- [ ] **Step 5: Run the parity + full core suite — expect PASS**: `./scripts/test.sh` (watch `E2EBinaryTests` parity: `names == Set(CommandRegistry().names)` must still hold — MCP auto-derives, CLI verb is manual).
- [ ] **Step 6: Commit** — `feat(c2): wait command (registry→MCP) + orchestra wait CLI verb (native re-invoke)`

---

### Task 4: Full green gate + advisory e2e

- [ ] **Step 1:** `./scripts/test.sh` — all green. If the ONLY failure is `RecoveryTests` "resume success: confirmed within grace" (known parallel-load flake), re-run `./scripts/test.sh --filter RecoveryTests` in isolation to confirm green, then treat as green.
- [ ] **Step 2:** `./scripts/typecheck-app.sh` — clean (self-pins CLT; no `DEVELOPER_DIR`).
- [ ] **Step 3 (advisory, O6):** `scripts/orch-ux-e2e.sh --run-id c2wake` — screenshot step may fail on a headless/locked window server (environmental, NOT a defect). Unit tests + typecheck are the gate.
- [ ] **Step 4:** Update docs breadcrumbs — `04-tests.md`/`02-contract.md`/`03-implementation.md` `Decisions made` note the as-built C2 symbols (`MergeWatch`, `Conclusion`, `concludeCard`, `wait` command). (Auto-sync handles `docs/`; this is the planning-truth secondary step.)
- [ ] **Step 5: Commit** any doc/breadcrumb edits — `docs(c2): record as-built merge-watch/wake symbols`.

---

## Self-Review

**Spec coverage (04-tests `MergeWatch`/`wake` row):**
- conclusion from real card state → `concludesOnArchive` / `alreadyConcluded` (via `isConcluded`, not git). ✓
- 0-commit branch = NOT concluded (regression) → `zeroCommitNotConcluded`. ✓
- cancel → `waitCancels` + MergeWatch `cancel`. ✓
- watcher resolves off the lifecycle event (subscriber, not git-poll) → `resolvesOffLifecycleEvent` + MergeWatch design (fed by `conclude`, no git). ✓
- transient crash + revive = NOT concluded (settled-terminal only) → `crashRevivedNotConcluded` + `isConcluded` excluding `sessionVanished`. ✓
- multi fan-out conclusions coalesce in the inbox → `fanoutCoalesces` (reuses C1 Inbox + StopDrain). ✓

**Critical design constraints (task prompt):**
- MergeWatch is a SUBSCRIBER on the service's terminal transitions + continuation keyed on the watch set (awaitResume pattern) — ✓ (no git/FS in MergeWatch; `conclude` is the only input).
- Service is the SINGLE authority (archive/Done + clean-exit) — ✓ (`concludeCard` only called from `archive` + report clean-exit).
- Key on SETTLED state; revived crash is NOT a conclusion — ✓ (`isConcluded` excludes `sessionVanished`; report clean-exit guarded by `!recovering`).
- Multi fan-out = one conclusion per child, coalesce in inbox, `wait` re-issues on remaining — ✓ (per-child `conclude`; inbox coalesce; CLI is single-shot + re-invoke re-issues; `wait` short-circuits already-concluded).
- Claude wakeTransport = nativeReinvoke: `orchestra wait` exits → harness re-invokes — ✓ (`mergeWatch.conclude` unblocks the wait → CLI prints + exits; `wake` nativeReinvoke = no-op).

**Placeholder scan:** none — all code is concrete. **Type consistency:** `Conclusion(cardId:ref:kind:)`, `Conclusion.Kind{done,exited}`, `wait(watcher:refs:)`, `mergeWaiterCount()`, `registerWatch(_:_:)` used identically across tasks. ✓

**Watch-outs during impl:**
- `EventReport(endReason:)` initializer spelling — verify against `StatusReport`/`EventReport` in `Model.swift` (test `cleanExitConcludes` constructs one). Adjust the test to the real initializer if needed.
- `JSONValue` helpers (`arrayValue`, `stringValue`, `optString`, `boolValue`) — confirm names in `Commands.swift`/`JSONValue.swift`; inline plain unwraps if the fancy `.orThrow()`/`.asyncMap` helpers don't exist.
- Reference rendering: the CLI prints `r["ref"]` — `Conclusion` encodes `ref` + `cardId` + `kind`; confirm the Codable key is `ref`.
