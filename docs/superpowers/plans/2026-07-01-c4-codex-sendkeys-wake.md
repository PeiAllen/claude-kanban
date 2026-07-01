# C4 · Codex send-keys wake (detect-and-defer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the `.sendKeys` `wakeTransport` case that C2 left as a no-op, so an idle Codex card is woken by a content-free TUI keystroke — but ONLY when it is idle and its composer is empty (detect-and-defer).

**Architecture:** `OrchestraService.wake(_:)` already dispatches on `adapter.capabilities.wakeTransport`. C2 wired `.nativeReinvoke` (Claude) and left `.sendKeys` (Codex) as `break`. C4 fills that case with `sendKeysWake(_:)`: it reads the agent pane just-in-time via `capture-pane`, asks a pure heuristic (`CodexComposer`) whether the TUI is idle-and-composer-empty, and — only then — sends a **fixed, content-free nudge** via `SessionManaging.sendKeys`. Message content is never delivered by keystroke; it rides F3 (the durable inbox / session seed), which is out of C4 scope.

**Tech Stack:** Swift 6, swift-testing (`@Suite`/`@Test`/`#expect`/`#require`), SwiftPM. Tests run under `scripts/test.sh`; app typecheck under `scripts/typecheck-app.sh`.

## Global Constraints

- **Nudge-only.** The wake keystroke is a FIXED constant carrying no inbox payload. Content rides F3 (inbox / `StopDrain` / session seed), never keystrokes.
- **Wake gate = idle AND composer-empty**, read from `capture-pane`. Defer on a draft. **Focus is NOT a gate.** Re-check right before the nudge (the single just-in-time capture IS that re-check).
- **Conservative defer.** A draft, an in-flight turn, or a pane we can't parse → defer (drop the nudge); the inbox stays durable.
- **No polling/timer loop in C4.** Defer means the nudge is dropped and retried only by the next event-driven wake (a later conclusion) or turn-end. Adding a retry timer would risk the F3 inject cap (`maxConsecutiveInjects`); `stop_hook_active` is informational, so the cap is Orchestra's to enforce (C1) — C4 must not bypass or duplicate it.
- **No real agents.** `USE_REAL_CLAUDE` stays unset; tests use `StubSessions` (records `sendKeys`, stubs `capture-pane`). Never spawn a real `codex`.
- **Do NOT rebuild** MergeWatch (C2), the inbox (C1), or the Codex adapter (B1). C4 only fills the `.sendKeys` case + adds the composer heuristic.
- **No `if agentId == …` in core.** The case is keyed on `capabilities.wakeTransport == .sendKeys`, not identity. (The `CodexComposer` heuristic is tuned to Codex's TUI because send-keys is Codex's transport in v1 — documented, not identity-branched.)

## File Structure

- **Create** `Sources/OrchestraCore/CodexComposer.swift` — pure heuristic: parse a captured pane → is it idle-and-composer-empty? No I/O, no service deps. One responsibility: the fragile TUI read, isolated so its drift is contained and unit-testable in isolation.
- **Modify** `Sources/OrchestraCore/OrchestraService+Wake.swift` — replace the `.sendKeys` `break` with `await sendKeysWake(t)`; add `sendKeysWake(_:)` + the fixed `sendKeysWakeNudge` constant.
- **Modify** `Tests/OrchestraCoreTests/Stubs.swift` — extend `StubSessions` to (a) return controllable `capture-pane` text and (b) record `sendKeys` calls. Additive; existing behavior (empty capture, no-op send) preserved.
- **Create** `Tests/OrchestraCoreTests/CodexComposerTests.swift` — unit tests for the pure heuristic.
- **Create** `Tests/OrchestraCoreTests/CodexWakeTests.swift` — service-level tests for the `.sendKeys` wake path.

---

## Task 1: `CodexComposer` — the idle-and-composer-empty heuristic

**Files:**
- Create: `Sources/OrchestraCore/CodexComposer.swift`
- Test: `Tests/OrchestraCoreTests/CodexComposerTests.swift`

**Interfaces:**
- Consumes: nothing (pure `String` in).
- Produces:
  - `enum CodexComposer` with `static func canNudge(_ pane: String) -> Bool`
  - `CodexComposer.Composer` (`.empty` / `.draft(String)` / `.unknown`) via `static func composer(_ pane: String) -> Composer`
  - `static func isWorking(_ pane: String) -> Bool`
  - Task 2 (`sendKeysWake`) calls `CodexComposer.canNudge(pane)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/CodexComposerTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("C4 · CodexComposer (idle + composer-empty heuristic; fragile by nature)")
struct CodexComposerTests {

    // An idle pane with an empty composer line → nudgeable.
    @Test("idle + empty composer → canNudge true, composer .empty")
    func idleEmpty() {
        let pane = """
        ● Ran the tests — all green.

        ›
        """
        #expect(CodexComposer.composer(pane) == .empty)
        #expect(CodexComposer.isWorking(pane) == false)
        #expect(CodexComposer.canNudge(pane) == true)
    }

    // A user draft in the composer → defer.
    @Test("draft in composer → canNudge false, composer .draft")
    func draftDefers() {
        let pane = """
        ● Ran the tests — all green.

        › let me think before I answer
        """
        #expect(CodexComposer.composer(pane) == .draft("let me think before I answer"))
        #expect(CodexComposer.canNudge(pane) == false)
    }

    // A turn is streaming (interrupt hint present) even with an empty composer → defer (not idle).
    @Test("in-flight turn (esc to interrupt) → canNudge false even with empty composer")
    func workingDefers() {
        let pane = """
        ● Thinking… (Esc to interrupt)

        ›
        """
        #expect(CodexComposer.isWorking(pane) == true)
        #expect(CodexComposer.canNudge(pane) == false)
    }

    // No composer marker located → we can't confirm empty → conservative defer.
    @Test("no composer line found → composer .unknown → canNudge false")
    func unknownDefers() {
        let pane = "just some scrollback with no input line at all\n"
        #expect(CodexComposer.composer(pane) == .unknown)
        #expect(CodexComposer.canNudge(pane) == false)
    }

    // An empty pane (capture failed / session gone) → unknown → defer.
    @Test("empty pane → canNudge false")
    func emptyPaneDefers() {
        #expect(CodexComposer.composer("") == .unknown)
        #expect(CodexComposer.canNudge("") == false)
    }

    // A greyed placeholder in an empty composer must NOT read as a draft.
    @Test("empty-composer placeholder text is treated as empty, not a draft")
    func placeholderIsEmpty() {
        let pane = """
        ● Done.

        › Send a message
        """
        #expect(CodexComposer.composer(pane) == .empty)
        #expect(CodexComposer.canNudge(pane) == true)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter CodexComposerTests`
Expected: FAIL to compile — `cannot find 'CodexComposer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/OrchestraCore/CodexComposer.swift`:

```swift
import Foundation

/// Best-effort read of a send-keys agent's TUI composer from a captured agent pane, for the F2
/// detect-and-defer wake (C4). The send-keys nudge fires ONLY when the agent is idle AND its composer
/// is empty; anything else (a user draft, an in-flight turn, or a pane we cannot parse) DEFERS.
///
/// FRAGILE BY NATURE. This parses Codex's TUI text rendering, which drifts across versions — hence q10
/// keeps v1 on send-keys and watches upstream app-server #29922 / #28144 to eventually replace this
/// with a real control channel (`wakeTransport.controlChannel`). It is deliberately CONSERVATIVE: when
/// the composer can't be located it reports "not nudgeable" so we never fire a keystroke into an unknown
/// UI state. Focus is NOT consulted (per design: focus is not a gate). Keyed on the send-keys transport,
/// not agent identity; the marker/placeholder tables below are the only Codex-specific knobs and are the
/// documented place to tune when the TUI changes.
enum CodexComposer {

    /// Substrings Codex renders WHILE a turn is streaming; idle = none present. Lower-cased match.
    static let workingCues = ["esc to interrupt", "esc to stop", "working", "thinking", "generating"]

    /// Leading glyphs of the TUI composer input line (scanned bottom-up).
    static let promptMarkers: Set<Character> = ["›", "❯", "▌", "▶"]

    /// Greyed placeholder strings Codex shows in an EMPTY composer (they arrive as literal pane text).
    /// Normalized to `.empty` so a placeholder is not misread as a user draft. TUNE against the real TUI.
    static let emptyPlaceholders = ["send a message", "ask codex", "type a message"]

    /// The composer's content: confirmed empty, a user draft, or "couldn't find the composer line".
    enum Composer: Equatable { case empty, draft(String), unknown }

    /// Locate the composer input line (last line beginning with a prompt marker) and classify it.
    static func composer(_ pane: String) -> Composer {
        for raw in pane.split(whereSeparator: \.isNewline).reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, promptMarkers.contains(first) else { continue }
            let rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            let restLc = rest.lowercased()
            if rest.isEmpty || emptyPlaceholders.contains(where: { restLc == $0 }) { return .empty }
            return .draft(rest)
        }
        return .unknown
    }

    /// Is a turn currently streaming? (heuristic; see caveat)
    static func isWorking(_ pane: String) -> Bool {
        let lc = pane.lowercased()
        return workingCues.contains { lc.contains($0) }
    }

    /// Safe to fire the wake nudge? ONLY when idle AND the composer is confirmed empty. A draft, an
    /// in-flight turn, or an unparseable pane all DEFER (false) — the inbox stays durable for a later wake.
    static func canNudge(_ pane: String) -> Bool {
        !isWorking(pane) && composer(pane) == .empty
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter CodexComposerTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/CodexComposer.swift Tests/OrchestraCoreTests/CodexComposerTests.swift
git commit -m "feat(c4): CodexComposer idle+composer-empty heuristic (detect-and-defer)"
```

---

## Task 2: Wire the `.sendKeys` wake case (nudge-only + detect-and-defer)

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Wake.swift:56-57` (the `.sendKeys` case) and add `sendKeysWake(_:)` + `sendKeysWakeNudge`
- Modify: `Tests/OrchestraCoreTests/Stubs.swift:61-62` (StubSessions `capture`/`sendKeys`)
- Test: `Tests/OrchestraCoreTests/CodexWakeTests.swift`

**Interfaces:**
- Consumes: `CodexComposer.canNudge(_:)` (Task 1); `SessionManaging.capture(_:window:)` + `.sendKeys(_:text:window:)`; the existing `wake(_ id:)` dispatch and `Task` (`t`) already in scope.
- Produces:
  - `OrchestraService.sendKeysWake(_ t: Task) async` (internal)
  - `static let OrchestraService.sendKeysWakeNudge: String`
  - `StubSessions.setCapture(_ id: UUID, _ text: String)`, `StubSessions.keysSent(to id: UUID) -> [String]`.

- [ ] **Step 1: Extend `StubSessions` to control capture + record sendKeys**

In `Tests/OrchestraCoreTests/Stubs.swift`, inside `final class StubSessions`, add stored state near the other `private(set)` fields (after `var ensureSleepMs: UInt32 = 0` on line 37):

```swift
    private var captureText: [String: String] = [:]
    private(set) var sentKeys: [(name: String, text: String)] = []

    /// Seed the pane text `capture(_:window:)` returns for this card (drives C4 detect-and-defer).
    func setCapture(_ id: UUID, _ text: String) {
        lock.lock(); captureText[sessionName(id)] = text; lock.unlock()
    }

    /// Nudges/keystrokes sent to a card's agent window, in order (drives C4 nudge-only assertions).
    func keysSent(to id: UUID) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let n = sessionName(id)
        return sentKeys.filter { $0.name == n }.map(\.text)
    }
```

Then replace the two no-op lines (currently `Stubs.swift:61-62`):

```swift
    func capture(_ name: String, window: String) throws -> String { "" }
    func sendKeys(_ name: String, text: String, window: String) throws {}
```

with:

```swift
    func capture(_ name: String, window: String) throws -> String {
        lock.lock(); defer { lock.unlock() }; return captureText[name] ?? ""
    }
    func sendKeys(_ name: String, text: String, window: String) throws {
        lock.lock(); sentKeys.append((name, text)); lock.unlock()
    }
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/OrchestraCoreTests/CodexWakeTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("C4 · Codex send-keys wake (nudge-only; detect-and-defer)")
struct CodexWakeTests {

    /// A Claude-shaped capability tuple with the send-keys wake transport, so `wake` routes through the
    /// C4 case without dragging in Codex's discovered-session / file-tail launch behavior.
    static let sendKeysCaps = AgentCapabilities(
        sessionId: .seeded, telemetry: .hooksPush, contextUsage: .percent,
        wakeTransport: .sendKeys, inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed, authMode: .subscription)

    // Idle + empty composer → the fixed nudge is sent exactly once.
    @Test("wake nudges when the card is idle and the composer is empty")
    func nudgesWhenIdleAndEmpty() async throws {
        let env = TestEnv.make(capabilities: Self.sendKeysCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        env.sessions.setCapture(card.id, "● Done.\n\n›\n")

        await env.svc.wake(card.id)

        #expect(env.sessions.keysSent(to: card.id) == [OrchestraService.sendKeysWakeNudge])
    }

    // A user draft in the composer → defer (no keystroke).
    @Test("wake defers (no nudge) when the composer holds a draft")
    func defersOnDraft() async throws {
        let env = TestEnv.make(capabilities: Self.sendKeysCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        env.sessions.setCapture(card.id, "● Done.\n\n› half-written question")

        await env.svc.wake(card.id)

        #expect(env.sessions.keysSent(to: card.id).isEmpty)
    }

    // A turn is streaming → defer even though the composer is empty (idle is a gate; focus is not).
    @Test("wake defers when a turn is in flight (not idle)")
    func defersWhenBusy() async throws {
        let env = TestEnv.make(capabilities: Self.sendKeysCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        env.sessions.setCapture(card.id, "● Thinking… (Esc to interrupt)\n\n›\n")

        await env.svc.wake(card.id)

        #expect(env.sessions.keysSent(to: card.id).isEmpty)
    }

    // An unreadable pane (capture empty / no composer marker) → conservative defer.
    @Test("wake defers when the pane can't be parsed")
    func defersWhenPaneUnreadable() async throws {
        let env = TestEnv.make(capabilities: Self.sendKeysCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        // No setCapture → StubSessions.capture returns "".

        await env.svc.wake(card.id)

        #expect(env.sessions.keysSent(to: card.id).isEmpty)
    }

    // NUDGE-ONLY: inbox content is NEVER delivered via keystroke — only the fixed nudge is sent.
    @Test("the nudge carries no inbox content (content rides F3, not keys)")
    func nudgeCarriesNoContent() async throws {
        let env = TestEnv.make(capabilities: Self.sendKeysCaps)
        let repo = TestEnv.repo(env.base)
        let card = try await env.svc.spawn(SpawnInput(prompt: "c", repo: repo, branch: "c"))
        let marker = "SECRET-INBOX-PAYLOAD-ac91"
        try await env.svc.send(card.id, marker)          // durable inbox content (F3), not a keystroke
        env.sessions.setCapture(card.id, "● Done.\n\n›\n")

        await env.svc.wake(card.id)

        let sent = env.sessions.keysSent(to: card.id)
        #expect(sent == [OrchestraService.sendKeysWakeNudge])
        #expect(sent.allSatisfy { !$0.contains(marker) })   // content did NOT ride the keystroke
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter CodexWakeTests`
Expected: FAIL — `type 'OrchestraService' has no member 'sendKeysWakeNudge'` (and the idle/nudge cases fail: the `.sendKeys` case is still a `break`, so nothing is sent).

- [ ] **Step 4: Implement the `.sendKeys` wake case**

In `Sources/OrchestraCore/OrchestraService+Wake.swift`, replace the `.sendKeys` case body (currently line 57):

```swift
        case .sendKeys:
            break   // Codex send-keys nudge + detect-and-defer — C4 (deferred; nudge only, no content).
```

with:

```swift
        case .sendKeys:
            await sendKeysWake(t)
```

Then, still inside `extension OrchestraService`, add the constant + method (place them right after `wake(_:)`, before `isConcluded(_:)`):

```swift
    /// The FIXED, content-free wake keystroke for send-keys agents (Codex TUI). Its ONLY job is to
    /// start a turn on an idle composer. Inbox payloads NEVER ride this keystroke — content is delivered
    /// by F3 (the durable inbox / session seed), so this stays a constant and carries no message content.
    public static let sendKeysWakeNudge = "Please continue."

    /// F2 wake for a send-keys agent (Codex TUI): NUDGE-ONLY + detect-and-defer.
    /// Fire the fixed nudge ONLY when the card is idle AND its composer is empty, read just-in-time from
    /// `capture-pane` (this single capture IS the "re-check right before the nudge"; focus is NOT a gate).
    /// A draft, an in-flight turn, an unparseable pane, or a dead session all DEFER — we drop the nudge
    /// and leave the inbox durable; a later event-driven wake / turn-end delivers it. No retry loop here
    /// (that would risk the F3 inject cap). Content is never sent — only `sendKeysWakeNudge`.
    func sendKeysWake(_ t: Task) async {
        let name = sessions.sessionName(t.id)
        guard (try? sessions.isAlive(name)) == true else { return }   // no live TUI → inbox stays durable
        let pane = (try? sessions.capture(name, window: "agent")) ?? ""
        guard CodexComposer.canNudge(pane) else { return }            // draft / busy / unknown → defer
        try? sessions.sendKeys(name, text: Self.sendKeysWakeNudge, window: "agent")
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter CodexWakeTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Run the C2 wake suite to prove no regression**

Run: `./scripts/test.sh --filter WakeMergeWatchTests`
Expected: PASS (unchanged — the `.nativeReinvoke` path and merge-watch are untouched).

- [ ] **Step 7: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Wake.swift Tests/OrchestraCoreTests/Stubs.swift Tests/OrchestraCoreTests/CodexWakeTests.swift
git commit -m "feat(c4): Codex send-keys wake — nudge-only + detect-and-defer"
```

---

## Task 3: Full green + typecheck + advisory e2e

**Files:** none (verification only).

- [ ] **Step 1: Full unit suite (unsandboxed shell — swift build needs it)**

Run: `./scripts/test.sh`
Expected: PASS. KNOWN FLAKE: if `RecoveryTests "resume success: confirmed within grace"` is the ONLY failure, re-run `./scripts/test.sh --filter RecoveryTests` to confirm it passes in isolation, then treat green.

- [ ] **Step 2: App typecheck (self-pins CLT via scripts/toolchain.sh; no DEVELOPER_DIR)**

Run: `./scripts/typecheck-app.sh`
Expected: PASS.

- [ ] **Step 3: Advisory UX e2e (O6 — not a merge gate)**

Run: `./scripts/orch-ux-e2e.sh --run-id c4wake`
Expected: passes, OR the screenshot step fails on a headless/locked window server — that is environmental (O6/P2), not a defect. The unit tests + typecheck are the gate.

- [ ] **Step 4: Move to `review` and report**

Do NOT merge/archive. Move the card to `review` and report: `DONE: live/04-codex-wake — tests green` plus a one-liner. The orchestrator merges.

---

## Self-Review

**1. Spec coverage** (C4 row + 04-tests "Codex send-keys wake" + edge cases):
- "wake only when idle+composer-empty" → `CodexWakeTests.nudgesWhenIdleAndEmpty` + `CodexComposerTests.idleEmpty`. ✓
- "defer on draft (stub capture-pane)" → `defersOnDraft` + `CodexComposerTests.draftDefers`. ✓
- "nudge-only (no content via keys)" → `nudgeCarriesNoContent`. ✓
- "composer detection + its fragility" → `CodexComposer` doc comment + `promptMarkers`/`emptyPlaceholders`/`workingCues` knobs + unknown/placeholder/busy tests. ✓
- "defer-retry" → documented (event-driven, no timer); `defersWhenBusy` / `defersWhenPaneUnreadable` prove the drop. ✓
- "Focus is NOT a gate" → `sendKeysWake` never reads focus; documented. ✓
- "Re-check right before the nudge" → single just-in-time `capture` immediately precedes `sendKeys`; documented. ✓
- "stop_hook_active informational → respect inject/loop cap" → no retry loop added; documented (cap is C1's). ✓

**2. Placeholder scan:** No `TBD`/`handle edge cases`/"write tests for the above" — every step has concrete code. ✓

**3. Type consistency:** `CodexComposer.canNudge(_:)`, `.composer(_:) -> Composer`, `.isWorking(_:)` used identically in Task 1 and Task 2. `OrchestraService.sendKeysWakeNudge` (public static) referenced in tests. `StubSessions.setCapture`/`keysSent` defined in Task 2 Step 1, used in Step 2. `sendKeysWake(_ t: Task)` matches the `wake` call `await sendKeysWake(t)`. ✓
