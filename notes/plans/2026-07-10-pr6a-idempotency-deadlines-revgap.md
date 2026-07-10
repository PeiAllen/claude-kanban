# PR6a — Idempotency + RPC Deadlines + rev-Gap Resync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **REVISION 5** — round 4 (Opus) caught a **critical deadlock my round-3 fix introduced**: the semaphore-bridged reconnect barrier parked the *sole reader thread* waiting for a subscribe ack only that thread could read → a healthy subscribe false-fails after `callTimeout` → infinite reconnect loop (and hangs `TransportReconnectTests`). Revision 5 replaces it with a **break-first + detached-Task success-gate** (reader live when the ack arrives) and adds `test_subscribeSuccessFiresOnReconnect` (the positive path the failure-only test masked). Also: capture-before/emit-after sibling-warning form (avoids self-match), PR6b reuse-on-retry cross-PR flag. See "## Review round 4 — resolution" at the bottom. Rounds 1–3 below.
>
> **REVISION 4** — incorporates plan-review rounds 1, 2 AND 3. Round 1: atomic spawn dedup, race-free `PendingCall` deadline, resolve-outside-the-lock, bounded `probeVersion`, non-breaking `subscribeWithRev()`, the subscribe→snapshot barrier, 4 new tests. Round 2 (Opus): dedicated `probeTimeout` + 2 nits. Round 3 (codex R2): **success-gate the subscribe barrier** (was failure-open — snapshot could run unsubscribed), **caller-suppliable ids** + narrowed retry-safety claim (bare per-invocation mint doesn't cover a human's blind re-click — that retention is PR6b), **deadline = wait-bound-not-execution** semantics documented, and strengthened tests. See "## Review rounds — resolutions" at the bottom.

**Goal:** Make `spawn`/`batch-spawn` idempotent over dropped connections (client-minted ids + an **atomic** server dedup), give `ControlClient.call` a race-free per-RPC deadline + a ping keepalive + a bounded first-connect probe, and add per-card `rev`-gated board apply + reconnect-driven resync in `BoardStore` (with the subscribe→snapshot registration barrier that closes the only in-live-connection loss window) so a stale/reordered event can never clobber newer board state.

**Architecture:** Wire-level convergence closers. Clients mint the card `UUID`; the daemon dedups atomically inside `TaskStore` (retry returns the existing card as-is, whatever its phase). `call` installs a `PendingCall` (continuation + timer + resolved-once flag) under one lock; a periodic `version` ping tears a silently-dead transport into the existing reconnect path; the first-connect `probeVersion` is watchdog-bounded. The board tracks the **highest applied `rev` per card** (not a single board-global cursor — see the load-bearing sparse-rev note) and applies a task event iff its envelope `rev` beats that card's; resync is driven by **reconnection** (the only real loss channel, once the subscribe→snapshot barrier is in place), which re-baselines the gate from a fresh `boardSnapshot.rev`.

**Tech Stack:** Swift (Swift Concurrency, `@unchecked Sendable` client), swift-testing / XCTest (`swift test`), newline-JSON-RPC over UDS, `Transport` protocol seam.

## Global Constraints

- **No auto-retrier anywhere.** Deadline expiry surfaces to the human/agent; idempotency makes manual re-issue safe **when the re-issue carries the same client id**. Do not add a client-side automatic re-send of a timed-out mutation.
- **Retry-safety needs a retained id, and that's the caller's job.** PR6a delivers the *wire mechanism* (required `SpawnInput.id` + atomic server dedup) **and makes the id caller-suppliable** (CLI `--id`; the MCP bridge preserves a supplied `id`, injecting one only when absent) so an agent/script can reuse the id it minted on a manual retry. **App-side reuse-on-retry** (SpawnSheet retaining the id of a failed/in-flight spawn) is **PR6b's** `isSpawning`/retry UX (Task 6.4) — out of PR6a scope; noted in the merge-request. A bare per-invocation mint alone does **not** make a human's blind re-click/re-run idempotent.
- **A per-RPC deadline bounds *waiting*, not *execution*** (standard RPC-deadline semantics, like gRPC). A call that times out locally may still have been written and executed by the daemon. This is coherent with the design: idempotent verbs (`spawn`) are retry-safe via dedup; `send` has no dedup because a re-sent message is deliberate user intent (finalization decision). Do not pretend a timeout implies non-execution.
- **Agent-agnostic.** No `if agentId == …`. Nothing in this PR is agent-specific.
- **Clean wire break, ship together.** `SpawnInput.id` is a **required** wire field; no back-compat for id-less spawns. All clients ship with the daemon.
- **Do NOT change `ControlClient.subscribe()`'s element type.** ~18 test files consume `subscribe()` and pattern-match `Event` cases; a new `subscribeWithRev()` carries rev to BoardStore with zero blast radius.
- **Stay in-scope.** Touch only the sites listed here. Do **not** edit PR5's actor-hygiene sites (`offActor` sweeps, telemetry debounce, snapshot-from-cache) or PR6b's UI/`displayState` work (`DisplayState.swift`, `SpawnSheet`, `RecoveryView`, terminal reconnect policy). Keep the parallel merge with PR5 clean.
- **`swift test` green after every task.** Authoritative gate: `swift test --no-parallel` (a known repo-wide real-tmux/UDS PTY-exhaustion flake shows only under the parallel run; re-run any such failure in isolation).
- **Fold deviations into the vault** (`notes/designs/lifecycle-convergence/03-implementation.md` + `04-tests.md` "Decisions made") and surface them in the merge-request.
- **Anchors drift.** PR1–PR4b landed since `f1aa568`; the `file:line` anchors below were re-verified on this branch tip but **search the symbol** if one has moved again.

---

## ⚠️ LOAD-BEARING: the sparse-rev contract + the loss-channel precondition (read before Task 6.3)

From PR1, folded into vault `03-implementation.md` Decisions (lines 164–165):

- `rev` bumps **only on a real state change** (`TaskStore.update` skips the bump on a no-op mutation).
- `rev` is **monotonic by value but MAY BE SPARSE** — not every bump carries a client event.
- **`spawn`'s deferred emit** (create → emit across `await`s) makes delivered `rev` **non-monotonic in wire order**: an event carrying a *lower* `rev` can arrive *after* one carrying a higher `rev`.

**Wire facts verified in this PR:**

1. `EventEnvelope` carries only a **board-global** `rev` (`Sources/OrchestraKit/Model.swift:1000`) — **no** per-subscriber sequence, no `prevRev`. A client cannot distinguish a sparse forward gap from a genuine missed event on a live stream.
2. A **board-global** `lastSeenRev` gate (the plan's original literal wording) is **UNSOUND**: post-snapshot, card X mutates to `rev 20` and card Y to `rev 12` (both real, both unseen); wire order delivers X(20) then Y(12); a global cursor at 20 would **drop Y(12)**. The spawn-deferred-emit reorder makes this routine. → gate **per card**.
3. **The only in-live-connection loss window is the subscribe→snapshot registration gap** (found in review). The daemon dispatches each request on a connection as a **detached `Task`** (`ControlServer.swift:72`) — requests are handled **concurrently**, and `ControlClient.subscribe()` issues the subscribe RPC from a **detached task** too (`ControlClient.swift:278`). So `boardSnapshot` can be handled *before* the subscriber is registered; a task event emitted in that window is dropped (the ring replays **activity only**, `ControlServer.swift:122-124`) and lost on a live connection. **Task 6.3 closes this with an awaited subscribe barrier** — only then is "reconnect is the only loss channel" TRUE, and only then is reconnect-only resync sound.

**The rule Task 6.3 implements (both reviewers must confirm):**

- Gate **per card**: apply `taskUpserted(t)` / `taskRemoved(id)` iff `env.rev > max(baselineRev, appliedRev[id])`. An unknown card (`appliedRev[id]` absent) is `-∞` → a create always passes the per-card check but still must clear the snapshot floor.
- `baselineRev` = the `rev` of the last adopted `boardSnapshot`; on adoption, `appliedRev.removeAll()`.
- **Adoption re-seats the cursor UNCONDITIONALLY — up OR down (cross-PR with PR5).** `adoptSnapshotRev` sets `baselineRev = rev` (never `max` with the old value). PR5's telemetry-persist debounce lets on-disk `rev` lag in-memory, so a hard crash can reload the daemon BELOW an observed rev; the reconnect snapshot is authoritative and the cursor must follow it downward (else the next post-reload event is dropped). Guarded by `test_snapshotReseatsCursorDownward`. Merge-gate: PR5's cached snapshot must keep `rev ≤ its true task-data rev`.
- **Never resync on a bare forward gap or a duplicate rev.** Resync is triggered by **reconnection** (adopts a fresh `boardSnapshot.rev`), never by gap size.
- **Subscribe barrier:** the subscribe RPC is **awaited** (server registration is synchronous under lock before its reply — `ControlServer.swift:117-126`) **before** `boardSnapshot`, on both first connect and reconnect.
- `activity` / `agentTerminalOwner` / `shellsChanged` are **not** rev-gated.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/OrchestraKit/Model.swift` | `SpawnInput.id: UUID` required (memberwise init + `CodingKeys` + `init(from:)`) | 6.1 |
| `Sources/OrchestraCore/TaskStore.swift` | `createIfAbsent(_:) -> (task, rev, created)` — atomic get-or-append (no `await` between) | 6.1 |
| `Sources/OrchestraCore/OrchestraService.swift` | Spawn dedup via `createIfAbsent`; drop `UUID()` mint (`:330`); return existing before side effects | 6.1 |
| `Sources/OrchestraCore/CommandRegistry.swift` | Read `id` from params in `spawn` + `batch-spawn` handlers | 6.1 |
| `Sources/OrchestraUI/BoardStore.swift` | Client-mint id; `subscribeWithRev`; awaited subscribe barrier; per-card `rev` gate; `baselineRev` on snapshot | 6.1, 6.3 |
| `Sources/orchestra/CLIRunner.swift` | Client-mint id in `spawn` + `batch-spawn` | 6.1 |
| `Sources/orchestra-mcp/main.swift` | Inject `id` into `spawn`/`batch-spawn` args (mirror the `wait`/`watcher` block) | 6.1 |
| `Sources/OrchestraKit/JSONValue.swift` | `uuid(_:)` param helper | 6.1 |
| `Sources/OrchestraKit/CommandCatalog.swift` | Optional `id` param on the `spawn`/`batch-spawn` MCP schemas (agent-discoverable retry id) | 6.1 |
| `Sources/OrchestraKit/Control/ControlClient.swift` | `PendingCall` deadline; bounded `probeVersion`; ping loop; `subscribeWithRev`; awaited reconnect re-subscribe | 6.2, 6.3 |
| `Tests/OrchestraCoreTests/IdempotencyTests.swift` (new) | `test_spawnWithClientIdIsIdempotent`, `test_batchSpawnRetryIsIdempotent`, `test_concurrentSameIdSpawnCreatesOne` (+ no-dup-activity), `test_spawnParamRetryIsIdempotent` (wire path) | 6.1 |
| `Tests/OrchestraCoreTests/ControlClientTests.swift` (new) | `test_callTimesOut`, `test_callTimesOutNearZero`, `test_pingDetectsDeadTunnel`, `test_firstConnectProbeTimesOut`, `test_subscribeAwaitedBeforeSnapshot`, `test_subscribeFailureDoesNotFireOnReconnect`, `test_subscribeSuccessFiresOnReconnect` (+ `StubTransport`) | 6.2, 6.3 |
| `Tests/OrchestraUITests/BoardStoreTests.swift` (new) | `test_staleEventDropped`, `test_revGapTriggersResync`, `test_forwardGapDoesNotResync` | 6.3 |

> Docs: Stage 6's SSOT doc update is Task 6.6, owned by PR6b. This PR folds its deviations into the **vault** Decisions tables and names them in the merge-request; it does not touch `docs/`.
>
> The idempotency tests live in `OrchestraCoreTests` (not `IntegrationTests`) because the deterministic daemon harness (`TestEnv.make()`) and the concurrent-spawn precedent (`SpawnRaceTests.swift`) are there — a deviation from the spec's suggested path, justified by harness availability.

---

## Task 6.1: Client-minted ids + ATOMIC spawn dedup

**Files:** `Model.swift` (`SpawnInput` `:1061`), `JSONValue.swift` (`:77`), `TaskStore.swift` (`create` `:148`), `OrchestraService.swift` (`spawn` `:321`, mint `:330`), `CommandRegistry.swift` (`spawn` `:79`, `batch-spawn` `:324`), `BoardStore.swift` (`spawn` `:670`), `CLIRunner.swift` (`:29`, `batchSpawn` `:302`), `orchestra-mcp/main.swift` (`:68`). Test: `Tests/OrchestraCoreTests/IdempotencyTests.swift` (create).

**Interfaces:**
- Consumes: `TestEnv.make()` / `env.svc` harness (`SpawnRaceTests.swift`); `TaskStore.currentRev`.
- Produces: `SpawnInput.id: UUID` (required, first stored property). `TaskStore.createIfAbsent(_ task:) throws -> (task: Task, rev: Int, created: Bool)` — returns the existing card (`created:false`) if `task.id` is already present, else appends (`created:true`), **with no `await` in between** (atomic within the actor). `OrchestraService.spawn` returns the existing card unchanged when it already exists.

- [ ] **Step 1: Write the failing tests**

Mirror `SpawnRaceTests.swift`'s harness (`TestEnv.make()`, `env.svc.spawn`, `env.svc.list`). Create `Tests/OrchestraCoreTests/IdempotencyTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

@Suite("Spawn idempotency (client-minted ids)")
struct IdempotencyTests {
    // Two spawns with the SAME id create ONE card; the second returns the existing card as-is.
    @Test func test_spawnWithClientIdIsIdempotent() async throws {
        let env = TestEnv.make(); let repo = TestEnv.repo(env.base)
        let id = UUID()
        let first  = try await env.svc.spawn(SpawnInput(id: id, prompt: "p", repo: repo, branch: "b"))
        let second = try await env.svc.spawn(SpawnInput(id: id, prompt: "p", repo: repo, branch: "b"))
        #expect(first.id == id); #expect(second.id == id)
        #expect(await env.svc.list(includeArchived: true).filter { $0.id == id }.count == 1)
    }

    // A partially-acked batch retried with the same per-item ids creates no duplicates.
    @Test func test_batchSpawnRetryIsIdempotent() async throws {
        let env = TestEnv.make(); let repo = TestEnv.repo(env.base)
        let ids = [UUID(), UUID(), UUID()]
        let inputs = ids.enumerated().map { SpawnInput(id: $1, prompt: "p", repo: repo, branch: "b\($0)") }
        _ = await env.svc.batchSpawn(inputs)
        _ = await env.svc.batchSpawn(inputs)          // full retry, same ids
        for id in ids { #expect(await env.svc.list(includeArchived: true).filter { $0.id == id }.count == 1) }
    }

    // CONCURRENT same-id spawns (the real retry-races-original case) create exactly one card AND
    // emit no duplicate/spurious activity (the loser must not fire the "second live card" warning).
    @Test func test_concurrentSameIdSpawnCreatesOne() async throws {
        let env = TestEnv.make(); let repo = TestEnv.repo(env.base)
        let box = EventBox()
        let stream = await env.svc.subscribe()
        let collector = _Concurrency.Task { for await e in stream { await box.add(e.event) } }
        let id = UUID()
        async let a = env.svc.spawn(SpawnInput(id: id, prompt: "p", repo: repo, branch: "b"))
        async let b = env.svc.spawn(SpawnInput(id: id, prompt: "p", repo: repo, branch: "b"))
        _ = try await (a, b)
        #expect(await env.svc.list(includeArchived: true).filter { $0.id == id }.count == 1)
        try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        let warnings = await box.events.filter { if case .activity(let it) = $0 { return it.kind == .warning } else { return false } }
        #expect(warnings.isEmpty, "a same-id retry must not emit a spurious multiplicity warning")
        collector.cancel()
    }

    // The WIRE path (command params carry `id`), not just the service API: two spawn requests with the
    // same `id` param dedup to one card — proving the registry handler reads `id` and dedups.
    @Test func test_spawnParamRetryIsIdempotent() async throws {
        let env = TestEnv.make(); let repo = TestEnv.repo(env.base)
        let id = UUID()
        let params = JSONValue.object(["id": .string(id.uuidString), "prompt": .string("p"),
                                       "repo": .string(repo), "branch": .string("b")])
        _ = try await env.dispatch("spawn", params)     // use the available registry/RPC dispatch harness
        _ = try await env.dispatch("spawn", params)
        #expect(await env.svc.list(includeArchived: true).filter { $0.id == id }.count == 1)
    }
}
```

> `EventBox` is the actor accumulator used by `ControlRoundTripTests`. `env.dispatch(_:_:)` stands in for the project's available way to drive a verb through `CommandRegistry`/`ControlServer` (copy the round-trip harness); if none is readily reusable at the service level, drive the registry handler closure directly with the params.
```

- [ ] **Step 2: Run to verify failure** — `swift test --no-parallel --filter IdempotencyTests` → FAIL to compile (`SpawnInput` has no `id:`), then `test_concurrentSameIdSpawnCreatesOne` fails on 2 cards once it compiles.

- [ ] **Step 3: `SpawnInput.id` required + `uuid` helper** — same as Revision 1 Step 3: add `public var id: UUID` (first stored property, no default) to the memberwise init + `CodingKeys` + a required decode in `init(from:)`; add `JSONValue.uuid(_:)`:

```swift
public func uuid(_ key: String) throws -> UUID {
    guard let s = self[key]?.stringValue, let u = UUID(uuidString: s) else {
        throw OrchestraError.invalidParams("\(key) must be a UUID string")
    }
    return u
}
```

- [ ] **Step 4: Atomic dedup in `TaskStore`** — add `createIfAbsent` beside `create` (`:148`). It must have **no `await`** between the presence check and the append (the actor owns `tasks`, so get+append is atomic):

```swift
/// Atomic get-or-create keyed on `task.id`: returns the existing card (created:false) if the id is
/// already present, else appends it (created:true). No `await` between check and append, so two
/// concurrent same-id callers cannot both append — the idempotency boundary (a check-then-act in the
/// service actor is NOT atomic, because every `await` re-enters).
@discardableResult
public func createIfAbsent(_ task: Task) throws -> (task: Task, rev: Int, created: Bool) {
    ensureLoaded()
    if let existing = tasks.first(where: { $0.id == task.id }) { return (existing, currentRev, false) }
    var t = task
    t.order = nextOrder(in: t.column)
    t.updatedAt = Date()
    tasks.append(t)
    try persist()
    return (t, currentRev, true)
}
```

- [ ] **Step 5: Route spawn through `createIfAbsent`; no side effects before it**

In `OrchestraService.spawn` (`:321`): use `input.id`, and **short-circuit before any side effect** (adapter resolution, `resolveRepo`, scratch mkdir, sibling warning) if the card already exists. The cleanest boundary: check existence first, then do the full create through `createIfAbsent` at the point the code currently calls `store.create`.

```swift
public func spawn(_ input: SpawnInput, source: ActivitySource = .daemon) async throws -> Task {
    // Idempotency (#15): a retried spawn with the same client-minted id returns the existing card
    // AS-IS, whatever its phase. Fast-path exit BEFORE any side effect; the authoritative single-
    // winner guarantee is the atomic createIfAbsent at the create point below (covers the concurrent
    // race the fast path can't).
    if let existing = await store.get(input.id) { return existing }

    let resolvedAgentId = input.agentId ?? input.model.flatMap { registry.adapter(forModel: $0)?.id } ?? config.defaultAgentId
    let adapter = try registry.get(resolvedAgentId)
    let id = input.id                                     // was: let id = UUID()
    // …materialize cwd / origin as today…

    // At the create point (was `store.create(task)`): use the atomic dedup. If a concurrent spawn
    // won the race, `created == false` → return its card and roll back anything this call made
    // (scratch dir is id-named + idempotent; a worktree is join-by-branch, so a shared tree is fine).
    let (created, rev, wasCreated) = try await store.createIfAbsent(task)
    if !wasCreated { return created }
    // …existing post-create path (emit .taskUpserted with `rev`, transition(.creatingWorktree), etc.)…
}
```

> Verify the exact create call site in `spawn` (search `store.create(`); thread `(created, rev, wasCreated)` into the existing emit/transition path. The fast-path `store.get` avoids doing side-effect work for the common sequential retry; `createIfAbsent` is the correctness backstop for the concurrent race.
>
> **Sibling-warning gating (Codex R2 §3 / Opus N-a):** the sibling-multiplicity warning (`OrchestraService.swift:357-363`, "spawning a second live card onto branch …") currently runs *before* the create point, so a concurrent same-branch *loser* would emit a spurious warning before dedup returns the winner. **Capture the sibling boolean BEFORE `createIfAbsent`** (while this card is not yet in the store — no self-match) and **emit the warning AFTER, only if `wasCreated`**. Do NOT simply move the scan past `createIfAbsent`: it would then find the winner's *own* just-created card and warn about itself (unless you add `$0.id != id`). `test_concurrentSameIdSpawnCreatesOne`'s no-dup-warning assertion catches a naive move.

In `CommandRegistry.swift`: `spawn` handler reads `id: try p.uuid("id")`; `batch-spawn` item reads `id: try item.uuid("id")` (as Revision 1).

- [ ] **Step 6: Clients mint the id — and make it caller-suppliable where retry-safety is achievable**
  - `BoardStore.spawn`: `let id = UUID()` into params + optimistic apply (as Revision 1). (Reuse-on-retry is PR6b.)
  - `CLIRunner` single `spawn`: **honour a `--id` flag if present, else mint** — `fields["id"] = .string((flags.value("id").flatMap(UUID.init(uuidString:)) ?? UUID()).uuidString)`. Add `--id <uuid>` to `CLIHelp`. A script that retries `spawn` reuses its `--id` → dedup.
  - `CLIRunner` `batchSpawn`: stamp a per-item id only where absent (preserve a caller-supplied item `id`): `if case .object(var f) = item, f["id"] == nil { f["id"] = .string(UUID().uuidString) }`.
  - `orchestra-mcp/main.swift`: inject `id` for `spawn`/`batch-spawn` **only when absent** (`if f["id"] == nil` / per-item), mirroring the `wait`/`watcher` block — so an agent that supplies+reuses an `id` gets dedup, and one that doesn't still spawns.
  - **`CommandCatalog.swift`: add `id` to the `spawn` (`:59-79`) and `batch-spawn` (`:291-295`) param schemas** (optional, NOT in `required` — the MCP bridge mints when absent), e.g. `"id": strProp("Client-minted UUID for idempotent retry — reuse the SAME id when re-issuing after a timeout to avoid a duplicate card; omit to have one minted (not retry-safe).")`. Without this, `tools/list` (generated from `CommandCatalog`, `orchestra-mcp/main.swift:27-33`) never advertises `id`, so an agent can't discover the retry mechanism (Codex R3). This is the schema half of caller-suppliable ids.

- [ ] **Step 7: Compile sweep** — every `SpawnInput(...)` now needs `id:` (e.g. `SpawnRaceTests.swift`, handoff/fork/reconciler sites). `swift build 2>&1 | grep "missing argument"`; add `id: UUID()` to each.

- [ ] **Step 8: Run to verify pass** — `swift test --no-parallel --filter IdempotencyTests` → PASS (incl. the concurrent test). Then `swift test --no-parallel` → green.

- [ ] **Step 9: Commit** — `git commit -am "feat(sync): client-minted ids + atomic spawn dedup (idempotent spawn/batch-spawn)"`

---

## Task 6.2: Race-free per-RPC deadline + bounded probe + ping keepalive

**Files:** `Sources/OrchestraKit/Control/ControlClient.swift` (`call` `:152`, `probeVersion` `:117`, `close` `:133`, `failPending` `:350`, `readUntilEOF` `:328`, init `:45`, `launchRunLoop` `:95`). Test: `Tests/OrchestraCoreTests/ControlClientTests.swift` (create).

**Interfaces:**
- Consumes: `Transport` (`Transport.swift:13`); `ControlClient(transport:source:clientId:)` (`:45`).
- Produces: race-free single-resolution via a `PendingCall` record; `call` throws within `callTimeout`; `probeVersion` bounded by `callTimeout`; a ping loop flips `state → .retrying` on a dead-but-open tunnel. New init params `callTimeout`/`pingInterval` (default `.seconds(15)`/`.seconds(20)`; injectable).

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/ControlClientTests.swift` with a controllable `StubTransport` (answers `version` until `goDead()`; `readLine` blocks until fed; records written method-frames in order):

```swift
import Testing
import Foundation
@testable import OrchestraKit

final class StubTransport: Transport, @unchecked Sendable {
    private let cond = NSCondition()
    private var inbound: [Data] = []
    private var closed = false, dead = false
    var answerVersion = true
    private(set) var writes: [String] = []           // methods written, in order (for the barrier test)

    func goDead() { cond.lock(); dead = true; cond.signal(); cond.unlock() }
    func open() throws { cond.lock(); let d = dead; cond.unlock(); if d { throw OrchestraError.io("dead") } }

    func write(_ data: Data) -> Bool {
        let msg = try? RPCCodec.decoder.decode(WireMessage.self, from: data)
        cond.lock()
        if let m = msg?.method { writes.append(m) }
        let isDead = dead
        if let m = msg?.method, m == "version", let id = msg?.id, answerVersion, !dead {
            inbound.append(#"{"id":\#(id),"result":{}}"#.data(using: .utf8)!); cond.signal()
        }
        // NOTE: the barrier test manually feeds a `subscribe`/`boardSnapshot` reply via feed(id:).
        cond.unlock()
        return !isDead
    }
    func feed(_ data: Data) { cond.lock(); inbound.append(data); cond.signal(); cond.unlock() }
    func readLine() -> Data? {
        cond.lock(); defer { cond.unlock() }
        while inbound.isEmpty && !closed && !dead { cond.wait() }
        return (closed || dead) ? nil : inbound.removeFirst()
    }
    func shutdown() { cond.lock(); closed = true; cond.signal(); cond.unlock() }
    func close()    { cond.lock(); closed = true; cond.signal(); cond.unlock() }
}

@Suite struct ControlClientTests {
    // A call against a dead-but-open transport (no EOF, no reply) throws within the deadline.
    @Test func test_callTimesOut() async throws {
        let stub = StubTransport()
        let c = ControlClient(transport: { stub }, source: .cli, callTimeout: .milliseconds(200), pingInterval: .seconds(3600))
        try c.connect()
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) { _ = try await c.call("list", .object([:])) }
        #expect(ContinuousClock.now - start < .seconds(2)); c.close()
    }

    // The timer-arm-before-insert race (Codex B3): a near-zero timeout must still resolve exactly once
    // (throw), never double-resume (crash) and never leak (hang).
    @Test func test_callTimesOutNearZero() async throws {
        let stub = StubTransport()
        // probeTimeout defaults to 15s, so the near-zero CALL deadline can't racily fail connect()'s probe.
        let c = ControlClient(transport: { stub }, source: .cli, callTimeout: .nanoseconds(1), pingInterval: .seconds(3600))
        try c.connect()
        await #expect(throws: (any Error).self) { _ = try await c.call("list", .object([:])) }
        c.close()
    }

    // The keepalive marks the connection degraded when pings stop returning.
    @Test func test_pingDetectsDeadTunnel() async throws {
        let stub = StubTransport()
        let c = ControlClient(transport: { stub }, source: .cli, callTimeout: .milliseconds(200), pingInterval: .milliseconds(100))
        try c.connect(); #expect(c.state == .live)
        stub.answerVersion = false
        var degraded = false
        for _ in 0..<50 { if c.state == .retrying { degraded = true; break }; try? await Task.sleep(for: .milliseconds(50)) }
        #expect(degraded); c.close()
    }

    // A dead-but-open tunnel on FIRST connect must not hang connect() forever (bounded probeVersion).
    @Test func test_firstConnectProbeTimesOut() async throws {
        let stub = StubTransport(); stub.answerVersion = false          // never answers the probe
        // probeTimeout short so the test doesn't wait the 15s default.
        let c = ControlClient(transport: { stub }, source: .cli, callTimeout: .seconds(5),
                              pingInterval: .seconds(3600), probeTimeout: .milliseconds(200))
        let start = ContinuousClock.now
        #expect(throws: (any Error).self) { try c.connect() }           // throws, doesn't hang
        #expect(ContinuousClock.now - start < .seconds(2)); c.close()
    }
}
```

> Confirm the `WireMessage`/`RPCCodec` reply shape (`{"id":…,"result":…}`) decodes; adjust the literal if field names differ. `test_subscribeAwaitedBeforeSnapshot` is added in Task 6.3.

- [ ] **Step 2: Run to verify failure** — `swift test --no-parallel --filter ControlClientTests` → FAIL to compile (no `callTimeout:` param), then `test_callTimesOut`/`test_firstConnectProbeTimesOut` hang on unfixed code.

- [ ] **Step 3: `PendingCall` record + single-resolution funnel**

Replace the bare `pending: [Int: CheckedContinuation<…>]` with a record holding continuation + timer + resolved flag, all mutated under `stateLock`:

```swift
private final class PendingCall {
    let cont: CheckedContinuation<JSONValue, Error>
    var timer: _Concurrency.Task<Void, Never>?
    var resolved = false
    init(_ c: CheckedContinuation<JSONValue, Error>) { cont = c }
}
private var pending: [Int: PendingCall] = [:]          // guarded by stateLock
private let callTimeout: Duration
private let pingInterval: Duration
private let probeTimeout: Duration                     // first-connect probe bound — DECOUPLED from callTimeout
private var pingTask: _Concurrency.Task<Void, Never>?

public init(transport: @escaping @Sendable () -> Transport, source: ActivitySource = .app,
            clientId: String? = nil,
            callTimeout: Duration = .seconds(15), pingInterval: Duration = .seconds(20),
            probeTimeout: Duration = .seconds(15)) {
    self.makeTransport = transport; self.source = source; self.clientId = clientId
    self.callTimeout = callTimeout; self.pingInterval = pingInterval; self.probeTimeout = probeTimeout
}

/// The SINGLE resolution point. Takes the pending record iff still unresolved, flips resolved,
/// cancels its timer, removes it — then resumes OUTSIDE the lock (NSLock is non-recursive; resuming
/// a continuation that awaits could re-enter). Idempotent: a second call for the same id no-ops.
private func resolve(_ id: Int, _ result: Result<JSONValue, Error>) {
    let p: PendingCall? = stateLock.withLock {
        guard let p = pending[id], !p.resolved else { return nil }
        p.resolved = true; p.timer?.cancel(); pending[id] = nil; return p
    }
    guard let p else { return }
    switch result {
    case .success(let v): p.cont.resume(returning: v)
    case .failure(let e): p.cont.resume(throwing: e)
    }
}
```

Rewrite `call` — **install the continuation FIRST**, then create the timer, then attach it under the lock only if still pending (so an early-firing timer that already resolved just cancels; a continuation is never left without a live resolver):

```swift
@discardableResult
public func call(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
    let id = stateLock.withLock { let i = nextId; nextId += 1; return i }
    let req = RPCRequest(id: id, method: method, params: params, source: source.rawValue, clientId: clientId)
    let line = try RPCCodec.line(req)
    return try await withCheckedThrowingContinuation { cont in
        let p = PendingCall(cont)
        stateLock.withLock { pending[id] = p }                        // continuation live FIRST
        let timer = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: self?.callTimeout ?? .seconds(15))
            if _Concurrency.Task.isCancelled { return }
            self?.resolve(id, .failure(OrchestraError.io("call '\(method)' timed out")))
        }
        let attached = stateLock.withLock { () -> Bool in
            guard let p = pending[id], !p.resolved else { return false }
            p.timer = timer; return true
        }
        if !attached { timer.cancel() }                              // already resolved (instant reply)
        let ok = writeLock.withLock { transport?.write(line) ?? false }
        if !ok { resolve(id, .failure(OrchestraError.io("write failed"))) }
    }
}
```

Route the other resolution sites through `resolve`:
- `readUntilEOF` (`:328-333`): `resolve(id, msg.error.map { .failure($0) } ?? .success(msg.result ?? .null))`.
- `failPending` (`:350`): snapshot ids under the lock, then `for id in ids { resolve(id, .failure(OrchestraError.io("connection dropped"))) }` OUTSIDE the lock.
- `close` (`:133`): snapshot ids under the lock, resolve each outside the lock, then `eventContinuation?.finish()` **and `envelopeContinuation?.finish()`** (Task 6.3 adds the second); also `pingTask?.cancel()`.

> **Deadline semantics (deliberate — Codex R2 §4):** the timer can fire *after* the write has been enqueued (esp. a near-zero timeout), so a timed-out call **may still execute on the daemon**. A per-RPC deadline bounds how long the *caller waits*, not whether the request *runs* (standard RPC-deadline semantics). This is coherent with the design: `spawn` is retry-safe via dedup; `send` has no dedup because a re-sent message is user intent. We do **not** add a racy pre-write "is it still pending?" check — it gives false assurance (the timer can fire between the check and the write) and contradicts the honest semantics. `test_callTimesOutNearZero` therefore asserts only that the call *throws* (resolves once), not that no write occurred.

- [ ] **Step 4: Bound `probeVersion`** — add a watchdog so first-connect can't hang on a dead-but-open tunnel:

```swift
private func probeVersion(on t: Transport) throws {
    let id = stateLock.withLock { let i = nextId; nextId += 1; return i }
    let req = RPCRequest(id: id, method: "version", params: nil, source: source.rawValue, clientId: clientId)
    guard t.write(try RPCCodec.line(req)) else { throw OrchestraError.io("version probe write failed") }
    // Watchdog: if no reply within probeTimeout, shutdown() the transport so readLine() returns nil → throw.
    // NOTE: bound by probeTimeout, NOT callTimeout — an aggressive product callTimeout (or the near-zero
    // test) must not make first-connect flaky (Opus NEW-1).
    let watchdog = _Concurrency.Task { [probeTimeout] in
        try? await _Concurrency.Task.sleep(for: probeTimeout)
        if !_Concurrency.Task.isCancelled { t.shutdown() }
    }
    defer { watchdog.cancel() }
    while let line = t.readLine() {
        guard !line.isEmpty, let msg = try? RPCCodec.decoder.decode(WireMessage.self, from: line) else { continue }
        if msg.id == id { if let err = msg.error { throw err }; return }
    }
    throw OrchestraError.io("daemon did not answer version probe (connection closed)")
}
```

- [ ] **Step 5: Ping keepalive (async, ms-accurate)** — launch one ping loop from `launchRunLoop` using `Task.sleep(for: pingInterval)` (not `Thread.sleep`+`components.seconds`, which truncates sub-second intervals):

```swift
private func launchRunLoop() {
    DispatchQueue.global().async { [weak self] in self?.runLoop() }
    stateLock.withLock {
        pingTask?.cancel()
        pingTask = _Concurrency.Task { [weak self] in await self?.pingLoop() }
    }
}

/// Detects a dead-BUT-OPEN tunnel the reader can't see. On a ping timeout: flip .retrying and
/// shutdown() the transport → reader EOF → runLoop reconnects. Safe across mutations (idempotent).
private func pingLoop() async {
    while !stateLock.withLock({ stopping }) {
        try? await _Concurrency.Task.sleep(for: pingInterval)
        if stateLock.withLock({ stopping }) { return }
        guard stateLock.withLock({ state == .live }) else { continue }
        do { _ = try await call("version") }                         // carries the per-call deadline
        catch {
            guard stateLock.withLock({ state == .live }) else { continue }
            setState(.retrying)
            writeLock.withLock { transport }?.shutdown()
        }
    }
}
```

- [ ] **Step 6: Run to verify pass** — `swift test --no-parallel --filter ControlClientTests` → PASS (all 4). Regression check: `swift test --no-parallel --filter "ControlRoundTrip|TransportReconnect"` → PASS. Then `swift test --no-parallel` → green.

- [ ] **Step 7: Commit** — `git commit -am "feat(sync): race-free per-RPC deadline + bounded probe + ping keepalive"`

---

## Task 6.3: Per-card `rev`-gated apply + subscribe barrier + reconnect resync

> Read the LOAD-BEARING section. Gate is **per card**; resync is **reconnect-driven**; the **subscribe→snapshot barrier** is what makes reconnect the only loss channel.

**Files:** `ControlClient.swift` (`subscribeWithRev` new; awaited reconnect re-subscribe `:304-308`); `BoardStore.swift` (stream consumer `:452-463`, `apply` `:587`, `refresh` `:475`, `spawn` optimistic apply `:685`). Tests: `Tests/OrchestraUITests/BoardStoreTests.swift` (create) + `test_subscribeAwaitedBeforeSnapshot` in `ControlClientTests.swift`.

**Interfaces:**
- Consumes: `EventEnvelope` (`Model.swift:1000`); `BoardSnapshot.rev` (`Model.swift:1027`).
- Produces: `ControlClient.subscribeWithRev() -> AsyncStream<EventEnvelope>` (does **not** auto-issue the subscribe RPC — the caller awaits it as a barrier); `BoardStore.apply(_ env: EventEnvelope)` (rev-gated); `BoardStore.adoptSnapshotRev(_ rev: Int)`. The existing `subscribe() -> AsyncStream<Event>` and the ungated `apply(_ event: Event)` are unchanged.

- [ ] **Step 1: Write the failing tests**

`Tests/OrchestraUITests/BoardStoreTests.swift` (mirror `BoardModelPlatformTests.swift`'s `model` construction + `Task` fixture builder):

```swift
import Testing
import Foundation
@testable import OrchestraUI
@testable import OrchestraKit

@Suite @MainActor struct BoardStoreTests {
    private func makeCard(_ title: String) -> Task { /* copy from BoardModelPlatformTests */ }

    @Test func test_staleEventDropped() throws {
        let model = TestModel.make()
        var card = makeCard("v-new")
        model.apply(EventEnvelope(rev: 10, event: .taskUpserted(card)))
        card.title = "v-old"
        model.apply(EventEnvelope(rev: 6, event: .taskUpserted(card)))          // stale ≤ 10 → drop
        #expect(model.tasks.first { $0.id == card.id }?.title == "v-new")
        let other = makeCard("other")
        model.apply(EventEnvelope(rev: 8, event: .taskUpserted(other)))         // lower rev, DIFFERENT card → apply
        #expect(model.tasks.contains { $0.id == other.id })
    }

    @Test func test_revGapTriggersResync() throws {
        let model = TestModel.make()
        let card = makeCard("c")
        model.apply(EventEnvelope(rev: 5, event: .taskUpserted(card)))
        model.adoptSnapshotRev(20)                                              // reconnect → snapshot@20
        model.apply(EventEnvelope(rev: 12, event: .taskUpserted(card)))         // pre-outage stale ≤ 20 → drop
        #expect(model.tasks.first { $0.id == card.id }?.title == "c")
        var newer = card; newer.title = "c2"
        model.apply(EventEnvelope(rev: 25, event: .taskUpserted(newer)))        // post-snapshot → apply
        #expect(model.tasks.first { $0.id == card.id }?.title == "c2")
    }

    // GUARD (sparse-rev contract): a bare forward gap on the LIVE stream applies through — no resync.
    // Structural: apply(_:) has no fetch branch, so this documents intent (it cannot fail on the impl).
    @Test func test_forwardGapDoesNotResync() throws {
        let model = TestModel.make()
        let card = makeCard("c")
        model.apply(EventEnvelope(rev: 5, event: .taskUpserted(card)))
        model.apply(EventEnvelope(rev: 99, event: .taskUpserted(card)))         // huge sparse gap, not loss
        #expect(model.tasks.contains { $0.id == card.id })                      // applied through, no fetch
    }
}
```

Add the barrier test to `ControlClientTests.swift` (proves `subscribeWithRev` does not auto-issue, so the caller controls subscribe-before-snapshot ordering):

```swift
// subscribeWithRev does not auto-issue; the awaited subscribe completes (ack fed) BEFORE any snapshot.
@Test func test_subscribeAwaitedBeforeSnapshot() async throws {
    let stub = StubTransport()
    let c = ControlClient(transport: { stub }, source: .app, callTimeout: .seconds(5), pingInterval: .seconds(3600))
    try c.connect()
    _ = c.subscribeWithRev()
    #expect(!stub.writes.contains("subscribe"))                   // NOT auto-issued — caller owns the barrier
    stub.answerSubscribe = true                                   // arrange the stub to ack subscribe
    try await c.call("subscribe")                                 // AWAITED — returns only after the ack
    #expect(stub.writes.contains("subscribe"))
    #expect(!stub.writes.contains("boardSnapshot"))               // snapshot issued only after, by the caller
    c.close()
}

// B2 failure-open guard: if the reconnect re-subscribe FAILS, onReconnect must NOT fire (no snapshot
// while unsubscribed). The critical invariant is "onReconnect not fired" — state oscillates during the
// retry loop (openOnce briefly sets .live before the detached subscribe fails), so we do NOT assert on it.
@Test func test_subscribeFailureDoesNotFireOnReconnect() async throws {
    let stub = StubTransport(); stub.answerVersion = true; stub.answerSubscribe = false; stub.reopenOnConnect = true
    let c = ControlClient(transport: { stub }, source: .app, callTimeout: .milliseconds(200), pingInterval: .seconds(3600))
    let reconnected = _Locked(false)
    c.onReconnect = { reconnected.value = true }
    try c.connect()
    _ = c.subscribeWithRev()                                      // sets `subscribed` so the reconnect re-subscribes
    (c as ControlClient).forceReconnect()                         // drop → runLoop reconnects → subscribe deadline-fails
    try? await _Concurrency.Task.sleep(for: .seconds(1))          // several failed subscribe attempts
    #expect(reconnected.value == false)                           // onReconnect NEVER fired → never snapshots unsubscribed
    c.close()
}

// The POSITIVE reconnect path (would have caught Opus NB-1): when subscribe IS answered on reconnect,
// onReconnect MUST fire — proving the ack is actually read (reader live after break), not deadlocked.
@Test func test_subscribeSuccessFiresOnReconnect() async throws {
    let stub = StubTransport(); stub.answerVersion = true; stub.answerSubscribe = true; stub.reopenOnConnect = true
    let c = ControlClient(transport: { stub }, source: .app, callTimeout: .seconds(2), pingInterval: .seconds(3600))
    let reconnected = _Locked(false)
    c.onReconnect = { reconnected.value = true }
    try c.connect()
    _ = c.subscribeWithRev()                                      // subscribed = true
    (c as ControlClient).forceReconnect()                         // drop → runLoop reconnects, subscribe acked
    var fired = false
    for _ in 0..<40 { if reconnected.value { fired = true; break }; try? await Task.sleep(for: .milliseconds(50)) }
    #expect(fired)                                               // fired well under the 2s callTimeout → ack WAS read
    c.close()
}
```

> `StubTransport` gains: `answerVersion`/`answerSubscribe` flags (default: answer `version`, do NOT answer `subscribe` — the failure test relies on the default; the success test opts in), `reopenOnConnect` (let `open()` reset `closed` so the runLoop can reconnect), and `writes` recording. `_Locked`/`_Atomic` = any tiny thread-safe box.

- [ ] **Step 2: Run to verify failure** — `swift test --no-parallel --filter "BoardStoreTests|test_subscribeAwaitedBeforeSnapshot"` → FAIL to compile (`apply(EventEnvelope)`, `adoptSnapshotRev`, `subscribeWithRev` missing).

- [ ] **Step 3: `subscribeWithRev` (non-breaking) + awaited reconnect re-subscribe**

In `ControlClient.swift`, keep the existing `subscribe()`/`eventContinuation` untouched. Add a **second** continuation for envelopes and a `subscribeWithRev()` that sets it up but does **not** auto-issue the RPC:

```swift
private var envelopeContinuation: AsyncStream<EventEnvelope>.Continuation?

/// Rev-carrying subscription for BoardStore's gate. Unlike `subscribe()`, this does NOT auto-issue
/// the `subscribe` RPC — the caller awaits `call("subscribe")` as a registration barrier BEFORE
/// `boardSnapshot`, closing the subscribe→snapshot loss window (the daemon dispatches requests
/// concurrently, so registration must be acknowledged before snapshotting).
public func subscribeWithRev() -> AsyncStream<EventEnvelope> {
    AsyncStream { cont in
        stateLock.withLock {
            self.envelopeContinuation?.finish()
            self.envelopeContinuation = cont
            self.subscribed = true                      // so runLoop re-subscribes on reconnect
        }
    }
}
```

In `readUntilEOF` (`:322-327`), yield to whichever continuation is set (both nil-safe):

```swift
if msg.method == "event" {
    if let env = try? msg.params?.decode(EventEnvelope.self) {
        // Take both continuations under ONE lock scope (N-c), yield after releasing.
        let (envCont, evtCont) = stateLock.withLock { (envelopeContinuation, eventContinuation) }
        envCont?.yield(env)          // BoardStore (rev-gated)
        evtCont?.yield(env.event)    // existing consumers (bare Event)
    }
}
```

In the reconnect path (`runLoop`, `:301-310`), **success-gate** the barrier: only fire `onReconnect` (which triggers `refresh → boardSnapshot`) if the re-subscribe **succeeded**. On subscribe failure, do **not** snapshot — force a reconnect (Codex R2 §2: the barrier was "failure-open").

> ⚠️ **Do NOT block the runLoop thread on the ack (Opus NB-1).** `readUntilEOF` — the *sole* reader that delivers the subscribe ack — runs at the **top of the outer loop, only after `break`**. If the reconnect loop parks on a semaphore waiting for `call("subscribe")` *before* `break`, nobody reads the ack, so the call resolves only via its `callTimeout` deadline → a **healthy** subscribe false-fails after 15 s → infinite reconnect loop (and it hangs `TransportReconnectTests`). So: `break` first (reader starts), and success-gate `onReconnect` **inside** the detached Task.

```swift
do {
    try openOnce()
    attempt = 0
    if stateLock.withLock({ subscribed }) {
        _Concurrency.Task { [weak self] in
            do { _ = try await self?.call("subscribe"); self?.onReconnect?() }  // registered → refresh
            catch { self?.forceReconnect() }                                   // NOT registered → drop → reconnect
        }
    } else {
        onReconnect?()
    }
    break                       // reader runs now, delivers the subscribe ack that resolves the call above
} catch { setState(.retrying); continue }
```

Add `forceReconnect()` for the initial-connect barrier-failure path (and the reconnect failure branch above):

```swift
/// Shut the current transport so the reader EOFs and the runLoop reconnects (with the success-gated
/// re-subscribe barrier). Used when the initial subscribe barrier fails — we must NOT snapshot unsubscribed.
public func forceReconnect() { (writeLock.withLock { transport })?.shutdown() }
```

Also `close()` must finish `envelopeContinuation` alongside `eventContinuation`.

- [ ] **Step 4: Per-card gate + baseline + barrier in BoardStore**

Add trackers near the per-card state (~`:90`):

```swift
/// Highest board `rev` applied per card — the per-card staleness gate. Board-global tracking is
/// unsound: rev is sparse AND non-monotonic in wire order (spawn's deferred emit), so a legit lower-
/// rev event for card B can arrive after a higher-rev event for card A. (PR1 sparse-rev decision.)
private var appliedRev: [UUID: Int] = [:]
/// The rev of the last adopted boardSnapshot — the resync floor. Reconnect (the only loss channel,
/// given the subscribe barrier) adopts a fresh snapshot rev here.
private var baselineRev: Int = 0
```

Add the rev-gated entry + snapshot adoption:

```swift
/// The rev-gated ingestion entry the live envelope stream calls. Task-state events apply iff they
/// beat this card's applied rev AND the snapshot floor; activity/owner/shells are not gated.
func apply(_ env: EventEnvelope) {
    switch env.event {
    case .taskUpserted(let t):
        guard env.rev > max(baselineRev, appliedRev[t.id] ?? Int.min) else { return }
        appliedRev[t.id] = env.rev; apply(env.event)
    case .taskRemoved(let id):
        guard env.rev > max(baselineRev, appliedRev[id] ?? Int.min) else { return }
        appliedRev[id] = env.rev; apply(env.event)
    case .activity, .agentTerminalOwner, .shellsChanged:
        apply(env.event)
    }
}

/// Resync floor adoption — `refresh()` calls this after a fresh boardSnapshot. Seeds the gate from
/// the snapshot's rev so pre-outage in-flight events can't clobber it.
func adoptSnapshotRev(_ rev: Int) { baselineRev = rev; appliedRev.removeAll() }
```

Change the stream consumer (`:452-463`) to use `subscribeWithRev` + the awaited barrier, **preserving** the `connGeneration == gen` guard + `handleStreamEnded(gen:)`:

```swift
if !streamStarted {
    streamStarted = true
    let stream = client.subscribeWithRev()
    _Concurrency.Task { [weak self] in
        for await env in stream {
            guard let self, self.connGeneration == gen else { break }
            self.apply(env)                                  // rev-gated
        }
        self?.handleStreamEnded(gen: gen)
    }
    // Success-gated BARRIER: registration must be acked before the snapshot. On failure, do NOT
    // snapshot unsubscribed — force a reconnect (the reconnect path re-runs the gated barrier + refresh).
    do { try await client.call("subscribe") }
    catch { client.forceReconnect(); return }
}
await refresh()
```

In `refresh()` (`:479`, the `boardSnapshot` branch), adopt the rev **before** the wholesale set:

```swift
if let snap = try? await client.boardSnapshot() {
    adoptSnapshotRev(snap.rev)
    tasks = snap.tasks
    // …unchanged…
    return
}
```

> Leave `apply(_ event: Event)` (`:587`) as-is (ungated) — the optimistic local apply in `spawn` (`:685`) and existing tests use it. Only the envelope stream + `apply(_ env:)` are rev-aware.

- [ ] **Step 5: Run to verify pass** — `swift test --no-parallel --filter "BoardStoreTests|ControlClientTests"` → PASS. Then `swift test --no-parallel` → green (existing `subscribe()` consumers untouched → no test churn).

- [ ] **Step 6: Commit** — `git commit -am "feat(sync): per-card rev gate + subscribe barrier + reconnect resync in BoardStore"`

---

## Task 6.4: Fold deviations into the vault

**Files:** `notes/designs/lifecycle-convergence/03-implementation.md` + `04-tests.md` ("Decisions made").

- [ ] **Step 1: Record PR6a deviations** (one row each):
1. **Per-card `appliedRev` gate** replaces the board-global `lastSeenRev` — sound under sparse + non-monotonic wire order; a global cursor drops cross-card-reordered updates. Added `test_forwardGapDoesNotResync` guard.
2. **Resync is reconnect-driven** (adopt `boardSnapshot.rev`), never forward-gap-driven.
3. **Subscribe→snapshot registration barrier** — the daemon dispatches per-connection requests concurrently (`ControlServer.swift:72`), so `subscribeWithRev()` does not auto-issue the RPC and BoardStore awaits `call("subscribe")` before `boardSnapshot`; the reconnect path awaits re-subscribe before `onReconnect`. This closes the only in-live-connection loss window — the precondition that makes reconnect-only resync sound.
4. **Non-breaking `subscribeWithRev()`** (second continuation) instead of changing `subscribe()`'s element type — avoids churning ~18 `Event`-matching test files and merge risk.
5. **Atomic `TaskStore.createIfAbsent`** is the idempotency boundary (a check-then-act across actor `await`s is not atomic); the service fast-paths `store.get` before side effects and returns the winner's card on a lost race. Added `test_concurrentSameIdSpawnCreatesOne`.
6. **Race-free deadline** via a `PendingCall{cont,timer,resolved}` record resolved through one `resolve(id:)` funnel (continuation installed before the timer; `resolve`/`close`/`failPending` never call the resolver while holding the non-recursive `stateLock`). **Bounded `probeVersion`** (watchdog) so first-connect can't hang. Added `test_callTimesOutNearZero` + `test_firstConnectProbeTimesOut`.

- [ ] **Step 2: Commit** — `git commit -am "docs(vault): fold PR6a as-built deviations (per-card rev gate, subscribe barrier, atomic dedup, race-free deadline)"`

---

## Self-review checklist

1. **Coverage:** 6.1 → `test_spawnWithClientIdIsIdempotent`, `test_batchSpawnRetryIsIdempotent`, `test_concurrentSameIdSpawnCreatesOne`; 6.2 → `test_callTimesOut`, `test_callTimesOutNearZero`, `test_pingDetectsDeadTunnel`, `test_firstConnectProbeTimesOut`; 6.3 → `test_staleEventDropped`, `test_revGapTriggersResync`, `test_forwardGapDoesNotResync`, `test_subscribeAwaitedBeforeSnapshot`. ✔
2. **Sparse-rev rule:** per-card gate; reconnect-only resync; forward gap never resyncs; subscribe barrier closes the live-loss window. ✔
3. **No auto-retrier.** ✔  4. **In-scope** (no PR5/PR6b sites; `subscribe()` + `apply(_ event:)` unchanged). ✔
5. **Type consistency:** `createIfAbsent`, `PendingCall`, `resolve`, `subscribeWithRev`, `apply(_ env:)`, `adoptSnapshotRev`, `appliedRev`, `baselineRev`, `SpawnInput.id` used identically. ✔  6. **Agent-agnostic.** ✔

## Review round 1 — resolutions (both reviewers)

| Finding | Severity | Resolution |
|---|---|---|
| Spawn idempotency TOCTOU (actor reentrancy across `get`→`create`; `create` appends unconditionally) | BLOCK (Opus B1 = Codex B2) | Atomic `TaskStore.createIfAbsent` (no `await` between check/append) + `test_concurrentSameIdSpawnCreatesOne`. |
| Subscribe→snapshot registration gap = a live-connection loss channel (daemon dispatches concurrently; ring replays activity only) | BLOCK (Codex B1) | `subscribeWithRev()` doesn't auto-issue; BoardStore awaits `call("subscribe")` before `boardSnapshot`; reconnect awaits re-subscribe before `onReconnect`. Makes "reconnect is the only loss channel" TRUE. (Resolves the Opus/Codex disagreement in Codex's favour — verified `ControlServer.swift:72`.) |
| Deadline timer armed before pending insert → possible leak; double-resume risk | BLOCK (Codex B3) | `PendingCall` record; continuation installed first, timer attached-if-pending; single `resolve` funnel. `test_callTimesOutNearZero`. |
| `takePending`/resolve called while holding non-recursive `stateLock` in `close`/`failPending` → deadlock | BLOCK (Opus B3 = Codex note) | `resolve` takes the record under the lock, resumes outside it; `close`/`failPending` snapshot ids then resolve outside. |
| Changing `subscribe()` → `EventEnvelope` breaks ~18 test files | BLOCK (Opus B2, worse than stated) | Non-breaking `subscribeWithRev()`; `subscribe()` unchanged. |
| `probeVersion` unbounded → first-connect hang; ping never starts | MAJOR (Codex 4) | Watchdog-bounded probe. `test_firstConnectProbeTimesOut`. |
| Stream-consumer edit dropped the `connGeneration`/`handleStreamEnded` guard | NIT (Opus N1) | Preserved in the Step 4 snippet. |
| `Config.default` doesn't exist | NIT (Opus N2) | Literal `.seconds(15)`/`.seconds(20)` defaults. |
| Sub-second `pingInterval` truncated by `components.seconds` | NIT (Opus N3) | Async ping loop with `Task.sleep(for: pingInterval)`. |
| `test_forwardGapDoesNotResync` client-spy has no seam | NIT (Opus N4) | Applied-through assertion; labelled a structural guard. |

## Review round 2 — resolutions

Round 2 (Opus resumed with round-1 context + fresh GPT-5.5 codex card) **confirmed all five round-1 resolutions correct** (the atomic dedup, the subscribe→snapshot barrier — Opus explicitly conceded Codex was right and it was wrong in round 1, verified against `ControlServer.swift:72`/`:117-126` — the race-free `PendingCall`/`resolve` funnel, the bounded probe, and N1–N4). One new issue + two nits, all folded into Revision 3 above:

| Finding | Severity | Resolution (Revision 3) |
|---|---|---|
| `probeVersion` bound by `callTimeout` → a near-zero `callTimeout` (the `test_callTimesOutNearZero` construction, or an aggressive product setting) racily fails `connect()`'s probe | MAJOR (Opus NEW-1) | Dedicated `probeTimeout: Duration = .seconds(15)` param; `probeVersion`'s watchdog uses it, decoupled from `callTimeout`. `test_firstConnectProbeTimesOut` passes `probeTimeout: .milliseconds(200)`; `test_callTimesOutNearZero` keeps the default probe. |
| Sibling-multiplicity warning runs before dedup → a concurrent loser emits a spurious "second live card" activity | NIT (Opus N-a) | Gate the warning on `wasCreated`. |
| `readUntilEOF` takes `stateLock` twice per event (one per continuation) | NIT (Opus N-c) | Read both continuations under one lock scope; yield after release. |

Opus N-b (a vanishingly-rare probe-watchdog spurious drop on reconnect) is self-healing and shrunk further by the NEW-1 fix; accepted.

## Review round 3 — resolutions (codex R2)

Codex R2 **confirmed** the per-card gate, the `subscribeWithRev` non-breaking shape, and the bounded probe are sound, and raised the following (all folded into Revision 4):

| Finding | Severity | Resolution |
|---|---|---|
| Idempotency doesn't cover the real manual-retry path — a fresh id is minted per user action / CLI run / MCP call, so a blind re-issue carries a *new* id and dedup can't fire | BLOCK (Codex R2 §1) | PR6a delivers the wire mechanism **+ caller-suppliable ids** (CLI `--id`; MCP preserves a supplied `id`, injecting only when absent) so agents/scripts reuse their id on retry; added `test_spawnParamRetryIsIdempotent` (wire path). **Narrowed the Global Constraint**: retry-safety needs a retained id; **app-side reuse-on-retry is PR6b**. ⚠️ **Cross-PR dependency to surface to the orchestrator:** PR6b's Task 6.4 currently scopes an `isSpawning` in-flight guard (blocks a concurrent double-click) — the *reuse-the-same-id-on-retry-after-a-failure* refinement is a stronger property that PR6b must explicitly own, or it falls through the cracks. Opus confirmed this scoping is within my authority (no Allen sign-off needed); flag it in the merge-request. |
| Subscribe barrier was **failure-open**: `try? await call("subscribe")` swallowed failure, then `refresh`/`onReconnect` ran anyway → snapshot while unsubscribed → loss | BLOCK (Codex R2 §2) | **Success-gate** both paths: reconnect awaits the ack and only `onReconnect`s if it succeeded (else `closeTransport` + retry); BoardStore's initial barrier `forceReconnect()`s and skips the snapshot on failure. Added `test_subscribeFailureDoesNotFireOnReconnect`. |
| User-visible side effects (the sibling "second live card" warning) run before dedup → a concurrent loser emits spurious activity | BLOCK (Codex R2 §3, = Opus N-a) | Gate the warning on `wasCreated` / move past `createIfAbsent`; `test_concurrentSameIdSpawnCreatesOne` now asserts **no** duplicate warning activity. |
| A timed-out call may still have been written/executed → a non-idempotent `send` could be delivered despite a local timeout | MAJOR (Codex R2 §4) | **Documented** as deliberate: a deadline bounds *waiting*, not *execution* (standard RPC semantics); coherent with no-`send`-dedup (re-send = user intent). No racy pre-write check. |
| `test_subscribeAwaitedBeforeSnapshot` didn't feed an ack; `test_concurrentSameIdSpawnCreatesOne` only counted cards | MAJOR (Codex R2 §5) | Both strengthened (feed the ack + assert snapshot-after; assert no-dup-activity). |

## Review round 4 — resolution (Opus)

Round 4 (Opus, resumed) **confirmed** the caller-suppliable ids + narrowed claim (R3.2, and that the scope boundary is within my authority — no Allen sign-off needed), the wait-not-execution deadline semantics (R3.3), and the sibling-warning gating intent (R3.4). It found **one new blocker my round-3 fix introduced**:

| Finding | Severity | Resolution (Revision 5) |
|---|---|---|
| The semaphore-bridged reconnect barrier (`sem.wait()`) parks the **sole reader thread** before `break`, but `readUntilEOF` (which delivers the subscribe ack) only runs *after* `break`. So a **healthy** subscribe ack is never read → the call resolves only via its `callTimeout` deadline → false-fails → **infinite reconnect loop**; also hangs `TransportReconnectTests`. The failure-only test masked it. | BLOCK (Opus NB-1) | **Break first, success-gate `onReconnect` inside the detached Task** (reader is live when the ack arrives): `Task { do { try await call("subscribe"); onReconnect() } catch { forceReconnect() } }; break`. Still success-gated (onReconnect only on ack), deadlock-free. Added **`test_subscribeSuccessFiresOnReconnect`** (positive path). Failure test keeps only the `onReconnect`-not-fired invariant (state oscillates, so not asserted). |
| Sibling warning: if *moved past* `createIfAbsent`, the scan self-matches the winner's own new card | NIT (Opus) | Capture the sibling boolean **before** `createIfAbsent`, emit **after** only if `wasCreated`. |
| App reuse-on-retry could fall through the cracks between PR6a/PR6b | NIT (Opus) | Cross-PR dependency flagged in the round-3 table + merge-request. |

**Codex R3 independently corroborated NB-1** (the reconnect deadlock) — same root cause, same fix direction ("ensure a reader is active while awaiting the ack" = break-first) — already resolved above; it asked for the positive reconnect test, which Revision 5 adds. Its one new non-blocking item: **the MCP `spawn`/`batch-spawn` `CommandCatalog` schemas lacked `id`**, so `tools/list` wouldn't advertise the retry field → added optional `id` to both schemas (Task 6.1 Step 6). Codex R3 explicitly accepted the caller-suppliable-id scope, the PR6b deferral, the deadline semantics, and confirmed no other pre-create visible emit exists. **With NB-1 resolved and the schema field added, both reviewers' blocking items are cleared.**

## Execution handoff

Phase B re-reviews **Revision 2** (both reviewers) — verify the atomic dedup, the subscribe barrier, and the race-free deadline. After both are clean, Phase C implements via **superpowers:subagent-driven-development** at high effort, strict TDD, one task per subagent with review between tasks.
