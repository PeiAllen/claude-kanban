# PR D2 — Constrained `send-keys` RPC (key schema) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a typed, constrained key-send API — a `KeyName` schema (Esc, arrows, Tab, Enter, C-c, PgUp/PgDn, Home/End, plus literal text) → `SessionManager.sendChord` → a `send-keys` RPC verb → a `ControlClient` method + CLI subcommand — distinct from the inbox `send`, for later use by captured-prompt semantic buttons (Codex) and non-live fallbacks.

**Architecture:** A new client-safe value model (`KeyName` enum + `KeyToken` chord element) describes an ordered list of keystrokes on the wire. The daemon's `SessionManager` maps each token to a `tmux send-keys` invocation (named key → tmux key token; literal text → `-l -- text`). A new `send-keys` command in the canonical `CommandRegistry` decodes the chord, validates it, and delegates to `OrchestraService.sendChord`, which forwards to `SessionManager`. Because the model is added to `OrchestraCore` as a **pure-Swift, `Foundation.Process`-free file**, PR F1 later relocates it into `OrchestraKit` verbatim so the iOS client can build chords. Crucially there is **no implicit Enter** — Enter is an explicit token — which is exactly what separates this from the line-only `sendKeys` and the inbox `send`.

**Tech Stack:** Swift 6 / SwiftPM, tmux (`-L orchestra`, named keys), Swift Testing (`@Suite`/`@Test`), real-tmux integration tests gated on `IntegrationSupport.tmuxAvailable`.

## Global Constraints

- **Design for every agent (Claude AND Codex).** No `if agent == "claude"` branches; the key schema is agent-agnostic (it drives whatever TUI is in the pane).
- **Daemon wire protocol changes stay minimal.** One additive verb (`send-keys`) + one additive value model. No changes to existing verbs; no TCP/WebSocket; no daemon PTY byte-proxy.
- **Do not regress the desktop or the Linux daemon build.** `swift build` / `swift test` must stay offline-green; `scripts/build-app.sh` (macOS) and `scripts/build-linux-daemon.sh` must keep working.
- **Do not overload the message `send`.** `send` stays the inbox-queue verb; `send-keys` is a separate explicit-schema verb.
- **Preserve the existing line-only path.** `SessionManager.sendKeys(_:text:window:)` (its only caller is `OrchestraService.inspect`) is left byte-for-byte unchanged.
- **Client-safe placement.** The `KeyName`/`KeyToken` model must contain **zero** `Foundation.Process` / AppKit / daemon references so PR F1 can move it into `OrchestraKit` unchanged. (Note: at D2 build time `OrchestraKit` does not exist yet — D2 has no dependency on F1 — so the model lands in `Sources/OrchestraCore/` in a self-contained file that F1 relocates.)
- **Small commits.** One commit per task.

---

## Background: what already exists (from the 2026-07-04 audit)

- `SessionManager.sendKeys(_ name:text:window:)` — `Sources/OrchestraCore/SessionManager.swift:145`. **INTERNAL, line-only** (sends literal text then `Enter`, two tmux calls). Its **only** caller is `OrchestraService.inspect` (`OrchestraService.swift:558`). There is **no** RPC verb exposing it. Leave it untouched.
- `send` RPC — `Commands.swift:79` → `OrchestraService.send` (`OrchestraService.swift:353`) queues to the **durable inbox** and `wake`s the card. This is NOT live keystrokes. Do not touch.
- Command pattern — every verb is a `Command` in `CommandRegistry.build()` (`Commands.swift:26`), delegating to `OrchestraService` via a `@Sendable` closure `(OrchestraService, JSONValue, ActivitySource) async throws -> JSONValue`. The MCP bridge (`orchestra-mcp/main.swift:29`) and CLI both generate from this one registry — **the MCP tool appears automatically**; only the CLI needs an explicit `switch` case.
- Schema builders — `CommandRegistry.schema/strProp/refProp` (`Commands.swift:308-336`).
- Param access — `JSONValue.string`/`optString`/`arrayValue`/`decode<T>` (`JSONValue.swift:48,74,77,81`).
- Client calls — clients use the generic `ControlClient.call(_ method:_ params:)` (`ControlClient.swift:75`); no per-verb convenience methods exist yet. The forest asks for a `ControlClient` method, so we add one `sendKeys` convenience.
- Real-tmux test harness — `Tests/IntegrationTests/SessionManagerTests.swift` (unique per-suite socket, `deinit` kills the server, `IntegrationSupport.tmuxAvailable`/`tempDir`). New pane-reaction tests follow this exact shape. Fixtures live in `Tests/IntegrationTests/Fixtures/` and auto-bundle via `resources: [.copy("Fixtures")]` in `Package.swift`.
- `OrchestraError.invalidParams(String)` / `.io(String)` (`Errors.swift:14-15`); `JSONValue.ok()` (`JSONValue.swift:84`).

---

## File Structure

**Create:**
- `Sources/OrchestraCore/KeyName.swift` — client-safe value model: `enum KeyName` (wire vocabulary `Esc`/`Up`/… + `tmuxToken` mapping) and `enum KeyToken` (`.named(KeyName)` | `.text(String)`, Codable wire form `{key:…}`/`{text:…}`). Pure Swift, no `Foundation.Process`. **F1 moves this file into `OrchestraKit` unchanged.**
- `Tests/OrchestraCoreTests/KeyNameTests.swift` — pure unit tests for the model (rawValue/token mapping, Codable round-trip, invalid-key rejection).
- `Tests/IntegrationTests/Fixtures/menu.sh` — tiny arrow-driven selector fixture used to assert arrow + Enter semantics against real tmux.

**Modify:**
- `Sources/OrchestraCore/SessionManager.swift` — add `sendChord(_ name:tokens:window:)` (leave `sendKeys` untouched).
- `Sources/OrchestraCore/OrchestraService.swift` — add `sendChord(_ id:tokens:window:)`.
- `Sources/OrchestraCore/Commands.swift` — add the `send-keys` `Command` (decode + validate `keys`, optional `window`).
- `Sources/OrchestraCore/Control/ControlClient.swift` — add `sendKeys(ref:_ chord:window:)` convenience over `call`.
- `Sources/orchestra/CLIRunner.swift` — add a `send-keys` `case`.
- `Sources/orchestra/CLIHelp.swift` — add the `send-keys` help line.
- `Tests/IntegrationTests/SessionManagerTests.swift` — add real-tmux pane-reaction tests for `sendChord`.
- `Tests/OrchestraCoreTests/OrchestraServiceTests.swift` (or a new `SendKeysCommandTests.swift`) — command-level param validation tests.

---

## Wire contract (single source of truth for all tasks)

RPC verb `send-keys`:

```jsonc
// request params
{
  "ref":  "<card ref: UUID | shortId | orchestra://task/<ref>>",
  "keys": [ {"key": "Up"}, {"key": "Up"}, {"text": "y"}, {"key": "Enter"} ],
  "window": "agent"        // optional, default "agent"
}
// response
{ "ok": true }
```

- `keys` is an **ordered** array of chord elements. Each element is exactly one of `{"key": <KeyName>}` or `{"text": <literal>}`. An element with neither, both, an unknown key name, or empty text is rejected with `invalidParams`.
- `KeyName` wire vocabulary (the exact rawValues the phone sends): `Esc`, `Up`, `Down`, `Left`, `Right`, `Tab`, `Enter`, `C-c`, `PgUp`, `PgDn`, `Home`, `End`.
- **No implicit Enter.** Submitting requires an explicit `{"key":"Enter"}`. Literal text is sent raw (`tmux send-keys -l -- <text>`), named keys as tmux key tokens.

---

## Task 1: `KeyName` + `KeyToken` client-safe value model

**Files:**
- Create: `Sources/OrchestraCore/KeyName.swift`
- Test: `Tests/OrchestraCoreTests/KeyNameTests.swift`

**Interfaces:**
- Produces:
  - `public enum KeyName: String, Sendable, Codable, CaseIterable, Equatable` with cases `esc, up, down, left, right, tab, enter, ctrlC, pageUp, pageDown, home, end` and rawValues `"Esc","Up","Down","Left","Right","Tab","Enter","C-c","PgUp","PgDn","Home","End"`.
  - `public var tmuxToken: String` on `KeyName` (the token passed to `tmux send-keys`).
  - `public enum KeyToken: Sendable, Equatable, Codable` with `case named(KeyName)` and `case text(String)`, encoding to `{"key": <rawValue>}` / `{"text": <string>}`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/KeyNameTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("KeyName + KeyToken value model")
struct KeyNameTests {

    @Test("wire rawValues match the agreed vocabulary")
    func rawValues() {
        #expect(KeyName.esc.rawValue == "Esc")
        #expect(KeyName.ctrlC.rawValue == "C-c")
        #expect(KeyName.pageUp.rawValue == "PgUp")
        #expect(KeyName.pageDown.rawValue == "PgDn")
        #expect(KeyName(rawValue: "Up") == .up)
        #expect(KeyName(rawValue: "nope") == nil)
        // Every case is round-trippable through its rawValue.
        for k in KeyName.allCases { #expect(KeyName(rawValue: k.rawValue) == k) }
    }

    @Test("tmux tokens map wire names to tmux key names")
    func tmuxTokens() {
        #expect(KeyName.esc.tmuxToken == "Escape")
        #expect(KeyName.up.tmuxToken == "Up")
        #expect(KeyName.ctrlC.tmuxToken == "C-c")
        #expect(KeyName.pageUp.tmuxToken == "PPage")
        #expect(KeyName.pageDown.tmuxToken == "NPage")
        #expect(KeyName.home.tmuxToken == "Home")
        #expect(KeyName.end.tmuxToken == "End")
    }

    @Test("KeyToken decodes the wire form for named keys and literal text")
    func decodeTokens() throws {
        let named = try JSONValue.object(["key": .string("Enter")]).decode(KeyToken.self)
        #expect(named == .named(.enter))
        let text = try JSONValue.object(["text": .string("hi")]).decode(KeyToken.self)
        #expect(text == .text("hi"))
    }

    @Test("KeyToken round-trips through JSON")
    func roundTrip() throws {
        let chord: [KeyToken] = [.text("y"), .named(.enter)]
        let json = try JSONValue(encodable: chord)
        let back = try json.decode([KeyToken].self)
        #expect(back == chord)
    }

    @Test("an unknown key name fails to decode")
    func rejectUnknownKey() {
        #expect(throws: (any Error).self) {
            try JSONValue.object(["key": .string("F13")]).decode(KeyToken.self)
        }
    }

    @Test("an element with neither key nor text fails to decode")
    func rejectEmptyToken() {
        #expect(throws: (any Error).self) {
            try JSONValue.object([:]).decode(KeyToken.self)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeyNameTests`
Expected: FAIL — `cannot find 'KeyName' in scope` / `cannot find 'KeyToken' in scope`.

- [ ] **Step 3: Write the model**

Create `Sources/OrchestraCore/KeyName.swift`:

```swift
// Client-safe key-input value model. NOTE: this file must stay free of Foundation.Process /
// AppKit / daemon types so PR F1 can relocate it into OrchestraKit unchanged (the iOS client
// builds KeyChords from it). Only the daemon's SessionManager reads `tmuxToken`.

/// A named special key in the constrained send-keys vocabulary. The rawValue is the wire name the
/// phone sends; `tmuxToken` is the corresponding `tmux send-keys` key name.
public enum KeyName: String, Sendable, Codable, CaseIterable, Equatable {
    case esc      = "Esc"
    case up       = "Up"
    case down     = "Down"
    case left     = "Left"
    case right    = "Right"
    case tab      = "Tab"
    case enter    = "Enter"
    case ctrlC    = "C-c"
    case pageUp   = "PgUp"
    case pageDown = "PgDn"
    case home     = "Home"
    case end      = "End"

    /// The token passed to `tmux send-keys` (tmux's own key-name vocabulary).
    public var tmuxToken: String {
        switch self {
        case .esc:      return "Escape"
        case .up:       return "Up"
        case .down:     return "Down"
        case .left:     return "Left"
        case .right:    return "Right"
        case .tab:      return "Tab"
        case .enter:    return "Enter"
        case .ctrlC:    return "C-c"
        case .pageUp:   return "PPage"
        case .pageDown: return "NPage"
        case .home:     return "Home"
        case .end:      return "End"
        }
    }
}

/// One element of a key chord: either a named special key or a run of literal text. A `send-keys`
/// request is an ordered `[KeyToken]`. There is deliberately no implicit Enter — Enter is `.named(.enter)`.
public enum KeyToken: Sendable, Equatable, Codable {
    case named(KeyName)
    case text(String)

    private enum CodingKeys: String, CodingKey { case key, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let key = try c.decodeIfPresent(KeyName.self, forKey: .key)
        let text = try c.decodeIfPresent(String.self, forKey: .text)
        switch (key, text) {
        case let (k?, nil): self = .named(k)
        case let (nil, t?): self = .text(t)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "each keys[] element needs exactly one of `key` or `text`"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .named(let k): try c.encode(k, forKey: .key)
        case .text(let t):  try c.encode(t, forKey: .text)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter KeyNameTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/KeyName.swift Tests/OrchestraCoreTests/KeyNameTests.swift
git commit -m "feat(d2): add client-safe KeyName + KeyToken value model"
```

---

## Task 2: `SessionManager.sendChord` + real-tmux pane-reaction tests

This task carries the PR's core acceptance: each named key reaches the pane as a key (not literal text), and the literal-text path is preserved.

**Files:**
- Modify: `Sources/OrchestraCore/SessionManager.swift` (add `sendChord`; `sendKeys:145` stays unchanged)
- Create: `Tests/IntegrationTests/Fixtures/menu.sh`
- Test: `Tests/IntegrationTests/SessionManagerTests.swift` (add tests + a capture-pane poll helper)

**Interfaces:**
- Consumes: `KeyName`, `KeyToken` (Task 1); existing `SessionManager.isAlive`, `tmux(_:)`.
- Produces: `public func sendChord(_ name: String, tokens: [KeyToken], window: String = "agent") throws`.

- [ ] **Step 1: Add the menu fixture**

Create `Tests/IntegrationTests/Fixtures/menu.sh` (arrow-driven selector; renders `SELECTED=<label>` after each key and `CHOSE=<label>` on Enter). Run via `bash <path>` so no exec bit is required:

```bash
#!/usr/bin/env bash
# menu.sh — a tiny arrow-key selector used to assert send-keys Up/Down/Enter semantics.
# Reads raw keystrokes; redraws SELECTED=<label> on each arrow; prints CHOSE=<label> on Enter.
set -u
labels=(ALPHA BRAVO CHARLIE)
sel=0
draw() { printf '\rSELECTED=%s   ' "${labels[$sel]}"; }
draw
while true; do
  IFS= read -rsn1 c || continue
  if [ "$c" = $'\x1b' ]; then          # ESC — start of an arrow sequence
    read -rsn2 rest
    case "$rest" in
      '[A'|'OA') [ "$sel" -gt 0 ] && sel=$((sel-1)) ;;   # Up
      '[B'|'OB') [ "$sel" -lt 2 ] && sel=$((sel+1)) ;;   # Down
    esac
  elif [ -z "$c" ]; then               # read strips the trailing newline → empty == Enter
    printf '\nCHOSE=%s\n' "${labels[$sel]}"
    exit 0
  fi
  draw
done
```

- [ ] **Step 2: Write the failing tests**

Append to `Tests/IntegrationTests/SessionManagerTests.swift` (inside the existing `SessionManagerTests` class). Add a bounded capture-pane poll helper and four tests:

```swift
    // MARK: - send-keys (D2)

    /// Poll `capture-pane -p` until it contains `needle` or the attempt budget runs out.
    /// Pane reactions are asynchronous (the program processes the key after tmux delivers it),
    /// so assertions poll rather than read once. Returns the last capture for failure messages.
    @discardableResult
    private func waitForPane(_ target: String, contains needle: String,
                             attempts: Int = 40) throws -> String {
        var last = ""
        for _ in 0..<attempts {
            let r = try Proc.run(["tmux", "-L", socket, "capture-pane", "-p", "-t", target])
            last = r.stdout
            if last.contains(needle) { return last }
            _ = try? Proc.run(["sleep", "0.1"])
        }
        return last
    }

    private var menuFixturePath: String {
        Bundle.module.path(forResource: "Fixtures/menu", ofType: "sh")
            ?? Bundle.module.path(forResource: "menu", ofType: "sh") ?? ""
    }

    @Test("literal text token types into the pane; Enter token submits it")
    func chordTextThenEnter() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        // A plain interactive shell in the agent window.
        let (name, _) = try sm.ensure(task, argv: ["/bin/sh"])
        let target = "\(name):agent"

        // Text alone must NOT submit — no output yet, just the typed line.
        try sm.sendChord(name, tokens: [.text("echo D2_SUBMIT_OK")])
        // Now the explicit Enter token submits it.
        try sm.sendChord(name, tokens: [.named(.enter)])
        let pane = try waitForPane(target, contains: "D2_SUBMIT_OK")
        // The echoed *output* line appears (the command actually ran).
        #expect(pane.contains("D2_SUBMIT_OK"))
        try sm.kill(name)
    }

    @Test("C-c interrupts a running foreground command")
    func chordCtrlCInterrupts() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        let (name, _) = try sm.ensure(task, argv: ["/bin/sh"])
        let target = "\(name):agent"

        // Block the shell on a long sleep.
        try sm.sendChord(name, tokens: [.text("sleep 30")])
        try sm.sendChord(name, tokens: [.named(.enter)])
        // Interrupt it, then prove the shell is interactive again.
        try sm.sendChord(name, tokens: [.named(.ctrlC)])
        try sm.sendChord(name, tokens: [.text("echo BACK_ALIVE")])
        try sm.sendChord(name, tokens: [.named(.enter)])
        let pane = try waitForPane(target, contains: "BACK_ALIVE")
        // If C-c had NOT interrupted, the shell would still be blocked on sleep and never echo.
        #expect(pane.contains("BACK_ALIVE"))
        try sm.kill(name)
    }

    @Test("arrow keys move a menu selection; Enter chooses it")
    func chordArrowsMoveMenu() throws {
        #expect(!menuFixturePath.isEmpty)
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        // Run the menu fixture as the agent-window program.
        let (name, _) = try sm.ensure(task, argv: ["bash", menuFixturePath])
        let target = "\(name):agent"
        _ = try waitForPane(target, contains: "SELECTED=ALPHA")   // initial render

        try sm.sendChord(name, tokens: [.named(.down)])          // ALPHA -> BRAVO
        _ = try waitForPane(target, contains: "SELECTED=BRAVO")
        try sm.sendChord(name, tokens: [.named(.down)])          // BRAVO -> CHARLIE
        _ = try waitForPane(target, contains: "SELECTED=CHARLIE")
        try sm.sendChord(name, tokens: [.named(.up)])            // CHARLIE -> BRAVO
        _ = try waitForPane(target, contains: "SELECTED=BRAVO")
        try sm.sendChord(name, tokens: [.named(.enter)])         // choose BRAVO
        let pane = try waitForPane(target, contains: "CHOSE=BRAVO")
        #expect(pane.contains("CHOSE=BRAVO"))
        try sm.kill(name)
    }

    @Test("sendChord on a dead session throws")
    func chordDeadSession() throws {
        #expect(throws: OrchestraError.self) {
            try sm.sendChord("orchestra-does-not-exist", tokens: [.named(.enter)])
        }
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter SessionManagerTests`
Expected: FAIL — `value of type 'SessionManager' has no member 'sendChord'`.

- [ ] **Step 4: Implement `sendChord`**

In `Sources/OrchestraCore/SessionManager.swift`, add immediately after `sendKeys` (after line 152, before `kill`):

```swift
    /// Send a constrained key chord to a window — an ordered mix of named special keys and literal
    /// text runs. Distinct from `sendKeys` (line-only) and the inbox `send`: named keys are delivered
    /// as tmux key tokens (`Escape`, `Up`, `C-c`, …) and text as raw bytes; there is NO implicit Enter,
    /// so submitting requires an explicit `.named(.enter)` token.
    public func sendChord(_ name: String, tokens: [KeyToken], window: String = "agent") throws {
        guard try isAlive(name) else { throw OrchestraError.io("session not alive: \(name)") }
        let target = "\(name):\(window)"
        for token in tokens {
            switch token {
            case .named(let key):
                _ = try tmux(["send-keys", "-t", target, key.tmuxToken])
            case .text(let text):
                // `-l` = literal; `--` ends option parsing so text starting with `-` isn't swallowed.
                _ = try tmux(["send-keys", "-t", target, "-l", "--", text])
            }
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SessionManagerTests`
Expected: PASS (existing tests + 4 new; skipped entirely if tmux is unavailable).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/SessionManager.swift Tests/IntegrationTests/SessionManagerTests.swift Tests/IntegrationTests/Fixtures/menu.sh
git commit -m "feat(d2): SessionManager.sendChord + real-tmux pane-reaction tests"
```

---

## Task 3: `OrchestraService.sendChord` + `send-keys` command verb

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add `sendChord`)
- Modify: `Sources/OrchestraCore/Commands.swift` (add the `send-keys` `Command`)
- Test: `Tests/OrchestraCoreTests/SendKeysCommandTests.swift` (new — param validation, no tmux)

**Interfaces:**
- Consumes: `KeyToken` (Task 1), `SessionManager.sendChord` (Task 2), existing `require(_:)`, `sessions` (the `SessionManager` property), `logCommand`, `resolveRef`.
- Produces:
  - `public func sendChord(_ id: UUID, tokens: [KeyToken], window: String) async throws` on `OrchestraService`.
  - Registry command `send-keys` with params `{ref, keys, window?}` returning `.ok()`.

- [ ] **Step 1: Write the failing param-validation tests**

Create `Tests/OrchestraCoreTests/SendKeysCommandTests.swift`. These exercise the command's decode/validation branches without touching tmux — a bad chord must be rejected before any session work.

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("send-keys command — param validation")
struct SendKeysCommandTests {

    private func command() -> Command {
        let cmd = CommandRegistry().command("send-keys")
        #expect(cmd != nil)
        return cmd!
    }

    @Test("registry exposes send-keys with ref + keys required")
    func registered() throws {
        let cmd = command()
        #expect(cmd.name == "send-keys")
        let required = cmd.params["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required.contains("ref"))
        #expect(required.contains("keys"))
    }

    @Test("empty keys array is rejected")
    func rejectsEmptyKeys() async {
        let svc = TestSupport.service()   // in-memory service, no real card needed — fails before session work
        let params = JSONValue.object(["ref": .string("nonexistent"), "keys": .array([])])
        await #expect(throws: (any Error).self) {
            _ = try await command().run(svc, params, .cli)
        }
    }

    @Test("a keys element with an empty text run is rejected")
    func rejectsEmptyText() async {
        let svc = TestSupport.service()
        let params = JSONValue.object([
            "ref": .string("nonexistent"),
            "keys": .array([.object(["text": .string("")])]),
        ])
        await #expect(throws: (any Error).self) {
            _ = try await command().run(svc, params, .cli)
        }
    }

    @Test("an unknown key name is rejected")
    func rejectsUnknownKey() async {
        let svc = TestSupport.service()
        let params = JSONValue.object([
            "ref": .string("nonexistent"),
            "keys": .array([.object(["key": .string("F13")])]),
        ])
        await #expect(throws: (any Error).self) {
            _ = try await command().run(svc, params, .cli)
        }
    }
}
```

> **Implementer note:** use whatever in-memory `OrchestraService` factory the existing `OrchestraCoreTests` already use (grep the suite for how `OrchestraServiceTests` builds its `svc`; reuse that helper instead of `TestSupport.service()` if the name differs). The point of these tests is that validation happens **before** any session lookup, so an unresolvable ref still surfaces the validation error first. If the codebase resolves the ref before validating, reorder the handler (validate `keys` first) so these tests hold.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SendKeysCommandTests`
Expected: FAIL — `command("send-keys")` returns nil (`cmd != nil` fails / force-unwrap traps).

- [ ] **Step 3: Add the service method**

In `Sources/OrchestraCore/OrchestraService.swift`, add next to `send` (after the `send` method, ~line 365):

```swift
    /// Send a constrained key chord to one of the card's tmux windows (default `agent`). Unlike
    /// `send` (which queues to the durable inbox), this delivers live keystrokes — used by the phone's
    /// captured-prompt semantic buttons and non-live steering fallbacks. Validation of the chord itself
    /// happens at the command boundary; here we just require a live card and forward to the session.
    public func sendChord(_ id: UUID, tokens: [KeyToken], window: String) async throws {
        let t = try await require(id)
        try sessions.sendChord(sessions.sessionName(t.id), tokens: tokens, window: window)
    }
```

- [ ] **Step 4: Add the `send-keys` command**

In `Sources/OrchestraCore/Commands.swift`, add a new `Command` to the array in `build()` — place it right after the `send` command (after line 86). Note the schema describes `keys` as an array of `{key|text}` objects and validation rejects bad chords **before** resolving the ref:

```swift
            Command(name: "send-keys",
                    summary: "Send live keystrokes to a card's tmux window — an ordered chord of named "
                        + "keys (Esc, Up/Down/Left/Right, Tab, Enter, C-c, PgUp/PgDn, Home/End) and/or "
                        + "literal text. Distinct from `send` (inbox queue): no implicit Enter.",
                    params: schema([
                        "ref": refProp(),
                        "keys": .object([
                            "type": .string("array"),
                            "description": .string(
                                "Ordered chord elements; each is {\"key\": <name>} (Esc, Up, Down, Left, "
                                + "Right, Tab, Enter, C-c, PgUp, PgDn, Home, End) or {\"text\": <literal>}."),
                        ]),
                        "window": strProp("Target window (default 'agent')"),
                    ], required: ["ref", "keys"])) { svc, p, src in
                // Decode + validate the chord BEFORE any session work so a bad request fails cleanly.
                guard let arr = p["keys"]?.arrayValue, !arr.isEmpty else {
                    throw OrchestraError.invalidParams("keys must be a non-empty array")
                }
                let tokens = try (p["keys"] ?? .array([])).decode([KeyToken].self)
                for token in tokens {
                    if case .text(let s) = token, s.isEmpty {
                        throw OrchestraError.invalidParams("keys text elements must be non-empty")
                    }
                }
                let t = try await svc.resolveRef(try p.string("ref"))
                try await svc.sendChord(t.id, tokens: tokens, window: p.optString("window") ?? "agent")
                await svc.logCommand("send-keys", ref: t, source: src)
                return .ok()
            },
```

> **Ordering note:** `.decode([KeyToken].self)` throws on an unknown key name or a `{}`/both-fields element (Task 1's `KeyToken.init(from:)`), and the explicit `arr.isEmpty` / empty-text checks cover the rest — all before `resolveRef`, so the Task 3 validation tests pass regardless of whether the ref exists.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter SendKeysCommandTests`
Expected: PASS.

- [ ] **Step 6: Full suite — no regressions**

Run: `swift test`
Expected: PASS (all suites; tmux-gated ones run if tmux is present).

- [ ] **Step 7: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/Commands.swift Tests/OrchestraCoreTests/SendKeysCommandTests.swift
git commit -m "feat(d2): send-keys command verb + OrchestraService.sendChord"
```

---

## Task 4: `ControlClient.sendKeys` convenience + CLI `send-keys` subcommand

The verb is already MCP-exposed automatically (the MCP bridge generates tools from the registry). This task adds the client-side convenience the forest calls for and a CLI entry point so the acceptance path is drivable end-to-end through the daemon.

**Files:**
- Modify: `Sources/OrchestraCore/Control/ControlClient.swift` (add `sendKeys`)
- Modify: `Sources/orchestra/CLIRunner.swift` (add a `send-keys` case)
- Modify: `Sources/orchestra/CLIHelp.swift` (add a help line)

**Interfaces:**
- Consumes: `KeyToken` (Task 1), `ControlClient.call` (`ControlClient.swift:75`), the `send-keys` verb (Task 3).
- Produces: `public func sendKeys(ref: String, _ chord: [KeyToken], window: String = "agent") async throws` on `ControlClient`; CLI verb `send-keys <ref> <token...>`.

- [ ] **Step 1: Add the `ControlClient` convenience**

In `Sources/OrchestraCore/Control/ControlClient.swift`, add after the generic `call<T:Decodable>` overload (after line ~100):

```swift
    /// Send a constrained key chord to a card's tmux window (default `agent`). Convenience over the
    /// `send-keys` verb — encodes the typed chord to the wire form. Distinct from queuing to the inbox.
    public func sendKeys(ref: String, _ chord: [KeyToken], window: String = "agent") async throws {
        _ = try await call("send-keys", .object([
            "ref": .string(ref),
            "keys": try JSONValue(encodable: chord),
            "window": .string(window),
        ]))
    }
```

- [ ] **Step 2: Add the CLI subcommand**

In `Sources/orchestra/CLIRunner.swift`, add a `case` inside the `switch verb` (e.g. after the `exec` case, ~line 126). It maps positional tokens to a chord: a bare token that matches a `KeyName` rawValue becomes `{key}`, anything else becomes `{text}`; `--text <str>` forces a literal:

```swift
            case "send-keys":
                let ref = flags.positional(0) ?? flags.require("ref")
                let window = flags.value("window") ?? "agent"
                // Each positional after the ref is one chord element: a known key name (Esc, Up, C-c,
                // …) becomes a named key; anything else is sent as literal text. Use --text to force
                // a token to be treated as literal even if it looks like a key name.
                var keys: [JSONValue] = []
                if let forced = flags.value("text") {
                    keys.append(.object(["text": .string(forced)]))
                }
                for tok in flags.positionalsFrom(1) {
                    if KeyName(rawValue: tok) != nil {
                        keys.append(.object(["key": .string(tok)]))
                    } else {
                        keys.append(.object(["text": .string(tok)]))
                    }
                }
                guard !keys.isEmpty else { die("send-keys needs at least one key or --text") }
                _ = try await client.call("send-keys", .object([
                    "ref": .string(ref), "keys": .array(keys), "window": .string(window),
                ]))
                print("sent-keys")
```

> **Implementer note:** confirm `Flags` exposes `positionalsFrom(_:)` (it is used by the `send` case at `CLIRunner.swift:56`) and `value(_:)`/`positional(_:)`/`require(_:)`. If `die(_:)` isn't in scope here, reuse the same failure path the neighboring cases use.

- [ ] **Step 3: Add the help line**

In `Sources/orchestra/CLIHelp.swift`, add under `send` (after line 15):

```
      send-keys <ref> <key|text...> [--text <literal>] [--window <w>]
                                                 Send live keystrokes (Esc, Up, C-c, Enter, text …)
```

- [ ] **Step 4: Build the CLI + daemon**

Run: `swift build`
Expected: builds clean (no warnings introduced).

- [ ] **Step 5: End-to-end verification against an ISOLATED daemon**

Do **not** touch the user's live daemon. Use the project's disposable-daemon harness (see the `Orchestra isolated testing` memory / `scripts/orch-test.sh`) which runs an isolated `orchestrad` on its own `HOME` + tmux socket. Drive the new verb through the CLI against that instance and assert the pane reacts. Sketch of the manual check the harness should perform:

```bash
# inside the isolated harness (own ORCHESTRA_SOCK + tmux -L):
#   1. spawn a scratch card running an interactive shell in its agent window
#   2. orchestra send-keys <ref> "echo E2E_OK"      # literal text, no submit
#   3. orchestra send-keys <ref> Enter               # explicit submit
#   4. capture the agent pane and assert it contains E2E_OK
#   5. orchestra send-keys <ref> "sleep 30" Enter C-c "echo BACK" Enter
#      -> pane contains BACK  (proves C-c interrupted via the RPC path)
#   6. tear down the isolated daemon + tmux server
```

Expected: the isolated pane shows `E2E_OK` and `BACK`; the live daemon and the user's sessions are untouched.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Control/ControlClient.swift Sources/orchestra/CLIRunner.swift Sources/orchestra/CLIHelp.swift
git commit -m "feat(d2): ControlClient.sendKeys convenience + CLI send-keys verb"
```

---

## Task 5: Regression sweep + build parity

**Files:** none (verification only).

- [ ] **Step 1: Offline unit + integration suite**

Run: `swift test`
Expected: all suites PASS; tmux-gated suites run (if tmux present) including the new `sendChord` pane tests.

- [ ] **Step 2: Linux daemon cross-build (no regression)**

Run: `scripts/build-linux-daemon.sh` (source `~/.swiftly/env.sh` first per the `Linux daemon cross-build` memory).
Expected: cross-compiles `orchestrad`/`orchestra`/`orchestra-mcp` to static Linux binaries. The new file is pure Swift + tmux argv, so it must cross-compile unchanged.

- [ ] **Step 3: macOS app build (no regression)**

Run: `scripts/build-app.sh`
Expected: the desktop app builds; D2 added no App/ code, so this is a pure "still green" check.

- [ ] **Step 4: Sanity — `send` and `inspect` untouched**

Confirm by inspection: `SessionManager.sendKeys` (line-only) is byte-identical to before, and `OrchestraService.inspect` still calls it. The inbox `send` verb/method are unchanged.

- [ ] **Step 5: Commit (if any doc/nits emerged)**

Only if this step produced changes (e.g. a docs/reference update). Otherwise skip.

---

## F1 hand-off note (for the later core-split)

When PR F1 extracts `OrchestraKit`, move `Sources/OrchestraCore/KeyName.swift` into `Sources/OrchestraKit/` **verbatim** (it is already `Foundation.Process`-free). `SessionManager.sendChord` (daemon) keeps reading `KeyName.tmuxToken`; the iOS client builds `[KeyToken]` and calls `ControlClient.sendKeys`. No API change is required at F1 time — this is why the model was placed in a self-contained file rather than inlined into `SessionManager.swift` or `Commands.swift`.

---

## Self-Review

**1. Spec coverage (card SCOPE + ACCEPTANCE + forest D2):**
- `KeyName` schema (Esc, arrows, Tab, Enter, C-c, PgUp/PgDn, Home/End + literal text) → Task 1 ✅ (exact vocabulary in `KeyName` cases).
- `SessionManager` `tmux send-keys` → Task 2 (`sendChord`) ✅; `sendKeys` line-only path preserved ✅ (Task 5 Step 4).
- `send-keys` verb in `CommandRegistry` → Task 3 ✅.
- `ControlClient` method → Task 4 ✅.
- Distinct from inbox `send`, not overloaded → separate verb + method, no `send` edits ✅.
- Enum in shared/client-safe module (OrchestraKit post-F1) → Task 1 places it in a pure file; F1 hand-off note ✅ (D2 has no F1 dep, so it lands in OrchestraCore now).
- ACCEPTANCE: C-c interrupts a sleep (Task 2 `chordCtrlCInterrupts`) ✅; arrows move a menu selection (Task 2 `chordArrowsMoveMenu` + `menu.sh`) ✅; Enter submits (Task 2 `chordTextThenEnter`) ✅; literal-text path preserved (same test) ✅; verified via isolated harness (Task 4 Step 5) ✅.
- GLOBAL CONSTRAINTS: both Claude+Codex (schema is agent-agnostic) ✅; minimal wire changes (one additive verb) ✅; no regressions (Task 5) ✅; small commits (one per task) ✅.

**2. Placeholder scan:** No `TBD`/`handle edge cases`/"write tests for the above" — every code + test step contains full code. Two `Implementer note` blocks point at a name to confirm in-repo (the in-memory service factory; `Flags` helper names) rather than leaving logic unspecified.

**3. Type consistency:** `KeyName`/`KeyToken` names, `sendChord(_:tokens:window:)` (SessionManager + Service), `sendKeys(ref:_:window:)` (ControlClient), verb `send-keys`, param keys `ref`/`keys`/`window` — all used consistently across Tasks 1→4. `tmuxToken` used only by `SessionManager.sendChord`. Wire form `{key|text}` matches `KeyToken` Codable in Task 1 and the CLI/command decoders in Tasks 3–4.

---

## Execution Handoff

Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task with review between tasks (Tasks 1→5 are cleanly separable; Task 2 is the acceptance-critical one to review closely).
2. **Inline Execution** — batch with checkpoints via superpowers:executing-plans.
