# Agent Buttons Simplification + Inbox Editor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the fan-out / handoff / fork buttons, replace the Send button with a full inbox editor (list / reorder / append / edit / remove), expose the inbox operations as MCP commands, and update the delegation skill doc so exploratory forks default to a freeform read-only card in the current cwd.

**Architecture:** The daemon owns a durable `Inbox` actor (JSON-backed). We add three actor mutators (`remove`/`update`/`reorder`), thin `OrchestraService` pass-throughs, and four `CommandRegistry` commands (`inbox`, `inbox-edit`, `inbox-remove`, `inbox-reorder`) — which surface as MCP tools automatically because the MCP bridge is generated from the registry. The SwiftUI app gets `BoardModel` wrappers and a new `InboxEditorView` popover, and drops the three removed buttons. The delegation docs are edited to teach the freeform-readonly fork recipe.

**Tech Stack:** Swift (SwiftPM for `OrchestraCore` + daemon/CLI/MCP; a separate Xcode/SwiftUI app under `App/`), `swift-testing` (`@Suite`/`@Test`/`#expect`).

## Global Constraints

- Core/daemon/CLI/MCP build + test with `swift build` / `swift test` — these targets stay dependency-free and offline-green. Do NOT add the `App/` sources to `Package.swift`.
- The SwiftUI app (`App/`) is built separately: typecheck with `scripts/typecheck-app.sh`, full build with `scripts/build-app.sh`, visual check with `scripts/orch-ui-shot.sh`.
- Every registry command auto-becomes an MCP tool (`Sources/orchestra-mcp/main.swift` maps each `Command`) and a CLI verb. Adding a command to `CommandRegistry.build()` is all that's needed to expose it on both surfaces.
- Never pass `git -C <path>`; rely on cwd.
- Do throwaway work in `./.scratch/`.
- Commit message trailers (end every commit with):
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Szir87pEDAHY6GYkBLwNnT
  ```

---

## File Structure

**Modified — core (SwiftPM, tested):**
- `Sources/OrchestraCore/Inbox.swift` — add `remove`/`update`/`reorder` actor methods.
- `Sources/OrchestraCore/OrchestraService.swift` — add `inboxPeek`/`inboxRemove`/`inboxUpdate`/`inboxReorder` pass-throughs near `send` (~line 315).
- `Sources/OrchestraCore/Commands.swift` — register four commands in `build()`.
- `Tests/OrchestraCoreTests/InboxTests.swift` — actor-level tests.
- `Tests/OrchestraCoreTests/CommandsTests.swift` — command dispatch tests + update the `fullSet` expected-names list.

**Modified — app (Xcode, typecheck/build):**
- `App/BoardModel.swift` — remove `handoff`/`fork`/`fanout`; remove `showFanout`; add four inbox wrappers.
- `App/Views/ToolbarView.swift` — remove `fanoutButton` + its use in `ControlsRow.body`.
- `App/OrchestraApp.swift` — remove the fan-out overlay + its `.animation` line.
- `App/Views/InspectorView.swift` — remove handoff/fork actions + their `@State`; replace `sendAction` with `inboxAction`; add `InboxEditorView`.

**Deleted:**
- `App/Views/FanoutSheet.swift`.

**Modified — docs:**
- `Sources/OrchestraCore/Resources/delegation-skill.md`
- `Sources/OrchestraCore/Resources/delegation-agents.md`

---

## Task 1: Inbox actor — remove / update / reorder

**Files:**
- Modify: `Sources/OrchestraCore/Inbox.swift`
- Test: `Tests/OrchestraCoreTests/InboxTests.swift`

**Interfaces:**
- Consumes: existing `InboxMessage { id, cardId, text, createdAt }`, `Inbox.peek/enqueue/drain`, `OrchestraError.invalidParams(_:)`.
- Produces (public `Inbox` actor methods):
  - `func remove(_ id: UUID) throws`
  - `func update(_ id: UUID, text: String) throws`
  - `func reorder(_ cardId: UUID, orderedIds: [UUID]) throws`

- [ ] **Step 1: Write the failing tests**

Add this suite to `Tests/OrchestraCoreTests/InboxTests.swift` (append at end of file):

```swift
@Suite("Inbox edit / remove / reorder")
struct InboxEditTests {
    static func tmp() -> String { NSTemporaryDirectory() + "inbox-\(UUID().uuidString).json" }

    @Test("remove drops one message by id, leaves the rest")
    func removeOne() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let c = UUID()
        try await inbox.enqueue(c, "a"); try await inbox.enqueue(c, "b")
        let ids = await inbox.peek(c).map(\.id)
        try await inbox.remove(ids[0])
        #expect(await inbox.peek(c).map(\.text) == ["b"])
    }

    @Test("update replaces text only, preserving id/createdAt")
    func updateText() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let c = UUID()
        try await inbox.enqueue(c, "old")
        let m = try #require(await inbox.peek(c).first)
        try await inbox.update(m.id, text: "new")
        let after = try #require(await inbox.peek(c).first)
        #expect(after.text == "new")
        #expect(after.id == m.id)
        #expect(after.createdAt == m.createdAt)
    }

    @Test("update throws for an unknown message id")
    func updateUnknown() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path)
        await #expect(throws: OrchestraError.self) {
            try await inbox.update(UUID(), text: "x")
        }
    }

    @Test("reorder permutes a card's messages and preserves other cards' interleaving")
    func reorderPreservesInterleave() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let a = UUID(); let b = UUID()
        // array order: a1, b1, a2, a3
        try await inbox.enqueue(a, "a1"); try await inbox.enqueue(b, "b1")
        try await inbox.enqueue(a, "a2"); try await inbox.enqueue(a, "a3")
        let aIds = await inbox.peek(a).map(\.id)          // [a1, a2, a3]
        // new order for a: a3, a1, a2
        try await inbox.reorder(a, orderedIds: [aIds[2], aIds[0], aIds[1]])
        #expect(await inbox.peek(a).map(\.text) == ["a3", "a1", "a2"])
        #expect(await inbox.peek(b).map(\.text) == ["b1"])  // b untouched
    }

    @Test("reorder rejects a non-permutation of the card's ids")
    func reorderRejectsBadIds() async throws {
        let path = Self.tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let inbox = Inbox(path: path); let c = UUID()
        try await inbox.enqueue(c, "a"); try await inbox.enqueue(c, "b")
        await #expect(throws: OrchestraError.self) {
            try await inbox.reorder(c, orderedIds: [UUID()])   // wrong ids
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter InboxEditTests`
Expected: FAIL — `value of type 'Inbox' has no member 'remove'` (and `update`/`reorder`).

- [ ] **Step 3: Implement the three methods**

In `Sources/OrchestraCore/Inbox.swift`, insert these methods after `drain(_:)` (before `private func persist()`), at `Inbox.swift:63`:

```swift
    /// Remove one message by id (no-op if absent). Used by the inbox editor.
    public func remove(_ id: UUID) throws {
        ensureLoaded()
        messages.removeAll { $0.id == id }
        try persist()
    }

    /// Replace a message's text in place; id / cardId / createdAt are preserved.
    public func update(_ id: UUID, text: String) throws {
        ensureLoaded()
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            throw OrchestraError.invalidParams("no inbox message with id \(id)")
        }
        let old = messages[idx]
        messages[idx] = InboxMessage(id: old.id, cardId: old.cardId, text: text, createdAt: old.createdAt)
        try persist()
    }

    /// Reorder a single card's pending messages. `orderedIds` must be a permutation of that card's
    /// current message ids. Because all cards share one append-ordered array, this refills exactly the
    /// array slots the card already occupies (in the new order), leaving other cards' interleaving intact.
    public func reorder(_ cardId: UUID, orderedIds: [UUID]) throws {
        ensureLoaded()
        let slots = messages.enumerated().filter { $0.element.cardId == cardId }
        let current = slots.map(\.element)
        guard Set(orderedIds) == Set(current.map(\.id)) else {
            throw OrchestraError.invalidParams("orderedIds must be a permutation of the card's pending message ids")
        }
        let byId = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let reordered = orderedIds.map { byId[$0]! }
        for (slot, msg) in zip(slots.map(\.offset), reordered) { messages[slot] = msg }
        try persist()
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter InboxEditTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Inbox.swift Tests/OrchestraCoreTests/InboxTests.swift
git commit -m "feat(inbox): remove/update/reorder actor methods

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Szir87pEDAHY6GYkBLwNnT"
```

---

## Task 2: Service pass-throughs + inbox MCP commands

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift:315-320` (add methods after `send`)
- Modify: `Sources/OrchestraCore/Commands.swift` (add commands in `build()`, after the `send` command at line 83)
- Test: `Tests/OrchestraCoreTests/CommandsTests.swift`

**Interfaces:**
- Consumes: `Inbox.peek/remove/update/reorder` (Task 1), `OrchestraService.require(_:)`, `OrchestraService.resolveRef(_:)`, `CommandRegistry.schema/strProp/refProp`, `JSONValue.string/arrayValue/stringValue`, `JSONValue.ok()`, `JSONValue(encodable:)`.
- Produces:
  - `OrchestraService.inboxPeek(_ id: UUID) async throws -> [InboxMessage]`
  - `OrchestraService.inboxRemove(_ id: UUID, messageId: UUID) async throws`
  - `OrchestraService.inboxUpdate(_ id: UUID, messageId: UUID, text: String) async throws`
  - `OrchestraService.inboxReorder(_ id: UUID, orderedIds: [UUID]) async throws`
  - Registry commands: `inbox`, `inbox-edit`, `inbox-remove`, `inbox-reorder`.

- [ ] **Step 1: Write the failing tests**

Append this suite to `Tests/OrchestraCoreTests/CommandsTests.swift`:

```swift
@Suite("Inbox editor commands")
struct InboxCommandsTests {
    @Test("inbox lists, inbox-edit rewrites, inbox-remove drops, inbox-reorder permutes")
    func inboxCrud() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let reg = CommandRegistry()
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        try await env.svc.send(t.id, "one")
        try await env.svc.send(t.id, "two")

        // inbox (list)
        let list = try #require(reg.command("inbox"))
        let msgs = try await list.run(env.svc, .object(["ref": .string(t.shortId)]), .mcp)
            .decode([InboxMessage].self)
        #expect(msgs.map(\.text) == ["one", "two"])

        // inbox-edit
        let edit = try #require(reg.command("inbox-edit"))
        _ = try await edit.run(env.svc, .object(["ref": .string(t.shortId),
            "id": .string(msgs[0].id.uuidString), "text": .string("ONE")]), .mcp)

        // inbox-reorder → [two, one]
        let reorder = try #require(reg.command("inbox-reorder"))
        _ = try await reorder.run(env.svc, .object(["ref": .string(t.shortId),
            "ids": .array([.string(msgs[1].id.uuidString), .string(msgs[0].id.uuidString)])]), .mcp)

        let afterEdit = try await list.run(env.svc, .object(["ref": .string(t.shortId)]), .mcp)
            .decode([InboxMessage].self)
        #expect(afterEdit.map(\.text) == ["two", "ONE"])

        // inbox-remove
        let remove = try #require(reg.command("inbox-remove"))
        _ = try await remove.run(env.svc, .object(["ref": .string(t.shortId),
            "id": .string(msgs[1].id.uuidString)]), .mcp)
        let final = try await list.run(env.svc, .object(["ref": .string(t.shortId)]), .mcp)
            .decode([InboxMessage].self)
        #expect(final.map(\.text) == ["ONE"])
    }

    @Test("inbox-edit rejects a non-UUID id")
    func badId() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let reg = CommandRegistry()
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        let edit = try #require(reg.command("inbox-edit"))
        await #expect(throws: OrchestraError.self) {
            _ = try await edit.run(env.svc, .object(["ref": .string(t.shortId),
                "id": .string("not-a-uuid"), "text": .string("z")]), .mcp)
        }
    }
}
```

Also update the `fullSet` test's `expected` array (`CommandsTests.swift:11-13`) to include the four new names:

```swift
        let expected = ["list", "spawn", "move", "send", "status", "archive",
                        "restart", "resume", "shell", "inspect", "closeShell", "exec", "sessions", "batch-spawn",
                        "wait", "handoff", "trust", "trustState",
                        "inbox", "inbox-edit", "inbox-remove", "inbox-reorder"]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "Inbox editor commands"`
Expected: FAIL — `reg.command("inbox")` returns nil → `#require` throws.

- [ ] **Step 3a: Add the service pass-throughs**

In `Sources/OrchestraCore/OrchestraService.swift`, immediately after the `send(_:_:)` method (after line 320), add:

```swift
    /// Inbox editor (UI + MCP): list a card's pending messages. Non-destructive.
    public func inboxPeek(_ id: UUID) async throws -> [InboxMessage] {
        let t = try await require(id)
        return await inbox.peek(t.id)
    }

    /// Inbox editor: remove one queued message by its id.
    public func inboxRemove(_ id: UUID, messageId: UUID) async throws {
        _ = try await require(id)
        try await inbox.remove(messageId)
    }

    /// Inbox editor: edit the text of one queued message.
    public func inboxUpdate(_ id: UUID, messageId: UUID, text: String) async throws {
        _ = try await require(id)
        try await inbox.update(messageId, text: text)
    }

    /// Inbox editor: reorder a card's queued messages (ids = full new order).
    public func inboxReorder(_ id: UUID, orderedIds: [UUID]) async throws {
        let t = try await require(id)
        try await inbox.reorder(t.id, orderedIds: orderedIds)
    }
```

- [ ] **Step 3b: Register the four commands**

In `Sources/OrchestraCore/Commands.swift`, insert these four `Command` entries right after the `send` command (after line 83, before the `wait` command):

```swift
            Command(name: "inbox",
                    summary: "List a card's pending inbox messages (id, text, createdAt) in FIFO order.",
                    params: schema(["ref": refProp()], required: ["ref"])) { svc, p, _ in
                let t = try await svc.resolveRef(try p.string("ref"))
                return try JSONValue(encodable: await svc.inboxPeek(t.id))
            },

            Command(name: "inbox-edit", summary: "Edit the text of a queued inbox message.",
                    params: schema(["ref": refProp(),
                                    "id": strProp("Inbox message id (a UUID from `inbox`)"),
                                    "text": strProp("New message text")],
                                   required: ["ref", "id", "text"])) { svc, p, _ in
                let t = try await svc.resolveRef(try p.string("ref"))
                guard let mid = UUID(uuidString: try p.string("id")) else {
                    throw OrchestraError.invalidParams("id must be a message UUID")
                }
                try await svc.inboxUpdate(t.id, messageId: mid, text: try p.string("text"))
                return .ok()
            },

            Command(name: "inbox-remove", summary: "Remove a queued inbox message by id.",
                    params: schema(["ref": refProp(),
                                    "id": strProp("Inbox message id (a UUID from `inbox`)")],
                                   required: ["ref", "id"])) { svc, p, _ in
                let t = try await svc.resolveRef(try p.string("ref"))
                guard let mid = UUID(uuidString: try p.string("id")) else {
                    throw OrchestraError.invalidParams("id must be a message UUID")
                }
                try await svc.inboxRemove(t.id, messageId: mid)
                return .ok()
            },

            Command(name: "inbox-reorder",
                    summary: "Reorder a card's pending inbox messages (`ids` = the full new order).",
                    params: schema(["ref": refProp(),
                                    "ids": .object([
                                        "type": .string("array"),
                                        "items": .object(["type": .string("string")]),
                                        "description": .string("The card's message ids in the desired new order"),
                                    ])],
                                   required: ["ref", "ids"])) { svc, p, _ in
                let t = try await svc.resolveRef(try p.string("ref"))
                guard let arr = p["ids"]?.arrayValue else {
                    throw OrchestraError.invalidParams("ids must be an array")
                }
                var ordered: [UUID] = []
                for e in arr {
                    guard let s = e.stringValue, let u = UUID(uuidString: s) else {
                        throw OrchestraError.invalidParams("each id must be a UUID string")
                    }
                    ordered.append(u)
                }
                try await svc.inboxReorder(t.id, orderedIds: ordered)
                return .ok()
            },
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CommandsTests` (covers both the new suite and the updated `fullSet`).
Expected: PASS. Then run the whole core suite to catch regressions:
Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/Commands.swift Tests/OrchestraCoreTests/CommandsTests.swift
git commit -m "feat(inbox): inbox/inbox-edit/inbox-remove/inbox-reorder commands

Exposes the inbox editor ops on the shared registry (MCP + CLI + app).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Szir87pEDAHY6GYkBLwNnT"
```

---

## Task 3: Remove the Fan-out button

**Files:**
- Modify: `App/Views/ToolbarView.swift:91` (remove `fanoutButton` from body) and `App/Views/ToolbarView.swift:97-117` (remove the `fanoutButton` computed property)
- Modify: `App/OrchestraApp.swift:104-113` (remove overlay) and `App/OrchestraApp.swift:133` (remove animation)
- Modify: `App/BoardModel.swift:28` (remove `showFanout`) and `App/BoardModel.swift:269-283` (remove `fanout`)
- Delete: `App/Views/FanoutSheet.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: no fan-out UI; `batch-spawn` remains reachable via MCP only.

- [ ] **Step 1: Remove the toolbar button**

In `App/Views/ToolbarView.swift`, delete the `fanoutButton` line from `ControlsRow.body` (line 91):

```swift
        HStack(spacing: 10) {
            mcpChip
            doneButton
            activityButton
            themeToggle
            newAgentButton
        }
```

Then delete the entire `// MARK: - Fan-out` section and `fanoutButton` property (lines 97-117).

- [ ] **Step 2: Remove the overlay + animation**

In `App/OrchestraApp.swift`, delete the fan-out overlay block (lines 104-113, the `if model.showFanout { … FanoutSheet() … }`) and the animation line `.animation(.easeOut(duration: 0.18), value: model.showFanout)` (line 133).

- [ ] **Step 3: Remove the model state + method**

In `App/BoardModel.swift`, delete `@Published var showFanout = false` (line 28) and the entire `fanout(prompts:repo:branch:)` method (lines 269-283, including its doc comment).

- [ ] **Step 4: Delete the sheet**

```bash
git rm App/Views/FanoutSheet.swift
```

- [ ] **Step 5: Typecheck the app**

Run: `scripts/typecheck-app.sh`
Expected: no errors, no remaining references to `showFanout`, `fanout`, or `FanoutSheet`.
(If typecheck is slow/unavailable, run `scripts/build-app.sh` instead and confirm it builds.)

- [ ] **Step 6: Commit**

```bash
git add App/Views/ToolbarView.swift App/OrchestraApp.swift App/BoardModel.swift
git commit -m "feat(app): remove Fan-out button (batch-spawn stays MCP-only)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Szir87pEDAHY6GYkBLwNnT"
```

---

## Task 4: Remove the Handoff and Fork buttons

**Files:**
- Modify: `App/Views/InspectorView.swift:42-49` (remove handoff/fork `@State`), `:66-69` (remove from body), `:117-151` (remove `handoffAction` + `forkAction`)
- Modify: `App/BoardModel.swift:245-267` (remove `handoff` + `fork`)

**Interfaces:**
- Consumes: nothing new.
- Produces: the per-card header shows only Send (→ becomes Inbox in Task 5) + Archive. `handoff` remains reachable via MCP; fork is reachable via `spawn` (MCP).

- [ ] **Step 1: Remove the button calls from the header body**

In `App/Views/InspectorView.swift`, in `HeaderBar.body` (lines 66-69), remove `handoffAction` and `forkAction`, leaving:

```swift
            // Live-delivery card actions — hidden for a dead card (recovery owns that state).
            if task.status != .dead {
                sendAction
```

(Do not touch `sendAction` here — Task 5 renames it.)

- [ ] **Step 2: Remove the handoff/fork `@State`**

In `App/Views/InspectorView.swift`, delete these `@State` lines (from the block at 42-49):

```swift
    @State private var showHandoff = false
    @State private var showFork = false
    @State private var handoffText = ""
    @State private var forkPrompt = ""
    @State private var forkContext = ""
    @State private var forkBranch = ""
```

Leave `showSend` and `sendText` (Task 5 handles them).

- [ ] **Step 3: Remove the action builders**

In `App/Views/InspectorView.swift`, delete the entire `handoffAction` computed property (lines 117-127, incl. its `/// Handoff (F1)…` doc comment) and the entire `forkAction` computed property (lines 129-151, incl. its `/// Fork:…` doc comment).

- [ ] **Step 4: Remove the model methods**

In `App/BoardModel.swift`, delete the `handoff(_:context:)` method (lines 245-253, incl. doc comment) and the `fork(from:prompt:branch:context:)` method (lines 255-267, incl. doc comment).

- [ ] **Step 5: Typecheck the app**

Run: `scripts/typecheck-app.sh`
Expected: no errors. `popoverField`, `popoverEditor`, `confirmButton`, and `actionButton` are still used by `sendAction`, so they stay (no unused-helper warnings that fail the build).

- [ ] **Step 6: Commit**

```bash
git add App/Views/InspectorView.swift App/BoardModel.swift
git commit -m "feat(app): remove Handoff and Fork buttons (use natural-language MCP)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Szir87pEDAHY6GYkBLwNnT"
```

---

## Task 5: Send → Inbox editor

**Files:**
- Modify: `App/BoardModel.swift` (add four inbox wrappers near `send`, ~line 243)
- Modify: `App/Views/InspectorView.swift` (rename `showSend`→`showInbox`, drop `sendText`; replace `sendAction` with `inboxAction`; add `InboxEditorView`)

**Interfaces:**
- Consumes: registry commands `inbox`/`inbox-edit`/`inbox-remove`/`inbox-reorder` (Task 2); `OrchestraCore.InboxMessage`; existing `BoardModel.send`.
- Produces:
  - `BoardModel.inboxPeek(_ id: UUID) async -> [InboxMessage]`
  - `BoardModel.inboxEdit(_ id: UUID, messageId: UUID, text: String) async`
  - `BoardModel.inboxRemove(_ id: UUID, messageId: UUID) async`
  - `BoardModel.inboxReorder(_ id: UUID, orderedIds: [UUID]) async`
  - `InboxEditorView` (private, in InspectorView.swift); `inboxAction` header button.

- [ ] **Step 1: Add the BoardModel wrappers**

In `App/BoardModel.swift`, right after the existing `send(_:_:)` method (after line 243), add:

```swift
    /// Inbox editor: list a card's pending messages (empty on any error).
    func inboxPeek(_ id: UUID) async -> [InboxMessage] {
        (try? await client.call("inbox", .object(["ref": .string(id.uuidString)]))
            .decode([InboxMessage].self)) ?? []
    }
    /// Inbox editor: edit one queued message's text.
    func inboxEdit(_ id: UUID, messageId: UUID, text: String) async {
        _ = try? await client.call("inbox-edit", .object(["ref": .string(id.uuidString),
            "id": .string(messageId.uuidString), "text": .string(text)]))
    }
    /// Inbox editor: remove one queued message.
    func inboxRemove(_ id: UUID, messageId: UUID) async {
        _ = try? await client.call("inbox-remove", .object(["ref": .string(id.uuidString),
            "id": .string(messageId.uuidString)]))
    }
    /// Inbox editor: reorder a card's queued messages (full new order).
    func inboxReorder(_ id: UUID, orderedIds: [UUID]) async {
        _ = try? await client.call("inbox-reorder", .object(["ref": .string(id.uuidString),
            "ids": .array(orderedIds.map { .string($0.uuidString) })]))
    }
```

- [ ] **Step 2: Rename the header state**

In `App/Views/InspectorView.swift`, in the `@State` block, replace:

```swift
    @State private var showSend = false
```
```swift
    @State private var sendText = ""
```

with a single:

```swift
    @State private var showInbox = false
```

(Delete the now-unused `sendText`.)

- [ ] **Step 3: Replace `sendAction` with `inboxAction`**

In `App/Views/InspectorView.swift`, change the body reference (was `sendAction` at line 67) to `inboxAction`:

```swift
            // Live-delivery card actions — hidden for a dead card (recovery owns that state).
            if task.status != .dead {
                inboxAction
```

Then replace the entire `sendAction` computed property (lines 105-115, incl. its doc comment) with:

```swift
    /// Inbox (F3): view/reorder/edit/remove/append the card's durable queued messages.
    private var inboxAction: some View {
        actionButton("Inbox", systemImage: "tray.full", isOn: $showInbox) {
            InboxEditorView(task: task)
                .environmentObject(model)
                .environment(\.theme, theme)
        }
    }
```

- [ ] **Step 4: Add the `InboxEditorView`**

In `App/Views/InspectorView.swift`, add this private struct just after the `HeaderBar` struct closes (after line 223, before the `private extension String` block). It uses up/down chevrons to reorder (robust inside a popover; drag-and-drop is a possible future enhancement):

```swift
/// The inbox editor popover: list the card's durable queued messages with per-row reorder
/// (up/down), inline edit, and delete, plus an append field. All ops round-trip to the daemon
/// and reload. Loaded fresh each time the popover opens.
private struct InboxEditorView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task

    @State private var messages: [InboxMessage] = []
    @State private var appendText = ""
    @State private var editingId: UUID?
    @State private var editText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inbox — \(messages.count) queued").font(F.ui(12, .semibold)).foregroundColor(theme.text)
            Text("Delivered at the agent's next turn-end (F3).").font(F.ui(11)).foregroundColor(theme.text2)

            if messages.isEmpty {
                Text("No queued messages.").font(F.ui(11.5)).foregroundColor(theme.text3)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 4) { ForEach(messages, id: \.id) { row($0) } }
                }
                .frame(maxHeight: 220)
            }

            HStack(spacing: 6) {
                TextField("Append a message…", text: $appendText)
                    .textFieldStyle(.plain)
                    .font(F.ui(12.5)).foregroundColor(theme.text)
                    .padding(.horizontal, 9).frame(height: 30)
                    .background(theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.fieldBorder, lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Button {
                    let text = appendText.trimmed; guard !text.isEmpty else { return }
                    appendText = ""
                    _Concurrency.Task { await model.send(task.id, text); await reload() }
                } label: {
                    Text("Add").font(F.ui(12, .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(theme.accent.opacity(appendText.trimmed.isEmpty ? 0.4 : 1))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(appendText.trimmed.isEmpty)
            }
        }
        .padding(12).frame(width: 360)
        .task { await reload() }
    }

    private func row(_ m: InboxMessage) -> some View {
        HStack(spacing: 6) {
            VStack(spacing: 1) {
                chevron("chevron.up") { _Concurrency.Task { await move(m, by: -1) } }
                chevron("chevron.down") { _Concurrency.Task { await move(m, by: 1) } }
            }
            if editingId == m.id {
                TextField("", text: $editText, onCommit: { _Concurrency.Task { await commitEdit(m) } })
                    .textFieldStyle(.plain)
                    .font(F.ui(12)).foregroundColor(theme.text)
            } else {
                Text(m.text).font(F.ui(12)).foregroundColor(theme.text).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { editingId = m.id; editText = m.text }
            }
            Button { _Concurrency.Task { await remove(m) } } label: {
                Image(systemName: "trash").font(F.ui(10)).foregroundColor(theme.text2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func chevron(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(F.ui(8, .semibold)).foregroundColor(theme.text2)
        }
        .buttonStyle(.plain)
    }

    private func reload() async { messages = await model.inboxPeek(task.id) }

    private func remove(_ m: InboxMessage) async {
        await model.inboxRemove(task.id, messageId: m.id); await reload()
    }

    private func commitEdit(_ m: InboxMessage) async {
        let text = editText.trimmed
        editingId = nil
        if !text.isEmpty && text != m.text { await model.inboxEdit(task.id, messageId: m.id, text: text) }
        await reload()
    }

    private func move(_ m: InboxMessage, by delta: Int) async {
        guard let i = messages.firstIndex(where: { $0.id == m.id }) else { return }
        let j = i + delta
        guard j >= 0, j < messages.count else { return }
        var ids = messages.map(\.id); ids.swapAt(i, j)
        await model.inboxReorder(task.id, orderedIds: ids); await reload()
    }
}
```

- [ ] **Step 5: Typecheck the app**

Run: `scripts/typecheck-app.sh`
Expected: no errors. (`_Concurrency.Task` matches the existing usage in this file; `F`, `theme.field`, `theme.fieldBorder`, `theme.accent`, `.trimmed` are all already used in InspectorView.)

- [ ] **Step 6: Build + visual smoke test**

Run: `scripts/build-app.sh`
Expected: builds clean.
Run: `scripts/orch-ui-shot.sh`
Expected: a screenshot of the board; open a card's inspector and confirm the header shows **Inbox** + **Archive** (no Send/Handoff/Fork), the toolbar has no **Fan-out**, and the Inbox popover lists/append/edit/reorder/delete works. Paste the PNG back for review.

- [ ] **Step 7: Commit**

```bash
git add App/BoardModel.swift App/Views/InspectorView.swift
git commit -m "feat(app): replace Send button with an Inbox editor

List/reorder/edit/append/remove the card's durable inbox; ops round-trip
through the new inbox-* commands.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Szir87pEDAHY6GYkBLwNnT"
```

---

## Task 6: Delegation skill-doc — freeform-readonly fork default

**Files:**
- Modify: `Sources/OrchestraCore/Resources/delegation-skill.md:14` (tool line) and `:37-39` (Fork bullet)
- Modify: `Sources/OrchestraCore/Resources/delegation-agents.md:11` (tool line) and `:33-35` (Fork bullet)

**Interfaces:**
- Consumes: nothing (prose only).
- Produces: guidance that steers exploratory forks to `spawn` with `cwd` + `access: readOnly` + `seed`.

- [ ] **Step 1: Update `delegation-skill.md`**

Replace the `spawn` / `batch-spawn` bullet (line 14):

```markdown
- **`spawn` / `batch-spawn`** — start a new card (or N) with a **seed** (the task + any handoff context).
```

with:

```markdown
- **`spawn` / `batch-spawn`** — start a new card (or N) with a **seed** (the task + any handoff context).
  A spawn either cuts a git **worktree** (`repo` + `branch`) *or* runs **freeform** in an existing
  directory (`cwd`, no worktree) — optionally **read-only** (`access: readOnly`: the agent can
  read/search/git but not edit/write/commit).
```

Replace the Fork bullet (lines 37-39):

```markdown
- **Fork** — *you want an independent exploration of a slice, and you'll want the result back.* Spawn with
  the slice as the seed; the fork concludes and comes back to you via a wake + your inbox. Good for
  "try approach A vs. B" and parallel discussions.
```

with:

```markdown
- **Fork** — *you want an independent exploration or side-discussion of a slice, and you'll want the
  result back.* Default to a **lightweight read-only freeform card in the same directory**: `spawn` with
  `cwd` = your working dir, `access: readOnly`, and the slice as the `seed` — no worktree, no branch,
  nothing to clean up. It explores and reports back via a wake + your inbox. Ideal for *"while planning,
  go over components A, B, and C separately without clogging this context, then pull their conclusions
  back."* Only cut a **worktree fork** (`spawn` with `repo` + `branch`) when the fork will change files
  and you want its own branch/PR.
```

- [ ] **Step 2: Update `delegation-agents.md`**

Apply the same two edits: the tool-surface `spawn` bullet (line 11) and the Fork bullet (lines 33-35). Use the identical replacement text as Step 1.

- [ ] **Step 3: Verify no build impact + docs read cleanly**

These files are bundled resources compiled into `OrchestraCore`. Confirm the package still builds:
Run: `swift build`
Expected: builds clean.
Then re-read both files and confirm the fork guidance is unambiguous and the "components A/B/C" example is present.

- [ ] **Step 4: Commit**

```bash
git add Sources/OrchestraCore/Resources/delegation-skill.md Sources/OrchestraCore/Resources/delegation-agents.md
git commit -m "docs(delegation): default exploratory forks to freeform read-only cwd cards

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Szir87pEDAHY6GYkBLwNnT"
```

---

## Final verification

- [ ] `swift test` — full core suite green (Inbox + Commands tests included).
- [ ] `scripts/build-app.sh` — app builds.
- [ ] `scripts/orch-ui-shot.sh` — inspector header shows only **Inbox** + **Archive**; toolbar has no **Fan-out**; the Inbox popover lists/appends/edits/reorders/removes.
- [ ] Manual MCP sanity (optional, isolated daemon via `scripts/orch-test.sh`): `inbox <ref>` lists, `inbox-reorder`/`inbox-edit`/`inbox-remove` mutate, and a natural-language "fork a read-only card to review component X" makes the agent call `spawn` with `cwd` + `access: readOnly` + `seed`.

## Notes / deliberate scope cuts

- **No live count badge** on the Inbox button: there is no event channel pushing per-card inbox counts to the app today, so the count is shown inside the popover header (`Inbox — N queued`) rather than on the button. Adding a live badge would mean a new subscription — out of scope.
- **Reorder uses up/down chevrons**, not drag-and-drop: more robust and deterministic inside a themed popover. The backend (`inbox-reorder`) is gesture-agnostic, so drag can be added later without server changes.
- **No dedicated `fork` MCP tool**: the agent composes `spawn` (cwd + readOnly + seed); Task 6's doc default makes that reliable.
