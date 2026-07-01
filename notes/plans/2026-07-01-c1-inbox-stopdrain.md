# C1 — Inbox store + F3 Claude Stop-drain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan
> task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a durable per-card **Inbox** (F3), route `send` through it, and repurpose the **existing Claude
Stop hook** to *also* drain the inbox into the agent (`decision:block`+`reason`) — while preserving the hook's
current `_report --event notify` → `waiting` report.

**Architecture:** A new `Inbox` actor-over-JSON (sibling to `TaskStore`) holds durable messages. `OrchestraService`
gains an `inbox` and a `drainForStop(cardId)` method that applies the inject **loop-guard cap** and composes a
**10k-bounded** payload via a pure `StopDrain` helper. A new daemon `drain` RPC (ControlServer) lets the Stop
hook fetch the payload; `ReportHelper` (the `_report` process = the Claude hooksPush transport) detects the Stop
event (`hook_event_name == "Stop"`) and prints the `decision:block` JSON to stdout — additive to the unchanged
notify/waiting report. `send` enqueues to the inbox instead of typing into tmux.

**Tech Stack:** Swift 6, swift-testing (`@Suite`/`@Test`/`#expect`), actors, `OrchestraJSON` codec, UDS JSON-RPC.

## Global Constraints

- **Base = A2 (current `main`).** C1 bases on A2 specifically so both touch the Stop-hook path without a 3-way
  `HooksRenderer` conflict. As-built, C1 leaves `HooksRenderer`/`claude-hooks.json` **unchanged** (the drain
  rides the existing `_report --event notify` Stop hook), so there is in fact no `HooksRenderer` conflict.
- **Preserve Claude telemetry byte-identical.** `ReportTests`/`ParseTests`/`AdapterTests`/`RecoveryTests` must
  stay green unchanged. The notify→`waiting` report path (`ClaudeCodeAdapter.parse` `case "notify"`,
  `OrchestraService.report`) is **not modified**.
- **Offline + no live agent.** No network in build/test; unit tests never spawn real `claude` (`USE_REAL_CLAUDE`
  stays unset). Swift build/test needs an **unsandboxed** shell (sandbox-exec error → re-run with sandbox off).
- **Payload contract:** the injected Stop payload is capped at **10 000 characters** (design §8: "`additionalContext`
  (10k)"). Realized concretely as the Stop hook's `decision:block` + **`reason`** field (the documented Claude
  Stop-hook continuation channel; `reason` is fed to the model on block).
- **Loop guard:** both agents' `stop_hook_active` is *informational* (neither auto-enforces) → Orchestra caps
  **consecutive auto-injects** per card in the daemon; the cap resets on a genuine user prompt (UserPromptSubmit).
- **`send` routes through the inbox** (design §8.3 UC7). No keystroke delivery in C1; idle-card wake is C2.

## Real-seam facts (grounding — read before coding)

- `TaskStore` (`Sources/OrchestraCore/TaskStore.swift`) is the actor-over-JSON pattern to mirror: `init(path:)`,
  lazy `load()`, atomic `persist()` (temp + `replaceItemAt`), malformed → `.bak` + `[]`.
- `Config` (`Config.swift`) derives all paths from `dataDir` (`~/Library/Application Support/Orchestra`):
  `tasksPath`, `trustLedgerPath`, etc. Add `inboxPath` here.
- `OrchestraService` (actor) init (`OrchestraService.swift:27`) takes injectable `store`/`trust`/etc. with
  defaults. Add an injectable `inbox`. `send` is at `OrchestraService.swift:203` (currently `sessions.sendKeys`).
  `report` lives in `OrchestraService+Report.swift` (do not change its logic; only add an inject-count reset on
  a genuine prompt).
- `ClaudeCodeAdapter.parse` (`Agents/ClaudeCodeAdapter.swift:48`) maps `case "notify"` →
  `StatusReport(desc: message, status: .waiting)`. **Unchanged.**
- The Stop hook today (`Control/HooksRenderer.swift:38` + bundled `Resources/claude-hooks.json`) runs
  `__ORCHESTRA_BIN__ _report --event notify`. **Unchanged.**
- `ReportHelper.run` (`Sources/orchestra/ReportHelper.swift`) is the `_report` hook process: reads stdin JSON,
  calls `ClaudeCodeAdapter().parse(.hooksPush(kind:payload:))`, `boundedSend`s the report to the daemon over
  `$ORCHESTRA_SOCK`, keyed by `$ORCHESTRA_TASK_ID`. Only `statusline` prints to stdout today. It imports
  `OrchestraCore`.
- `ControlServer.dispatch` (`Control/ControlServer.swift:104`) has special RPC cases (`report`, `getConfig`, …)
  before falling through to `CommandRegistry`. `report` resolves the ref via `service.resolveRef`. Add a `drain`
  case the same way. The drain is **Orchestra-internal plumbing — NOT a `Command`** (not user-facing), so it does
  not touch `CommandRegistry` and does not affect the registry↔MCP parity test.
- `StatusReport(... promptText:)` puts `promptText` in the `EventReport` half (`Model.swift:456`); the parse
  `case "prompt"` yields `StatusReport(status:.running, promptText:)`. `report` reads `patch.event?.promptText`.
- Tests wire the service via `TestEnv.make()` (`Tests/OrchestraCoreTests/Stubs.swift:163`) — every store is under
  a temp dir. Add the inbox there. `StubSessions.sendKeys` is a no-op that records nothing.

## File Structure

- **Create** `Sources/OrchestraCore/Inbox.swift` — `InboxMessage` struct + `Inbox` actor (durable queue).
- **Create** `Sources/OrchestraCore/Agents/StopDrain.swift` — pure compose/cap helper + the block-JSON builder.
  (Kept tiny + pure; not in an actor so it's trivially unit-testable and reusable by the hook process.)
- **Modify** `Sources/OrchestraCore/Config.swift` — add `inboxPath`.
- **Modify** `Sources/OrchestraCore/OrchestraService.swift` — add `inbox` property + init param; `drainForStop`;
  inject-count state + reset; reroute `send` through the inbox.
- **Modify** `Sources/OrchestraCore/OrchestraService+Report.swift` — reset inject-count on a genuine prompt.
- **Modify** `Sources/OrchestraCore/Control/ControlServer.swift` — add the `drain` RPC case.
- **Modify** `Sources/orchestra/ReportHelper.swift` — Stop-event detection + drain call + print block JSON;
  add a `boundedCall` returning the response.
- **Modify** `Tests/OrchestraCoreTests/Stubs.swift` — inject a temp-path `Inbox` in `TestEnv.make()`.
- **Create** `Tests/OrchestraCoreTests/InboxTests.swift` — Inbox store + StopDrain + drainForStop + send routing.
- **Modify** `Tests/OrchestraCoreTests/ControlRoundTripTests.swift` — add a `drain` RPC round-trip test.

---

### Task 1: `InboxMessage` + `Inbox` actor (durable store)

**Files:**
- Create: `Sources/OrchestraCore/Inbox.swift`
- Modify: `Sources/OrchestraCore/Config.swift` (add `inboxPath`)
- Test: `Tests/OrchestraCoreTests/InboxTests.swift`

**Interfaces:**
- Produces:
  - `struct InboxMessage: Codable, Sendable, Equatable { let id: UUID; let cardId: UUID; let text: String; let createdAt: Date }`
  - `actor Inbox { init(path: String = Config.inboxPath); func enqueue(_ cardId: UUID, _ text: String) throws; func peek(_ cardId: UUID) -> [InboxMessage]; func drain(_ cardId: UUID) throws -> [InboxMessage]; @discardableResult func load() -> [InboxMessage] }`
  - `Config.inboxPath: String` → `"\(dataDir)/inbox.json"`
- Ordering contract: a flat, append-ordered `[InboxMessage]`; `peek`/`drain` filter by `cardId` **preserving
  append order** (FIFO per card). `drain` removes exactly the drained ids and persists.

- [ ] **Step 1: Add `inboxPath` to Config**

In `Config.swift`, next to `trustLedgerPath` (~line 68):

```swift
    public static var inboxPath: String { "\(dataDir)/inbox.json" }
```

- [ ] **Step 2: Write the failing test (order + peek non-destructive + drain clears)**

Create `Tests/OrchestraCoreTests/InboxTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("C1 · Inbox durable store")
struct InboxStoreTests {
    static func tmp() -> String { NSTemporaryDirectory() + "inbox-\(UUID().uuidString).json" }

    @Test("enqueue → drain preserves FIFO order, per card")
    func enqueueDrainOrder() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path)
        let a = UUID(); let b = UUID()
        try await inbox.enqueue(a, "a1")
        try await inbox.enqueue(b, "b1")
        try await inbox.enqueue(a, "a2")

        #expect(await inbox.peek(a).map(\.text) == ["a1", "a2"])   // peek is non-destructive
        #expect(await inbox.peek(a).map(\.text) == ["a1", "a2"])
        let drainedA = try await inbox.drain(a)
        #expect(drainedA.map(\.text) == ["a1", "a2"])
        #expect(await inbox.peek(a).isEmpty)                        // drain cleared a
        #expect(await inbox.peek(b).map(\.text) == ["b1"])          // b untouched
    }
}
```

- [ ] **Step 3: Run it and watch it fail (no `Inbox` type)**

Run: `./scripts/test.sh --filter InboxStoreTests` (unsandboxed)
Expected: FAIL to build — `cannot find 'Inbox' in scope`.

- [ ] **Step 4: Implement `Inbox`**

Create `Sources/OrchestraCore/Inbox.swift`:

```swift
import Foundation

/// One durable inbox message (F3). Conclusions/sends ride the inbox; artifacts ride git.
public struct InboxMessage: Codable, Sendable, Equatable {
    public let id: UUID
    public let cardId: UUID
    public let text: String
    public let createdAt: Date
    public init(id: UUID = UUID(), cardId: UUID, text: String, createdAt: Date = Date()) {
        self.id = id; self.cardId = cardId; self.text = text; self.createdAt = createdAt
    }
}

/// Durable per-card message queue (F3), sibling to `TaskStore`: actor-over-JSON, atomic save, malformed
/// → `.bak` + `[]`. A single append-ordered array gives FIFO-per-card via a stable filter, and survives
/// a daemon restart (messages persist until drained).
public actor Inbox {
    private let path: String
    private var messages: [InboxMessage] = []
    private var loaded = false

    public init(path: String = Config.inboxPath) { self.path = path }

    @discardableResult
    public func load() -> [InboxMessage] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { messages = []; loaded = true; return messages }
        do {
            messages = try OrchestraJSON.decoder.decode([InboxMessage].self, from: Data(contentsOf: url))
        } catch {
            let bak = path + ".bak"
            try? FileManager.default.removeItem(atPath: bak)
            try? FileManager.default.moveItem(atPath: path, toPath: bak)
            messages = []
        }
        loaded = true
        return messages
    }

    private func ensureLoaded() { if !loaded { _ = load() } }

    /// Pending messages for a card, in append (FIFO) order. Non-destructive.
    public func peek(_ cardId: UUID) -> [InboxMessage] {
        ensureLoaded()
        return messages.filter { $0.cardId == cardId }
    }

    public func enqueue(_ cardId: UUID, _ text: String) throws {
        ensureLoaded()
        messages.append(InboxMessage(cardId: cardId, text: text))
        try persist()
    }

    /// Return + remove all pending messages for a card, in order.
    @discardableResult
    public func drain(_ cardId: UUID) throws -> [InboxMessage] {
        ensureLoaded()
        let pending = messages.filter { $0.cardId == cardId }
        guard !pending.isEmpty else { return [] }
        messages.removeAll { $0.cardId == cardId }
        try persist()
        return pending
    }

    private func persist() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try OrchestraJSON.pretty.encode(messages)
        let url = URL(fileURLWithPath: path)
        let tmp = URL(fileURLWithPath: path + ".tmp.\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
```

- [ ] **Step 5: Run the test — expect PASS**

Run: `./scripts/test.sh --filter InboxStoreTests`
Expected: PASS.

- [ ] **Step 6: Add the durability-across-restart test**

Append to `InboxStoreTests` in `InboxTests.swift`:

```swift
    @Test("messages survive a daemon restart (new Inbox instance, same path)")
    func durableAcrossRestart() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let card = UUID()
        do {
            let inbox = Inbox(path: path)
            try await inbox.enqueue(card, "before restart")
        }
        // Fresh instance simulates a daemon restart — must read the persisted queue.
        let reborn = Inbox(path: path)
        #expect(await reborn.peek(card).map(\.text) == ["before restart"])
        #expect(try await reborn.drain(card).map(\.text) == ["before restart"])
    }
```

- [ ] **Step 7: Run — expect PASS**

Run: `./scripts/test.sh --filter InboxStoreTests`
Expected: PASS (both tests).

- [ ] **Step 8: Commit**

```bash
git add Sources/OrchestraCore/Inbox.swift Sources/OrchestraCore/Config.swift Tests/OrchestraCoreTests/InboxTests.swift
git commit -m "feat(inbox): durable per-card Inbox store (F3) with FIFO + restart durability"
```

---

### Task 2: `StopDrain` — 10k-bounded payload compose + block-JSON builder

**Files:**
- Create: `Sources/OrchestraCore/Agents/StopDrain.swift`
- Test: `Tests/OrchestraCoreTests/InboxTests.swift` (new suite)

**Interfaces:**
- Produces:
  - `enum StopDrain { static let maxPayloadChars = 10_000; static func compose(_ messages: [InboxMessage]) -> String?; static func blockJSON(reason: String) -> String }`
  - `compose` joins message texts (newest-last, FIFO) with a blank-line separator, truncates the **result** to
    `maxPayloadChars` (keeping a leading `[…truncated]` marker so the bound is visible), returns `nil` for empty
    input.
  - `blockJSON(reason:)` builds the exact Stop-hook stdout: `{"decision":"block","reason":<json-escaped reason>}`.

- [ ] **Step 1: Write the failing tests**

Add to `InboxTests.swift`:

```swift
@Suite("C1 · StopDrain payload")
struct StopDrainTests {
    func msg(_ t: String) -> InboxMessage { InboxMessage(cardId: UUID(), text: t) }

    @Test("empty → nil")
    func emptyNil() { #expect(StopDrain.compose([]) == nil) }

    @Test("compose preserves order (FIFO)")
    func order() {
        let r = StopDrain.compose([msg("first"), msg("second")])
        let f = r?.range(of: "first"); let s = r?.range(of: "second")
        #expect(f != nil && s != nil && f!.lowerBound < s!.lowerBound)
    }

    @Test("payload is bounded to 10k chars")
    func bound() {
        let big = String(repeating: "x", count: 25_000)
        let r = StopDrain.compose([msg(big)])
        #expect(r != nil)
        #expect(r!.count <= StopDrain.maxPayloadChars)
    }

    @Test("blockJSON is valid decision:block with escaped reason")
    func blockJson() throws {
        let json = StopDrain.blockJSON(reason: "line1\n\"quoted\"")
        let parsed = try JSONValue.parse(Data(json.utf8))
        #expect(parsed["decision"]?.stringValue == "block")
        #expect(parsed["reason"]?.stringValue == "line1\n\"quoted\"")
    }
}
```

- [ ] **Step 2: Run — expect FAIL (no `StopDrain`)**

Run: `./scripts/test.sh --filter StopDrainTests`
Expected: FAIL — `cannot find 'StopDrain' in scope`.

- [ ] **Step 3: Implement `StopDrain`**

Create `Sources/OrchestraCore/Agents/StopDrain.swift`:

```swift
import Foundation

/// Composes drained `InboxMessage`s into the bounded payload the Claude Stop hook injects, and builds
/// the `decision:block` stdout that forces continuation. Pure + synchronous so it is trivially testable
/// and callable from the `_report` hook process.
///
/// Payload channel: the design (§8) names this "`additionalContext` (10k)". The concrete Claude Stop-hook
/// continuation field is `reason` on a `{"decision":"block"}` output — `reason` is fed to the model to tell
/// it how to proceed. We cap the payload at 10k characters either way.
public enum StopDrain {
    /// The `additionalContext`/`reason` payload bound the Claude Stop hook enforces.
    public static let maxPayloadChars = 10_000

    /// Join drained messages (FIFO) into one bounded payload; `nil` if there is nothing to inject.
    public static func compose(_ messages: [InboxMessage]) -> String? {
        guard !messages.isEmpty else { return nil }
        let joined = messages.map(\.text).joined(separator: "\n\n")
        guard joined.count > maxPayloadChars else { return joined }
        let marker = "[…truncated]\n"
        let keep = maxPayloadChars - marker.count
        return marker + String(joined.prefix(max(0, keep)))
    }

    /// The Stop-hook stdout that blocks the stop and hands `reason` to the model to continue.
    public static func blockJSON(reason: String) -> String {
        let obj = JSONValue.object(["decision": .string("block"), "reason": .string(reason)])
        return (try? obj.serialized()) ?? #"{"decision":"block","reason":""}"#
    }
}
```

> **Note for implementer:** verify the exact serialization call available on `JSONValue` (grep
> `Sources/OrchestraCore/JSONValue.swift` for a `serialized()` / `encoded()` / `String(describing:)` path, or
> use `String(data: try OrchestraJSON.encoder.encode(obj), encoding: .utf8)`). Use whatever the codebase
> already exposes; the test only requires that `blockJSON` round-trips back to `decision:block` + `reason`.

- [ ] **Step 4: Run — expect PASS**

Run: `./scripts/test.sh --filter StopDrainTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Agents/StopDrain.swift Tests/OrchestraCoreTests/InboxTests.swift
git commit -m "feat(inbox): StopDrain — 10k-bounded payload compose + decision:block builder"
```

---

### Task 3: Wire `Inbox` into `OrchestraService` + `drainForStop` loop-guard cap

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add `inbox`, `drainForStop`, inject-count state)
- Modify: `Sources/OrchestraCore/OrchestraService+Report.swift` (reset inject-count on a genuine prompt)
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` (`TestEnv.make` injects a temp-path `Inbox`)
- Test: `Tests/OrchestraCoreTests/InboxTests.swift`

**Interfaces:**
- Consumes: `Inbox` (Task 1), `StopDrain` (Task 2).
- Produces on `OrchestraService`:
  - `let inbox: Inbox` (init param `inbox: Inbox? = nil`, default `Inbox()`).
  - `public let maxConsecutiveInjects = 25` (readable so tests loop to it).
  - `public func drainForStop(_ cardId: UUID) async -> String?` — returns the composed, 10k-bounded payload to
    inject, or `nil` (nothing pending, or the loop guard tripped). Applies the cap; **does not** need a task in
    the store.
  - `func resetInjectCount(_ cardId: UUID)` — internal; clears the per-card consecutive-inject counter.
- Loop-guard semantics:
  - inbox empty → reset counter to 0, return `nil` (natural end of a drain sequence).
  - counter ≥ cap → return `nil` **without** draining and **without** resetting (leave messages durable; only a
    genuine user prompt resets — this breaks a runaway Stop→inject→Stop loop).
  - otherwise → drain, increment counter, return `StopDrain.compose(drained)`.

- [ ] **Step 1: Add the `inbox` property + init param**

In `OrchestraService.swift`, add the stored properties near `store`/`trust` (after line 16):

```swift
    /// Durable per-card message inbox (F3). Sibling to `store`; `send` enqueues, the Stop hook drains.
    let inbox: Inbox
    /// Consecutive auto-injects per card since the last genuine user prompt — the F3 loop guard.
    /// `stop_hook_active` is informational on both agents, so Orchestra enforces the cap itself.
    var injectCounts: [UUID: Int] = [:]
    /// Break a runaway Stop→inject→Stop loop after this many consecutive auto-injects (reset by a real prompt).
    public let maxConsecutiveInjects = 25
```

Add `inbox: Inbox? = nil` to the `init` signature (after `trust: TrustLedger? = nil`) and assign it:

```swift
                trust: TrustLedger? = nil,
                inbox: Inbox? = nil) {
```
```swift
        self.inbox = inbox ?? Inbox()
```

- [ ] **Step 2: Inject a temp-path Inbox in the test harness**

In `Tests/OrchestraCoreTests/Stubs.swift`, `TestEnv.make()` — build an inbox under `base` and pass it:

```swift
        let trust = TrustLedger(path: base + "/trust-ledger.json")
        let inbox = Inbox(path: base + "/inbox.json")
        let svc = OrchestraService(config: config, store: store,
                                   registry: AgentRegistry(adapters: [adapter]),
                                   worktrees: worktrees, sessions: sessions, trust: trust, inbox: inbox)
```

> Keep the returned tuple shape unchanged (tests don't yet need the inbox handle; they read it via
> `svc.drainForStop` / a fresh `Inbox(path:)`). If a test needs the inbox directly, it constructs
> `Inbox(path: env.base + "/inbox.json")`.

- [ ] **Step 3: Write the failing loop-guard test**

Add to `InboxTests.swift`:

```swift
@Suite("C1 · drainForStop loop guard")
struct DrainForStopTests {
    @Test("caps consecutive auto-injects and preserves the pending message when tripped")
    func injectCap() async throws {
        let env = TestEnv.make()
        let inbox = Inbox(path: env.base + "/inbox.json")
        let card = UUID()
        let cap = await env.svc.maxConsecutiveInjects

        // Each stop re-fills the inbox, so the counter climbs (never natural-resets).
        for i in 0..<cap {
            try await inbox.enqueue(card, "msg\(i)")
            let payload = await env.svc.drainForStop(card)
            #expect(payload != nil)                      // injected each time up to the cap
        }
        try await inbox.enqueue(card, "over the cap")
        let capped = await env.svc.drainForStop(card)
        #expect(capped == nil)                           // loop guard tripped → no inject
        #expect(await inbox.peek(card).map(\.text) == ["over the cap"])  // message NOT lost

        // A genuine user prompt resets the guard → injects again.
        await env.svc.resetInjectCount(card)
        let after = await env.svc.drainForStop(card)
        #expect(after?.contains("over the cap") == true)
    }

    @Test("empty inbox resets the counter and returns nil")
    func emptyResets() async throws {
        let env = TestEnv.make()
        let card = UUID()
        #expect(await env.svc.drainForStop(card) == nil)  // nothing pending
    }
}
```

- [ ] **Step 4: Run — expect FAIL (no `drainForStop`/`resetInjectCount`)**

Run: `./scripts/test.sh --filter DrainForStopTests`
Expected: FAIL — `value of type 'OrchestraService' has no member 'drainForStop'`.

- [ ] **Step 5: Implement `drainForStop` + `resetInjectCount`**

Add to `OrchestraService.swift` (e.g. just below `send`, in a `// MARK: - inbox / F3` section):

```swift
    // MARK: - inbox / F3 (Stop-drain)

    /// Drain the card's inbox into the payload the Stop hook injects (`decision:block` + `reason`), applying
    /// the consecutive-inject loop guard. Returns `nil` when there is nothing to inject OR the guard tripped
    /// (in which case pending messages are left durable for the next genuine turn / wake). Does not require a
    /// task in the store — it is pure inbox + counter, safe to call from the transport.
    public func drainForStop(_ cardId: UUID) async -> String? {
        let pending = await inbox.peek(cardId)
        if pending.isEmpty { injectCounts[cardId] = 0; return nil }   // natural end → reset
        let count = injectCounts[cardId] ?? 0
        if count >= maxConsecutiveInjects { return nil }              // loop guard tripped; keep counter high
        let drained = (try? await inbox.drain(cardId)) ?? []
        injectCounts[cardId] = count + 1
        return StopDrain.compose(drained)
    }

    /// Reset a card's consecutive-inject guard — called on a genuine user prompt (UserPromptSubmit).
    func resetInjectCount(_ cardId: UUID) { injectCounts[cardId] = 0 }
```

- [ ] **Step 6: Reset the guard on a genuine prompt**

In `OrchestraService+Report.swift`, inside the `if let prompt = ev.promptText, !prompt.isEmpty { … }` block
(~line 50), add the reset (a real user turn ends any auto-inject loop):

```swift
            if let prompt = ev.promptText, !prompt.isEmpty {
                resetInjectCount(id)
                if task.titleProvisional {
```

- [ ] **Step 7: Run — expect PASS**

Run: `./scripts/test.sh --filter DrainForStopTests`
Expected: PASS (2 tests).

- [ ] **Step 8: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/OrchestraService+Report.swift Tests/OrchestraCoreTests/Stubs.swift Tests/OrchestraCoreTests/InboxTests.swift
git commit -m "feat(inbox): OrchestraService.drainForStop with consecutive-inject loop guard"
```

---

### Task 4: Route `send` through the inbox

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (`send`)
- Modify: `Sources/OrchestraCore/Commands.swift` (`send` summary text only)
- Test: `Tests/OrchestraCoreTests/InboxTests.swift`

**Interfaces:**
- `send(_ id: UUID, _ message: String)` now **enqueues** to the inbox (durable, delivered via F3 Stop-drain)
  instead of typing into tmux. Still validates the card exists (`require`). No keystrokes (idle-card wake is C2).

- [ ] **Step 1: Write the failing test**

Add to `InboxTests.swift`:

```swift
@Suite("C1 · send routes through the inbox")
struct SendRoutingTests {
    @Test("send enqueues a durable message instead of typing into tmux")
    func sendEnqueues() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await env.svc.spawn(SpawnInput(prompt: "work", repo: repo, branch: "feat"))
        try await env.svc.send(task.id, "hello there")

        let inbox = Inbox(path: env.base + "/inbox.json")
        #expect(await inbox.peek(task.id).map(\.text) == ["hello there"])
    }
}
```

> Check the exact `SpawnInput` initializer label set used elsewhere in the tests (grep
> `SpawnInput(` in `Tests/`) and mirror it; the point is a spawned card whose id the send targets.

- [ ] **Step 2: Run — expect FAIL (message not in inbox; `send` still calls sendKeys)**

Run: `./scripts/test.sh --filter SendRoutingTests`
Expected: FAIL — `inbox.peek(...)` is empty.

- [ ] **Step 3: Reroute `send`**

In `OrchestraService.swift`, replace the body of `send` (line 203):

```swift
    /// Enqueue a message to the card's durable inbox (F3). Delivered at the agent's next turn-end via the
    /// Stop-hook drain — no keystrokes, receiver-transparent. (Waking an *idle* card to drain is F2 / C2.)
    public func send(_ id: UUID, _ message: String) async throws {
        let t = try await require(id)
        try await inbox.enqueue(t.id, message)
    }
```

Update the `send` command summary in `Commands.swift` (line 73):

```swift
            Command(name: "send", summary: "Queue a message to the agent's inbox (drained at its next turn-end).",
```

- [ ] **Step 4: Run — expect PASS**

Run: `./scripts/test.sh --filter SendRoutingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/Commands.swift Tests/OrchestraCoreTests/InboxTests.swift
git commit -m "feat(inbox): route send through the durable inbox (F3), not tmux keystrokes"
```

---

### Task 5: `drain` daemon RPC (ControlServer)

**Files:**
- Modify: `Sources/OrchestraCore/Control/ControlServer.swift` (add `drain` case)
- Test: `Tests/OrchestraCoreTests/ControlRoundTripTests.swift`

**Interfaces:**
- New RPC `drain` (Orchestra-internal, not a `Command`): params `{ ref: <task ref> }` → resolves the ref, calls
  `service.drainForStop(task.id)`, returns `{ reason: <payload> }` where `reason` is the composed payload string,
  or JSON `null` when there is nothing to inject.

- [ ] **Step 1: Write the failing round-trip test**

Add to `ControlRoundTripTests`:

```swift
    @Test("drain RPC returns the composed inbox payload for a card")
    func drainRPC() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }
        let client = ControlClient(socketPath: path, source: .agent)
        try client.connect(); defer { client.close() }

        let spawnRes = try await client.call("spawn", .object([
            "prompt": .string("c"), "repo": .string(repo), "branch": .string("feat")]))
        let task = try spawnRes.decode(Task.self)

        // empty inbox → reason is null
        let empty = try await client.call("drain", .object(["ref": .string(task.shortId)]))
        #expect(empty["reason"]?.stringValue == nil)

        // enqueue via send, then drain returns the payload
        try await env.svc.send(task.id, "queued work")
        let got = try await client.call("drain", .object(["ref": .string(task.shortId)]))
        #expect(got["reason"]?.stringValue?.contains("queued work") == true)
    }
```

- [ ] **Step 2: Run — expect FAIL (`method not found: drain`)**

Run: `./scripts/test.sh --filter ControlRoundTripTests`
Expected: FAIL — the `drain` call errors with method-not-found.

- [ ] **Step 3: Add the `drain` RPC case**

In `ControlServer.swift`, add a case alongside `report` (after line 150):

```swift
        case "drain":
            guard let p = req.params, let ref = p.optString("ref") else {
                throw OrchestraError.invalidParams("drain needs ref")
            }
            let task = try await service.resolveRef(ref)
            let reason = await service.drainForStop(task.id)
            return .object(["reason": reason.map(JSONValue.string) ?? .null])
```

> Confirm the `JSONValue` null spelling in this codebase (grep `case .null` / `JSONValue.null` in
> `Sources/OrchestraCore/JSONValue.swift`); use whatever the enum exposes (`.null`).

- [ ] **Step 4: Run — expect PASS**

Run: `./scripts/test.sh --filter ControlRoundTripTests`
Expected: PASS (all round-trip tests, including `drainRPC`).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Control/ControlServer.swift Tests/OrchestraCoreTests/ControlRoundTripTests.swift
git commit -m "feat(inbox): drain RPC — Stop hook fetches the F3 payload from the daemon"
```

---

### Task 6: Stop-hook drain in `ReportHelper` (detect Stop → drain → print block JSON)

**Files:**
- Modify: `Sources/orchestra/ReportHelper.swift`
- Test: `Tests/OrchestraCoreTests/InboxTests.swift` (pure helpers) — the full process path is covered by the e2e.

**Interfaces:**
- The `_report` process, when the hook payload's `hook_event_name == "Stop"`, after sending the (unchanged)
  notify report, calls the daemon `drain` RPC for `$ORCHESTRA_TASK_ID` and, if a payload comes back, prints
  `StopDrain.blockJSON(reason:)` to stdout (this is what makes Claude continue). Non-Stop events are unchanged.
- Add a `boundedCall(sock:method:params:budgetMs:) -> JSONValue?` variant of `boundedSend` that returns the
  response result (the current `boundedSend` discards it).

> **Testability:** the `_report` helper is a process entry point (reads real stdin / opens a socket), so it is
> exercised end-to-end by the e2e, not a unit test. The *pure* pieces it relies on are already unit-tested:
> `StopDrain.blockJSON` (Task 2) and `drainForStop` (Task 3). Keep the new helper code a thin transport shim so
> there is no untested logic: detection is a one-line field read, and the payload/format are tested elsewhere.

- [ ] **Step 1: Add `boundedCall` (returns the response) next to `boundedSend`**

In `ReportHelper.swift`, add below `boundedSend`:

```swift
    /// Like `boundedSend`, but returns the daemon's `result` (or nil on timeout/error). Used by the Stop
    /// drain, which needs the response payload.
    static func boundedCall(sock: String, method: String, params: JSONValue, budgetMs: Int) async -> JSONValue? {
        let client = ControlClient(socketPath: sock, source: .agent)
        do { try client.connect() } catch { return nil }
        var result: JSONValue?
        await withTaskGroup(of: Void.self) { group in
            group.addTask { result = try? await client.call(method, params) }
            group.addTask { try? await _Concurrency.Task.sleep(for: .milliseconds(budgetMs)) }
            await group.next()
            client.close()
            group.cancelAll()
        }
        return result
    }
```

> Verify `ControlClient.call(_:_:)` signature (grep `func call` in `Sources/OrchestraCore/Control/ControlClient.swift`)
> and match it — `boundedSend` already calls `client.call("report", params)`, so the same shape applies.

- [ ] **Step 2: Detect Stop and drain, in `ReportHelper.run`**

At the end of `run(_:)`, after the `await boundedSend(...)` report send, add:

```swift
        // F3 Stop-drain: on the Stop hook (same `_report --event notify` command — distinguished by
        // `hook_event_name`), pull the card's durable inbox and, if non-empty, print the `decision:block`
        // continuation so Claude reads the queued messages as context. Additive: the notify→waiting report
        // above is unchanged.
        if payload["hook_event_name"]?.stringValue == "Stop" {
            let drainParams = JSONValue.object(["ref": .string(taskId)])
            if let resp = await boundedCall(sock: sock, method: "drain", params: drainParams, budgetMs: 2000),
               let reason = resp["reason"]?.stringValue, !reason.isEmpty {
                FileHandle.standardOutput.write(Data(StopDrain.blockJSON(reason: reason).utf8))
            }
        }
```

> `taskId` and `sock` are already in scope from the guard above (the function returns early if `ORCHESTRA_TASK_ID`
> is empty, which is correct — no card, no drain). `payload` is the parsed stdin JSON.

- [ ] **Step 3: Build the CLI target to confirm it compiles**

Run: `./scripts/test.sh --filter InboxStoreTests` (forces a full build of both targets)
Expected: PASS + no build errors in the `orchestra` target.

- [ ] **Step 4: Commit**

```bash
git add Sources/orchestra/ReportHelper.swift
git commit -m "feat(inbox): Stop hook drains the inbox → decision:block continuation (F3)"
```

---

### Task 7: Behavior-preservation — Stop-drain still emits the notify/waiting report

**Files:**
- Test: `Tests/OrchestraCoreTests/InboxTests.swift`

**Interfaces:** consumes `OrchestraService.report` (unchanged) + `ClaudeCodeAdapter.parse` (unchanged).

This proves C1 did not regress the Stop hook's existing report: the notify event still maps to `waiting`, and it
is independent of the drain.

- [ ] **Step 1: Write the test**

Add to `InboxTests.swift`:

```swift
@Suite("C1 · Stop-drain preserves the notify/waiting report")
struct NotifyPreservedTests {
    @Test("the Stop hook's notify event still parses to a waiting StatusReport and drives the card to waiting")
    func notifyStillWaiting() async throws {
        // 1. parse is byte-identical: notify → waiting.
        let report = ClaudeCodeAdapter().parse(.hooksPush(kind: "notify", payload: .object([:])))
        #expect(report?.snapshot?.status == .waiting)

        // 2. applied through the service, the card goes to .waiting — with a message queued in the inbox.
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await env.svc.spawn(SpawnInput(prompt: "w", repo: repo, branch: "feat"))
        try await env.svc.send(task.id, "queued")             // inbox has a pending message
        try await env.svc.report(task.id, ClaudeCodeAdapter().parse(.hooksPush(kind: "notify", payload: .object([:])))!)
        let after = try #require(await env.svc.status(task.id).task as Task?)
        #expect(after.status == .waiting)                     // notify/waiting report preserved
        #expect(await Inbox(path: env.base + "/inbox.json").peek(task.id).count == 1)  // drain is a separate step
    }
}
```

> Adjust `SpawnInput(...)` / the `status(...)` accessor to the real API (grep the existing tests). The essential
> assertions: `parse("notify")` → `.waiting`, and `report(...)` still transitions the card to `.waiting`.

- [ ] **Step 2: Run — expect PASS**

Run: `./scripts/test.sh --filter NotifyPreservedTests`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/OrchestraCoreTests/InboxTests.swift
git commit -m "test(inbox): Stop-drain preserves the notify/waiting report (behavior-preserved)"
```

---

### Task 8: Full green gate + advisory e2e

**Files:** none (verification only).

- [ ] **Step 1: Full unit suite (unsandboxed)**

Run: `./scripts/test.sh`
Expected: PASS. If the ONLY failure is `RecoveryTests` "resume success: confirmed within grace" (a known
pre-existing flake under parallel load), re-run `./scripts/test.sh --filter RecoveryTests` and treat green if it
passes in isolation.

- [ ] **Step 2: App typecheck**

Run: `./scripts/typecheck-app.sh`
Expected: PASS (self-pins the CLT toolchain; no `DEVELOPER_DIR` needed).

- [ ] **Step 3: Advisory UX e2e**

Run: `./scripts/orch-ux-e2e.sh --run-id c1inbox`
Expected: advisory (per O6). The screenshot step may fail on a headless/locked window server — that is
environmental, not a defect. Unit tests + typecheck are the gate.

- [ ] **Step 4: Move to `review` and report**

Do NOT merge to `main`, do NOT archive. Move this card to the `review` column and report:
`DONE: live/01-inbox-stopdrain — tests green` + a one-line summary.

---

## Self-Review

**Spec coverage (C1 row + 04-tests `Inbox`/F3 row):**
- durable Inbox store (sibling to TaskStore) → Task 1 ✅
- durability across restart → Task 1 Step 6 ✅
- enqueue→drain order → Task 1 Step 2 ✅
- inject cap (loop guard) → Task 3 ✅
- 10k `additionalContext` payload bound → Task 2 (`StopDrain.maxPayloadChars`) ✅
- route `send` through the inbox → Task 4 ✅
- repurpose the EXISTING Stop hook to ALSO drain (`decision:block`+payload), preserving `_report --event notify`
  / waiting → Task 5 (RPC) + Task 6 (hook shim, `hook_event_name` detection, notify unchanged) + Task 7 ✅
- C1 bases on A2 / no HooksRenderer conflict → `HooksRenderer`/`claude-hooks.json` left untouched ✅
- Stop-drain STILL emits the notify/waiting report → Task 7 ✅

**Placeholder scan:** every code step shows complete code; the two "verify the exact API" notes (JSONValue
null/serialize, ControlClient.call, SpawnInput labels) are grounding reminders, not placeholders — the concrete
code is present and only needs the real symbol confirmed by a one-line grep.

**Type consistency:** `Inbox` / `InboxMessage` / `StopDrain.compose` / `StopDrain.blockJSON` /
`OrchestraService.drainForStop` / `resetInjectCount` / `maxConsecutiveInjects` / `Config.inboxPath` / the `drain`
RPC are used identically across tasks. `drainForStop` returns `String?` everywhere; the RPC wraps it as
`{reason: String|null}`; the hook reads `resp["reason"]`.

**Open risk flagged for implementation:** the exact `decision:block` continuation field. Design says
"`additionalContext` (10k)"; the documented Claude Stop-hook field is `reason` on `{"decision":"block"}` (fed to
the model to proceed). Plan uses `reason`, capped at 10k. If the e2e shows Claude does not continue, add
`hookSpecificOutput.additionalContext` alongside `reason` in `StopDrain.blockJSON` (both carry the same payload).
Unit tests (the gate) are unaffected either way.
