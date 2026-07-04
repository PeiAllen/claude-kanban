# PR D1 — `capture` RPC (read-only pane capture) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a non-attaching, read-only `capture` RPC that scrapes a card's tmux pane text (agent or shell window), size-capped — the v1 source for the phone Agent tab.

**Architecture:** One new tmux verb threaded through the existing four-layer dispatch spine —
`SessionManager.capture` (runs `tmux -L <sock> capture-pane -p`) → `OrchestraService.capture` →
a `capture` `Command` in the `CommandRegistry` → a typed `ControlClient.capture(...)` convenience.
A small `CaptureResult` value type carries the text + a truncation flag over the wire. It follows the
existing `exec`/`sessions` verb patterns exactly and is **provider-neutral** (a pane scrape works
identically for Claude and Codex agent windows, and for `shell-N` windows).

**Tech Stack:** Swift 6 / SwiftPM (`OrchestraCore`), tmux (`-L orchestra -f embedded.conf`,
`capture-pane -p`), `Foundation.Process` via the repo's `Proc` wrapper, swift-testing (`Testing`).

## Global Constraints

- **Provider-neutral — no `if agent == "claude"` branches.** `capture` is a pane scrape; it never
  inspects the agent kind. It works for `agent` and `shell-N` windows regardless of Claude/Codex.
- **Minimal wire changes:** exactly one new verb (`capture`) + one new result type (`CaptureResult`).
  No new transport, no protocol version bump.
- **No regressions:** `swift build` and `swift test` must stay **offline-green** (the offline
  coverage is the stub-backed verb + round-trip tests; the real-tmux test is opt-in via
  `.enabled(if: tmuxAvailable)`). `scripts/build-app.sh` (macOS) and `scripts/build-linux-daemon.sh`
  (Linux/musl) must keep working — `capture-pane` is standard tmux on every platform, no new dep.
- **`embedded.conf` is unchanged.** `capture` never attaches and never resizes — it only reads.
- **Output is size-capped** (default 256 KiB of characters, matching `exec`'s cap) with a
  `truncated` flag.
- **Small commits:** one commit per task.
- **F1 (core-split) composition:** D1 has **no hard dependency on F1**. `CaptureResult` is added to
  `Sources/OrchestraCore/Model.swift` and the client method to `Sources/OrchestraCore/Control/ControlClient.swift`.
  If F1 lands first, both `Model.swift` and `ControlClient.swift` move to `OrchestraKit` **as whole
  files**, so this change moves with them and composes either way — at most a trivial rebase, no
  code change.

---

## Background: the seams this plan threads (verified against real code)

The dispatch spine already exists for `exec`/`sessions`; `capture` mirrors it:

| Layer | File | Pattern to mirror |
|---|---|---|
| tmux verb | `Sources/OrchestraCore/SessionManager.swift` | `sendKeys(_:text:window:)` (`:145`), `windows(_:)` (`:116`) — build argv via `tmux([...])`, guard `r.ok` |
| protocol | `Sources/OrchestraCore/Protocols.swift:12` | `SessionManaging` requirement + empty `extension SessionManager: SessionManaging {}` (`:37`) |
| test stub | `Tests/OrchestraCoreTests/Stubs.swift` | `StubSessions` in-memory impl (must implement every protocol method or the test build breaks) |
| service | `Sources/OrchestraCore/OrchestraService.swift` | `exec(_:_:timeout:)` (`:567`), `sessions(_:)` (`:577`) — `require(id)` + delegate to `sessions.*` |
| verb | `Sources/OrchestraCore/Commands.swift:26` | `exec`/`sessions` `Command` literals in `build()` |
| client | `Sources/OrchestraCore/Control/ControlClient.swift` | generic `call(_:_:as:)` (`:94`) — add a typed wrapper |
| model | `Sources/OrchestraCore/Model.swift:353` | `ExecResult` (`Codable, Sendable, Equatable` value type with `public init`) |

Auto-exposure facts:
- **MCP:** `Sources/orchestra-mcp/main.swift:29` maps **every** `registry.commands` entry to an MCP
  `Tool`. Adding the `capture` verb auto-exposes it as an MCP tool — **no MCP code change needed.**
- **CLI:** `Sources/orchestra/CLIRunner.swift` uses a hand-written `switch` with a `default:` that
  dies on unknown verbs. A CLI `capture` subcommand is **optional** (Task 4) — useful for the
  isolated-harness manual check, but not required for the acceptance tests.

Design decisions (locked):
- **Visible pane only, no scrollback.** `capture-pane -p` (no `-S`/`-E`) captures the current visible
  pane, which is naturally bounded to `rows × cols`. Scrollback (`-S -N`) is a deliberate future
  extension, **out of scope for D1**. `maxChars` is a hard safety cap on top.
- **Raw scrape, plain text.** No `-e` (no escape sequences), no `-J` (no line-join). The capture may
  contain TUI chrome (box-drawing, etc.) — that is the intended "capture fallback" per the design
  (`2026-07-03-phone-agent-terminal-ux-design.md` §Reading: "reads via non-attaching capture/RPC").
- **Not allowlist-gated.** Unlike `exec` (which runs arbitrary user commands and gates worktree
  cards on the repo allowlist), `capture` runs no user code — it only reads an existing pane — so it
  follows the `sessions` verb (no gate). Works for worktree / freeform / scratch cards alike.
- **Not activity-logged.** The phone Agent tab polls `capture` on a timer (like `list`), so logging
  each read would flood the activity feed. Follows the `list` precedent (`Commands.swift:31` comment).

---

## File Structure

**Modified files (all in `Sources/OrchestraCore/`, plus tests):**

- `Model.swift` — add `CaptureResult` value type next to `ExecResult` (~`:353`).
- `Protocols.swift` — add one `capture(...)` requirement to `SessionManaging` (`:12`).
- `SessionManager.swift` — add `capture(_:window:maxChars:)` (the real tmux call).
- `Tests/OrchestraCoreTests/Stubs.swift` — implement `StubSessions.capture(...)` (build fix + drives verb tests).
- `OrchestraService.swift` — add `capture(_:window:)` (`require` + isAlive + delegate).
- `Commands.swift` — add the `capture` `Command` to `build()`.
- `Control/ControlClient.swift` — add typed `capture(_:window:)` convenience.
- `Tests/IntegrationTests/SessionManagerTests.swift` — real-tmux capture tests (Task 1).
- `Tests/OrchestraCoreTests/CommandsTests.swift` — registry set + verb dispatch tests (Task 2).
- `Tests/OrchestraCoreTests/ControlRoundTripTests.swift` — full client↔server loop test (Task 3).
- `Sources/orchestra/CLIRunner.swift` + `CLIHelp` — **optional** CLI subcommand (Task 4).

`Model.swift`, `Protocols.swift`, `SessionManager.swift`, and `Stubs.swift` all change together in
Task 1 because adding a protocol requirement is a **build-breaking** change until every conformer
(the real `SessionManager` *and* `StubSessions`) implements it — they must land in one commit.

---

## Task 1: `SessionManager.capture` + `CaptureResult` (the tmux read)

Adds the value type, the protocol requirement, the real tmux implementation, and the test-stub
implementation — everything that must compile together — plus a real-tmux integration test.

**Files:**
- Modify: `Sources/OrchestraCore/Model.swift` (add `CaptureResult` near `:353`)
- Modify: `Sources/OrchestraCore/Protocols.swift:12-24` (add requirement)
- Modify: `Sources/OrchestraCore/SessionManager.swift` (add method after `sendKeys`, ~`:152`)
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` (add `StubSessions.capture`)
- Test: `Tests/IntegrationTests/SessionManagerTests.swift` (new tests)

**Interfaces:**
- Produces:
  - `public struct CaptureResult: Codable, Sendable, Equatable { let window: String; let text: String; let truncated: Bool; public init(window:text:truncated:) }`
  - `SessionManaging.capture(_ name: String, window: String, maxChars: Int) throws -> CaptureResult`
  - `SessionManager.capture(_ name: String, window: String = "agent", maxChars: Int = 256 * 1024) throws -> CaptureResult`
  - `StubSessions.capture(_:window:maxChars:)` returning `CaptureResult(window:, text: "stub-pane:<name>:<window>", truncated: false)`

- [ ] **Step 1: Write the failing integration test**

Add to `Tests/IntegrationTests/SessionManagerTests.swift` (inside the existing `SessionManagerTests`
class, alongside `ensureAndLiveness`):

```swift
    @Test("capture returns the agent pane's visible text; size-caps; missing window throws")
    func captureAgent() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        let marker = "CAPTURE_MARKER_\(UInt32.random(in: 0..<1_000_000))"
        // Echo a known marker into the agent pane, then keep the window alive.
        let (name, _) = try sm.ensure(task, argv: ["sh", "-c", "echo \(marker); sleep 30"])

        // tmux needs a beat to render the echo; retry so the test isn't flaky.
        var cap = try sm.capture(name)
        for _ in 0..<20 where !cap.text.contains(marker) {
            Thread.sleep(forTimeInterval: 0.05)
            cap = try sm.capture(name)
        }
        #expect(cap.window == "agent")
        #expect(cap.text.contains(marker))
        #expect(!cap.truncated)

        // A tiny cap truncates and sets the flag.
        let small = try sm.capture(name, window: "agent", maxChars: 3)
        #expect(small.text.count == 3)
        #expect(small.truncated)

        // Capturing a non-existent window throws (target can't be found).
        #expect(throws: OrchestraError.self) { try sm.capture(name, window: "shell-9") }

        try sm.kill(name)
    }

    @Test("capture reads a shell window too (works for non-agent windows)")
    func captureShell() throws {
        let cwd = IntegrationSupport.tempDir("sm")
        let task = makeTask(cwd: cwd)
        let (name, _) = try sm.ensure(task, argv: keepAliveArgv)   // ["sleep", "30"]
        let win = try sm.newShellWindow(name, cwd: cwd)            // "shell-1"
        let marker = "SHELL_MARK_\(UInt32.random(in: 0..<1_000_000))"
        try sm.sendKeys(name, text: "echo \(marker)", window: win)

        var cap = try sm.capture(name, window: win)
        for _ in 0..<20 where !cap.text.contains(marker) {
            Thread.sleep(forTimeInterval: 0.05)
            cap = try sm.capture(name, window: win)
        }
        #expect(cap.window == win)
        #expect(cap.text.contains(marker))
        try sm.kill(name)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SessionManagerTests`
Expected: FAIL to **compile** — `value of type 'SessionManager' has no member 'capture'` and
`cannot find 'CaptureResult' in scope`.

- [ ] **Step 3: Add the `CaptureResult` model**

In `Sources/OrchestraCore/Model.swift`, immediately after the `ExecResult` struct (`:353-361`):

```swift
/// A read-only pane snapshot (the `capture` command). Provider-neutral: just the pane's text,
/// size-capped. `truncated` is true when `text` was cut to the cap. No attach, no resize.
public struct CaptureResult: Codable, Sendable, Equatable {
    public let window: String    // "agent" | "shell-1" | ...
    public let text: String      // captured *visible* pane text, size-capped
    public let truncated: Bool   // true if `text` was cut to the cap
    public init(window: String, text: String, truncated: Bool) {
        self.window = window; self.text = text; self.truncated = truncated
    }
}
```

- [ ] **Step 4: Add the protocol requirement**

In `Sources/OrchestraCore/Protocols.swift`, inside `protocol SessionManaging` (after the `sendKeys`
requirement, ~`:21`):

```swift
    func capture(_ name: String, window: String, maxChars: Int) throws -> CaptureResult
```

(Protocol requirements can't carry default argument values; the defaults live on the concrete
`SessionManager` method. This mirrors how `sendKeys(_:text:window:)` is declared without defaults in
the protocol but has `window: String = "agent"` on the concrete type.)

- [ ] **Step 5: Implement the real tmux read**

In `Sources/OrchestraCore/SessionManager.swift`, after `sendKeys(...)` (`:152`):

```swift
    /// Read-only snapshot of a window's pane via `capture-pane -p` — the non-attaching read the
    /// phone Agent tab uses. Captures the *visible* pane (no scrollback) so output is naturally
    /// bounded; `maxChars` is a hard safety cap on top. Never attaches, never resizes. Works for the
    /// `agent` window and any `shell-N` window. Throws if the target window/pane doesn't exist.
    public func capture(_ name: String, window: String = "agent",
                        maxChars: Int = 256 * 1024) throws -> CaptureResult {
        let target = "\(name):\(window)"
        let r = try tmux(["capture-pane", "-p", "-t", target])
        guard r.ok else {
            throw OrchestraError.io(r.stderr.isEmpty ? "tmux capture-pane failed for \(target)" : r.stderr)
        }
        let full = r.stdout
        let truncated = full.count > maxChars
        let text = truncated ? String(full.prefix(maxChars)) : full
        return CaptureResult(window: window, text: text, truncated: truncated)
    }
```

- [ ] **Step 6: Implement the test stub**

In `Tests/OrchestraCoreTests/Stubs.swift`, inside `final class StubSessions` (after `sendKeys`,
before `kill`):

```swift
    func capture(_ name: String, window: String, maxChars: Int) throws -> CaptureResult {
        guard try isAlive(name) else { throw OrchestraError.io("session not alive: \(name)") }
        let text = "stub-pane:\(name):\(window)"
        return CaptureResult(window: window, text: String(text.prefix(maxChars)), truncated: false)
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter SessionManagerTests`
Expected: PASS — `captureAgent` and `captureShell` green (they require `tmux`; the suite is gated by
`.enabled(if: IntegrationSupport.tmuxAvailable)`, so on a tmux-less box they skip rather than fail).

Also confirm the whole build still compiles (the new protocol requirement reaches every conformer):
Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 8: Commit**

```bash
git add Sources/OrchestraCore/Model.swift Sources/OrchestraCore/Protocols.swift \
        Sources/OrchestraCore/SessionManager.swift Tests/OrchestraCoreTests/Stubs.swift \
        Tests/IntegrationTests/SessionManagerTests.swift
git commit -m "feat(daemon): SessionManager.capture — read-only tmux pane scrape + CaptureResult"
```

---

## Task 2: `capture` verb + `OrchestraService.capture` (RPC dispatch)

Wires the tmux read into the command registry via the service. The verb test runs fully offline
(StubSessions), so it is the **offline-green** guarantee for this PR.

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add `capture` after `sessions`, ~`:585`)
- Modify: `Sources/OrchestraCore/Commands.swift:26` (add the `capture` `Command` in `build()`)
- Test: `Tests/OrchestraCoreTests/CommandsTests.swift` (registry set + dispatch)

**Interfaces:**
- Consumes: `SessionManaging.capture(_:window:maxChars:)` and `CaptureResult` (Task 1);
  `OrchestraService.require(_:)` (`:619`), `resolveRef(_:)` (`:625`).
- Produces:
  - `OrchestraService.capture(_ id: UUID, window: String = "agent") async throws -> CaptureResult`
  - A registry `Command` named `"capture"` with params `{ ref (required), window (optional) }`.

- [ ] **Step 1: Write the failing tests**

In `Tests/OrchestraCoreTests/CommandsTests.swift`, update the `expected` names array in `fullSet`
(`:11-14`) to include `"capture"`:

```swift
        let expected = ["list", "spawn", "move", "send", "status", "archive", "reopen",
                        "restart", "resume", "shell", "inspect", "closeShell", "exec", "sessions",
                        "capture", "batch-spawn",
                        "wait", "handoff", "trust", "trustState",
                        "inbox", "inbox-edit", "inbox-remove", "inbox-reorder"]
```

Then add a dispatch test to the same suite:

```swift
    @Test("capture dispatches to a read of the card's agent pane")
    func dispatchCapture() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        // Make the card's tmux session deterministically alive for the read (spawn's ensure is async).
        env.sessions.setAlive(t.id, true)

        let reg = CommandRegistry()
        let capture = try #require(reg.command("capture"))
        let res = try await capture.run(env.svc, .object(["ref": .string(t.shortId)]), .mcp)
        let cap = try res.decode(CaptureResult.self)
        #expect(cap.window == "agent")
        // The stub echoes the session name into its pane text.
        #expect(cap.text.contains(env.sessions.sessionName(t.id)))

        // A read of a card whose session isn't running surfaces an error.
        let t2 = try await env.svc.spawn(SpawnInput(prompt: "y", repo: repo, branch: "c"))
        env.sessions.setAlive(t2.id, false)
        await #expect(throws: OrchestraError.self) {
            _ = try await capture.run(env.svc, .object(["ref": .string(t2.shortId)]), .mcp)
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CommandsTests`
Expected: FAIL — `fullSet` fails (`"capture"` not in `reg.names`) and `dispatchCapture` fails
(`reg.command("capture")` is `nil`, so `#require` throws).

- [ ] **Step 3: Add `OrchestraService.capture`**

In `Sources/OrchestraCore/OrchestraService.swift`, after `sessions(_:)` (which ends ~`:585`), in the
same `// MARK: - shells / exec / sessions` region:

```swift
    /// Read-only snapshot of a card's `agent` (default) or a `shell-N` window — the phone Agent
    /// tab's v1 read source. No attach, no resize. Not allowlist-gated: it runs no user code, it
    /// only reads an existing pane (cf. `exec`, which does gate). Throws if the session isn't running.
    public func capture(_ id: UUID, window: String = "agent") async throws -> CaptureResult {
        _ = try await require(id)                     // validates the card exists
        let name = sessions.sessionName(id)
        guard try sessions.isAlive(name) else { throw OrchestraError.io("session not running") }
        return try sessions.capture(name, window: window, maxChars: 256 * 1024)
    }
```

- [ ] **Step 4: Add the `capture` verb**

In `Sources/OrchestraCore/Commands.swift`, inside `build()`, immediately after the `sessions`
`Command` (`:257-263`) and before `trustState`:

```swift
            Command(name: "capture",
                    summary: "Read-only snapshot of a card's tmux pane (agent or a shell window). "
                        + "No attach, no resize.",
                    params: schema(["ref": refProp(),
                                    "window": strProp("Window to read: 'agent' (default) or a shell "
                                        + "window like 'shell-1'")],
                                   required: ["ref"])) { svc, p, _ in
                let t = try await svc.resolveRef(try p.string("ref"))
                let cap = try await svc.capture(t.id, window: p.optString("window") ?? "agent")
                // NOT logged: the phone Agent tab polls `capture` on a timer (like `list`), so
                // logging each read would flood the activity feed and bury real events.
                return try JSONValue(encodable: cap)
            },
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter CommandsTests`
Expected: PASS — `fullSet` and `dispatchCapture` green.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/Commands.swift \
        Tests/OrchestraCoreTests/CommandsTests.swift
git commit -m "feat(daemon): capture verb + OrchestraService.capture (read-only pane RPC)"
```

---

## Task 3: `ControlClient.capture(...)` convenience (typed client entry point)

The typed client method the iOS Agent tab (PR T3) will consume, verified end-to-end over the UDS
JSON-RPC socket.

**Files:**
- Modify: `Sources/OrchestraCore/Control/ControlClient.swift` (add method after `call<T:Decodable>`, ~`:100`)
- Test: `Tests/OrchestraCoreTests/ControlRoundTripTests.swift` (new round-trip test)

**Interfaces:**
- Consumes: `ControlClient.call(_:_:as:)` (`:94`), `CaptureResult` (Task 1), the `capture` verb (Task 2).
- Produces: `ControlClient.capture(_ ref: String, window: String = "agent") async throws -> CaptureResult`

- [ ] **Step 1: Write the failing test**

In `Tests/OrchestraCoreTests/ControlRoundTripTests.swift`, add a test to the suite (mirrors the
existing `roundTrip` harness — `ControlServer` + `ControlClient` over a `/tmp` socket):

```swift
    @Test("capture round-trips a pane read over the socket via the typed client method")
    func captureRoundTrip() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }

        let client = ControlClient(socketPath: path, source: .cli)
        try client.connect(); defer { client.close() }

        let spawnRes = try await client.call("spawn", .object([
            "prompt": .string("x"), "repo": .string(repo), "branch": .string("feat"),
        ]))
        let task = try spawnRes.decode(Task.self)
        env.sessions.setAlive(task.id, true)   // same StubSessions instance the server holds

        let cap = try await client.capture(task.shortId)
        #expect(cap.window == "agent")
        #expect(cap.text.contains(env.sessions.sessionName(task.id)))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ControlRoundTripTests`
Expected: FAIL to compile — `value of type 'ControlClient' has no member 'capture'`.

- [ ] **Step 3: Add the client convenience**

In `Sources/OrchestraCore/Control/ControlClient.swift`, after the generic `call<T: Decodable>(...)`
method (ends ~`:100`):

```swift
    /// Typed convenience over the `capture` verb — a non-attaching, read-only pane snapshot. The
    /// phone Agent tab's v1 read source.
    public func capture(_ ref: String, window: String = "agent") async throws -> CaptureResult {
        try await call("capture", .object(["ref": .string(ref), "window": .string(window)]),
                       as: CaptureResult.self)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ControlRoundTripTests`
Expected: PASS — `captureRoundTrip` green.

- [ ] **Step 5: Full suite + both builds (no-regression gate)**

Run: `swift build && swift test`
Expected: build succeeds; all tests pass (offline).

Run: `scripts/build-linux-daemon.sh` (from a shell with `~/.swiftly/env.sh` sourced)
Expected: cross-compiles green — `capture-pane` is standard tmux, no new symbol on Linux.

Run: `scripts/build-app.sh`
Expected: the macOS app still builds (no App-target change, but confirm the core still links).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Control/ControlClient.swift \
        Tests/OrchestraCoreTests/ControlRoundTripTests.swift
git commit -m "feat(client): ControlClient.capture — typed pane-snapshot convenience"
```

---

## Task 4 (OPTIONAL): CLI `capture` subcommand

Out of the named file scope, but it makes the isolated-harness manual check a one-liner
(`orchestra capture <ref>`). MCP already auto-exposes `capture`, so this is purely CLI ergonomics —
**skip if keeping the PR minimal.**

**Files:**
- Modify: `Sources/orchestra/CLIRunner.swift` (add a `case "capture"` in the verb switch)
- Modify: the `CLIHelp` text source (add a `capture` help line)

- [ ] **Step 1: Add the CLI case**

In `Sources/orchestra/CLIRunner.swift`, add a case near `exec`/`sessions` (~`:117-135`):

```swift
            case "capture":
                let ref = flags.positional(0) ?? flags.require("ref")
                let window = flags.value("window") ?? "agent"
                let cap = try await client.capture(ref, window: window)
                FileHandle.standardOutput.write(Data(cap.text.utf8))
                if cap.truncated { FileHandle.standardError.write(Data("\n[capture truncated]\n".utf8)) }
```

- [ ] **Step 2: Add a help line**

Add to the `CLIHelp.text` command list (matching the existing `("exec", "<ref> -- <cmd>")` style):

```
  capture <ref> [--window agent|shell-1]   read-only snapshot of a card's pane
```

- [ ] **Step 3: Build + manual smoke**

Run: `swift build`
Expected: builds. Manual: `orchestra capture <ref>` prints a live pane's text (see Verification).

- [ ] **Step 4: Commit**

```bash
git add Sources/orchestra/CLIRunner.swift Sources/orchestra/CLIHelp.swift
git commit -m "feat(cli): orchestra capture subcommand (read-only pane snapshot)"
```

---

## Verification — isolated harness (acceptance evidence)

Per the acceptance criteria, verify against a **disposable isolated daemon** (never the live app),
using the `scripts/orch-test.sh`-style harness (own `HOME` + tmux socket). Two paths:

1. **Automated (the offline gate):** `swift test` runs the stub-backed verb + round-trip tests
   (Tasks 2–3) with no tmux, and `swift test --filter SessionManagerTests` runs the real-tmux
   capture tests (Task 1) when tmux is present. This is the primary acceptance evidence:
   *"integration test captures a known scratch tmux pane and returns its text; output size-capped;
   works for agent + shell windows; no attach / no resize."*

2. **Manual, against an isolated daemon** (confirms the full daemon path incl. MCP auto-exposure):
   - Start an isolated daemon via the project's `orch-test.sh`-style harness (own `HOME`, own tmux
     `-L` socket) so nothing touches the live board.
   - Spawn a scratch card in it (e.g. `orchestra spawn --scratch "print a banner"`), which creates
     the `agent` tmux window.
   - Read its pane without attaching:
     - With Task 4: `orchestra capture <shortId>` → prints the agent pane text; add
       `--window shell-1` after opening a shell (`orchestra shell <ref>`) to prove the shell path.
     - Without Task 4 (MCP): call the auto-exposed `capture` MCP tool with `{ ref, window? }`.
   - Confirm: text returned, no attach happened (the card's window size is unchanged — `capture`
     issues no `attach`/`resize-window`), and works for both `agent` and `shell-N`.
   - Tear down the isolated daemon (the harness kills its own tmux server + temp `HOME`).

---

## Self-Review

**Spec coverage** (against the D1 scope in `2026-07-04-mobile-orchestra-implementation-forest.md`):
- `SessionManager.capture(session:window:)` running `capture-pane -p`, bounded output → Task 1 ✓
- `capture` verb in `CommandRegistry` → Task 2 ✓
- `OrchestraService` wiring → Task 2 ✓
- `ControlClient.capture(...)` convenience → Task 3 ✓
- Works for `agent` **and** `shell` windows → Task 1 (`captureAgent` + `captureShell`) ✓
- Output size-capped → `maxChars` + `truncated` (Tasks 1–2), asserted in `captureAgent` ✓
- No attach / no resize → `capture-pane -p` only; asserted implicitly (no `attach`/`resize-window`
  argv) + verification note ✓
- Provider-neutral (Claude + Codex) → pane scrape, no agent-kind branch ✓ (Global Constraints)
- Minimal wire changes / no regressions / small commits → one verb + one type; per-task commits;
  Task 3 Step 5 runs the full-suite + Linux + app build gate ✓
- F1 composition note → Global Constraints ✓

**Placeholder scan:** every code step contains complete code; every run step names the exact
`swift test --filter` command and expected pass/fail. No TBD/TODO. ✓

**Type consistency:** `CaptureResult(window:text:truncated:)` is defined once (Task 1) and decoded
identically in Tasks 2–3. `capture(_:window:maxChars:)` (SessionManaging/SessionManager/Stub) and
`OrchestraService.capture(_:window:)` and `ControlClient.capture(_:window:)` signatures match every
call site. The registry name `"capture"` matches the `reg.command("capture")` lookups and the
`fullSet` expected array. ✓
