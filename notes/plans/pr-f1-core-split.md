# PR F1 — Split a client-safe core out of `OrchestraCore` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract a new client-safe SwiftPM library target **`OrchestraKit`** (`.macOS(.v14) + .iOS(.v17)`) holding the models, wire/transport client, connection store, and command *vocabulary*, out of `OrchestraCore` — so an iOS client can link it with zero `Foundation.Process`/AppKit, while `OrchestraCore` keeps all daemon-side code and now depends on `OrchestraKit`. Pure re-partition, no behavior change.

**Architecture:** Two-layer package. `OrchestraKit` = Foundation-only logic every client needs (models + enums, `JSONValue`/codecs, `Config` path/socket resolvers, the `Transport`/`UDSSocket`/`RPC`/`ControlClient` stack, `Connection`/`ConnectionStore`/`RemoteCommands`, and a new `CommandCatalog` of name+arg schemas). `OrchestraCore` = daemon execution (`Proc`, `SessionManager`, `OrchestraService*`, `Launcher`, `ControlServer`, `CommandRegistry` handlers, adapters, diff, keyboard) and now `depends on OrchestraKit`. A single `@_exported import OrchestraKit` inside `OrchestraCore` keeps all ~65 existing `import OrchestraCore` consumers (daemon, CLI, tests, app) compiling unchanged.

**Tech Stack:** Swift 6 / SwiftPM multi-target, Foundation + POSIX shims (`Darwin`/`Glibc`/`Musl`), the official MCP swift-sdk (orchestra-mcp only). No new third-party dependencies.

## Global Constraints

- **Design for every agent (Claude AND Codex).** No `if agent == "claude"` branches; F1 touches no adapter logic — leave `Sources/OrchestraCore/Agents/` in Core untouched.
- **No behavior change.** F1 is a pure module re-partition + import fixups + one schema/execution split. Every existing test must stay green with no assertion changes.
- **Do not regress desktop or Linux.** `swift build` / `swift test` stay offline-green; `scripts/build-app.sh` (macOS app) and `scripts/build-linux-daemon.sh` (musl cross-build of `orchestrad`/`orchestra`/`orchestra-mcp`) must keep working.
- **Platforms:** `OrchestraKit` = `[.macOS(.v14), .iOS(.v17)]`; `OrchestraCore`/`orchestrad`/`orchestra`/`orchestra-mcp` stay macOS/Linux.
- **`OrchestraKit` must have ZERO `Foundation.Process` / `posix_spawn` / AppKit / UIKit references** — this is the iOS blocker being removed (`Proc.swift:25,132,159` stays in Core).
- **Small commits.** One commit per task below.

---

## The module boundary (the contract F2/F3 and every iOS card consume)

> This table is the deliverable the [PR-TREE](../../notes/plans/2026-07-04-mobile-orchestra-PR-TREE.md) points at ("name it crisply"). It is the authoritative statement of what lives in `OrchestraKit` after F1.

**`OrchestraKit` (client-safe, `.macOS + .iOS`) — the public surface downstream consumes:**

| Area | Types / entry points |
|------|----------------------|
| Models & enums | `Task`, `Column`, `StartIn`, `CardOrigin`, `CardAccess`, `WaitReason`, `DeadReason`, `DiffStat`, `TmuxTarget`, `ExecResult`, `StatusReport`, `AgentSessionInfo`, `CardSnapshot`(if present), `ActivitySource`, `Event`, `SpawnInput` (all of `Model.swift`) |
| Wire currency | `JSONValue`, `OrchestraJSON` (`wire`/`pretty`/`decoder`), `OrchestraError`, `RPCError` |
| Config / paths | `Config` (struct + `socketPath`/`tmuxSocket`/`dataDir`/`worktreePath`/`allowedRoots`/…), `StatusLineMode` |
| Transport client | `Transport` protocol, `ConnectionState`, `UDS`, `LineReader`, `RPCRequest`/`RPCResponse`/`RPCNotification`/`WireMessage`/`RPCCodec`, `ControlClient` (`connect`/`call`/`subscribe`/`state`/`onState`) |
| Connections | `Connection`, `ConnectionStore`, `RemoteCommands` |
| Command vocabulary | `CommandSchema` (name/summary/params), `CommandCatalog.all` / `CommandCatalog.schema(_:)` + schema builders |
| Version | `OrchestraVersion` |
| POSIX shim | `closeFD` |

**`OrchestraCore` (daemon, `.macOS + .Linux`, `depends on OrchestraKit`) — unchanged responsibilities:**

`Proc`, `SessionManager` (+`SessionInfo`), `WorktreeManager`, `MergeWatch`, `RolloutTailer`, `Launcher`, `OrchestraService` + `+Diff`/`+Recovery`/`+Report`/`+Wake`, `ConfigStore`, `TaskStore`, `TaskRef` (`resolve`/`slugify`/`titleSeed`), `PathResolver`, `Protocols` (`WorktreeManaging`/`SessionManaging`), `HandoffSeed`, `Inbox`, `CommandRegistry` (the name→handler execution table), `Control/{ControlServer,DaemonLifecycle,HookChannel,HooksRenderer}`, all of `Agents/`, `Diff/`, `Keyboard/`, and `Resources/`.

**Dependency edges (acyclic — verified: no Kit file references any Core-only type):**
```
OrchestraKit  ◄──  OrchestraCore  ◄──  orchestrad
      ▲                  ▲         ◄──  orchestra (CLI)
      └──────────────────┼──────── orchestra-mcp  (repointed to Kit-only, see D4)
                         App/ (XcodeGen, links OrchestraCore → transitively OrchestraKit)
```

### Recommendation for F2 (`BoardModel` / `Theme` home)

**Introduce a separate `OrchestraUI` SwiftUI target in F2 — do NOT put `BoardModel`/`Theme` into `OrchestraKit`.** Rationale: `OrchestraKit` is deliberately Foundation-only so *any* client (SwiftUI or not) links a minimal, UI-framework-free core. `BoardModel` is a SwiftUI `ObservableObject`, `Theme` is SwiftUI, and F2's platform protocols (`TerminalHost.attach(target:) -> View`, etc.) are SwiftUI-coupled. Keeping them in Kit would drag SwiftUI into the wire/model layer. Target layering to adopt in F2:
```
OrchestraKit (Foundation)  ◄─  OrchestraUI (SwiftUI: BoardModel, Theme, PlatformProtocols, shared views)  ◄─  App (macOS) / App-iOS
```
F1 does **not** create `OrchestraUI`; it only leaves the boundary clean so F2 can add it above Kit.

---

## Design decisions

- **D1 — `@_exported import OrchestraKit` from Core.** Add `Sources/OrchestraCore/Exports.swift` containing `@_exported import OrchestraKit`. Every downstream `import OrchestraCore` (daemon, CLI, 63 test files, the app) then transparently sees Kit's public symbols with **zero import-line churn**. This is the single biggest lever keeping F1 small. *Fallback if `@_exported` is rejected in review:* add an explicit `import OrchestraKit` to only the files the compiler flags (daemon `Control/*`, `TransportReconnectTests`, MCP). Chosen: `@_exported`.
- **D2 — Command schema/execution split.** `Command.run` is typed `(OrchestraService, JSONValue, ActivitySource) -> JSONValue`, so `Command`/`CommandRegistry` cannot move to Kit. Split the *vocabulary* (name + summary + param JSON-schema) into `OrchestraKit/CommandCatalog.swift` as pure data; keep the *handlers* in `OrchestraCore/CommandRegistry.swift` as a name→closure table paired against the catalog. A drift-guard test asserts `Set(handler names) == Set(CommandCatalog names)` so a missing/extra handler fails the build. This is the one non-mechanical transform in F1; single-source-of-truth is preserved (MCP `inputSchema` + CLI help read the catalog; the daemon reads the registry). *If review wants F1 smaller, the fallback is to defer the split and keep `Commands.swift` wholly in Core until F3/M4 — but the tree asks for a crisp iOS-consumable boundary, so the split is planned in.*
- **D3 — internal→public across the new seam.** Several symbols that daemon-side Core files use are currently module-`internal`; once their defining file moves to Kit they must become `public`. Known set (compiler-enforced, Task 2): in `RPC.swift` — `RPCRequest`, `RPCResponse`, `RPCNotification`, `WireMessage`, `RPCCodec` (+ their stored properties/methods); in `UDSSocket.swift` — `UDS` (+ used `static` methods `listen`/`connect`/`accept`/`writeAll`/`read`) and `LineReader` (+ `init(fd:)`/`next()`); in `Platform.swift` — `closeFD`. Drive this by the compiler: build, add `public` to each flagged symbol, repeat.
- **D4 — `orchestra-mcp` → Kit-only.** After D2, `orchestra-mcp/main.swift` references only `CommandCatalog`, `ControlClient`, `Config`, `JSONValue`, `RPCError`, `OrchestraJSON`, `OrchestraVersion` — all in Kit, zero daemon types. Repoint its dependency to `OrchestraKit` (+ the `MCP` product) and its `import OrchestraCore` → `import OrchestraKit`. Shrinks the bridge's link surface. (The CLI and daemon keep depending on `OrchestraCore`.)
- **D5 — `PathResolver` stays in Core.** The scope phrase "path resolvers from `Config`" = `Config`'s own `socketPath`/`dataDir`/`worktreePath`/`allowedRoots` helpers (which move to Kit *with* `Config`). `PathResolver.swift` is the allowlist **security enforcement** used by `OrchestraService.spawn`/`resolveRef`; no client needs it. Keep it in Core (it may depend on Kit's `Config`, which is legal). Likewise `TaskRef.swift`, `Inbox.swift`, `HandoffSeed.swift`, `Protocols.swift` stay in Core (not client-needed for F1; `HandoffSeed`→`StopDrain`, `Protocols`→`WorktreeManager`/`SessionManager`, `Inbox`'s actor are all Core-coupled). Rule applied throughout: **a file moves to Kit only if a client consumes it or the scope names it; else it stays in Core.**

---

## File-move manifest

**Move to `Sources/OrchestraKit/` (verbatim, no content change except D3 `public` edits in Task 2 and the D2 split in Task 3):**

_Task 1 group (leaf value/model/config/connection files — no Core deps):_
- `Model.swift`, `JSONValue.swift`, `Coders.swift`, `Errors.swift`, `Version.swift`, `Platform.swift`, `Config.swift`, `Connection.swift`, `ConnectionStore.swift`, `RemoteCommands.swift`

_Task 2 group (transport stack — needs `public` edits):_
- `Control/Transport.swift`, `Control/RPC.swift`, `Control/UDSSocket.swift`, `Control/ControlClient.swift` → `Sources/OrchestraKit/Control/`

_Task 3 (new file, split out of `Commands.swift`):_
- New `Sources/OrchestraKit/CommandCatalog.swift`

**Stay in `Sources/OrchestraCore/`:** everything else, notably `Proc.swift`, `SessionManager.swift`, `OrchestraService*.swift`, `Launcher.swift`, `WorktreeManager.swift`, `MergeWatch.swift`, `RolloutTailer.swift`, `ConfigStore.swift`, `TaskStore.swift`, `TaskRef.swift`, `PathResolver.swift`, `Protocols.swift`, `HandoffSeed.swift`, `Inbox.swift`, `Control/{ControlServer,DaemonLifecycle,HookChannel,HooksRenderer}.swift`, `Agents/*`, `Diff/*`, `Keyboard/*`, `Resources/*`. `Commands.swift` → renamed `CommandRegistry.swift` (execution only) in Task 3.

---

## Task 0: Preflight — capture the green baseline

**Files:** none (records the pre-change state so any regression is attributable).

- [ ] **Step 1: Confirm the tree is clean and on the F1 branch**

Run: `git status --short && git branch --show-current`
Expected: no output from `status`; branch is `plan/f1-core-split` (the plan lives here; the impl PR will use `mobile/f1-core-split`).

- [ ] **Step 2: Baseline `swift build`**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` (no errors).

- [ ] **Step 3: Baseline `swift test`**

Run: `swift test 2>&1 | tail -15`
Expected: all tests pass. Record the count (e.g. "Executed N tests, 0 failures") — the same count must hold after F1.

- [ ] **Step 4: Baseline macOS app build**

Run: `scripts/build-app.sh 2>&1 | tail -5`
Expected: build succeeds (records that the app links `OrchestraCore` cleanly today).

---

## Task 1: Create `OrchestraKit` + move the leaf files

**Files:**
- Modify: `Package.swift`
- Create: `Sources/OrchestraCore/Exports.swift`
- Move: `Model.swift`, `JSONValue.swift`, `Coders.swift`, `Errors.swift`, `Version.swift`, `Platform.swift`, `Config.swift`, `Connection.swift`, `ConnectionStore.swift`, `RemoteCommands.swift` → `Sources/OrchestraKit/`

**Interfaces:**
- Produces: the `OrchestraKit` target + product; `Config`, `Model.swift` types, `JSONValue`, `OrchestraJSON`, `OrchestraError`, `OrchestraVersion`, `Connection`/`ConnectionStore`/`RemoteCommands`, `closeFD` now live in `OrchestraKit`.
- Consumes: nothing from later tasks.

- [ ] **Step 1: Create the Kit source dir and move the leaf files with `git mv`**

```bash
mkdir -p Sources/OrchestraKit
git mv Sources/OrchestraCore/Model.swift Sources/OrchestraKit/Model.swift
git mv Sources/OrchestraCore/JSONValue.swift Sources/OrchestraKit/JSONValue.swift
git mv Sources/OrchestraCore/Coders.swift Sources/OrchestraKit/Coders.swift
git mv Sources/OrchestraCore/Errors.swift Sources/OrchestraKit/Errors.swift
git mv Sources/OrchestraCore/Version.swift Sources/OrchestraKit/Version.swift
git mv Sources/OrchestraCore/Platform.swift Sources/OrchestraKit/Platform.swift
git mv Sources/OrchestraCore/Config.swift Sources/OrchestraKit/Config.swift
git mv Sources/OrchestraCore/Connection.swift Sources/OrchestraKit/Connection.swift
git mv Sources/OrchestraCore/ConnectionStore.swift Sources/OrchestraKit/ConnectionStore.swift
git mv Sources/OrchestraCore/RemoteCommands.swift Sources/OrchestraKit/RemoteCommands.swift
```

- [ ] **Step 2: Add the `OrchestraKit` target + product to `Package.swift`**

Edit `Package.swift`. Add the product (after the `OrchestraCore` library product):

```swift
        .library(name: "OrchestraKit", targets: ["OrchestraKit"]),
```

Add the target (before the `OrchestraCore` target) and make `OrchestraCore` depend on it:

```swift
        .target(
            name: "OrchestraKit",
            // Client-safe: Foundation + POSIX only. Platforms include iOS so a phone client links it.
            // MUST NOT gain Foundation.Process / AppKit / UIKit references (verified by scripts/typecheck-kit-ios.sh).
            swiftSettings: []
        ),
        .target(
            name: "OrchestraCore",
            dependencies: ["OrchestraKit"],
            resources: [ /* unchanged resource list */ ]
        ),
```

Set per-target platforms by adding an `OrchestraKit` platform floor. `Package.platforms` stays `[.macOS(.v14)]` for the daemon products; `OrchestraKit` widens to iOS via the target's own availability — declare it at package level so both are expressible:

```swift
    platforms: [.macOS(.v14), .iOS(.v17)],
```

> Note: SwiftPM package-level `platforms` sets the *minimum* per-OS deployment target; the daemon executables still only *build* on macOS/Linux (they are never asked to build for iOS). Adding `.iOS(.v17)` here does not make `orchestrad` an iOS product — it only lets `OrchestraKit` be compiled against the iOS SDK in Task 4. Leave `products`/`dependencies` for the executables unchanged.

- [ ] **Step 3: Add the `@_exported` shim so downstream imports keep working (D1)**

Create `Sources/OrchestraCore/Exports.swift`:

```swift
// Re-export OrchestraKit so every existing `import OrchestraCore` (daemon, CLI, tests, app)
// transparently sees the client-safe types that moved to OrchestraKit in PR F1 — no import churn.
@_exported import OrchestraKit
```

- [ ] **Step 4: Build to verify the split target compiles**

Run: `swift build 2>&1 | tail -15`
Expected: `Build complete!`. If the compiler reports an unresolved symbol in a daemon-staying file (e.g. a Kit type referenced without visibility), it is because that symbol was `internal` — defer such fixes to Task 2 for the transport files; for the leaf files here everything referenced is already `public`, so this should build clean.

- [ ] **Step 5: Run the tests to confirm no behavior change**

Run: `swift test 2>&1 | tail -15`
Expected: same test count and 0 failures as Task 0 Step 3.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(F1): create OrchestraKit target; move models/config/connections into it"
```

---

## Task 2: Move the transport stack to Kit + make cross-seam symbols `public`

**Files:**
- Move: `Control/Transport.swift`, `Control/RPC.swift`, `Control/UDSSocket.swift`, `Control/ControlClient.swift` → `Sources/OrchestraKit/Control/`
- Modify (add `public`): the moved `RPC.swift`, `UDSSocket.swift`, `Platform.swift` (from Task 1)
- Touch (no logic change): daemon-staying `Control/ControlServer.swift`, `Control/DaemonLifecycle.swift` compile against the now-cross-module symbols

**Interfaces:**
- Consumes: `Config`, `JSONValue`, `OrchestraError`, `Event`, `ActivitySource`, `closeFD` from `OrchestraKit` (Task 1).
- Produces: `Transport`, `ConnectionState`, `UDS`, `LineReader`, `RPCRequest`/`RPCResponse`/`RPCNotification`/`WireMessage`/`RPCCodec`, `ControlClient` as `public` `OrchestraKit` symbols consumed by daemon `ControlServer`/`DaemonLifecycle` and by the CLI/MCP.

- [ ] **Step 1: Move the four transport files**

```bash
mkdir -p Sources/OrchestraKit/Control
git mv Sources/OrchestraCore/Control/Transport.swift Sources/OrchestraKit/Control/Transport.swift
git mv Sources/OrchestraCore/Control/RPC.swift Sources/OrchestraKit/Control/RPC.swift
git mv Sources/OrchestraCore/Control/UDSSocket.swift Sources/OrchestraKit/Control/UDSSocket.swift
git mv Sources/OrchestraCore/Control/ControlClient.swift Sources/OrchestraKit/Control/ControlClient.swift
```

- [ ] **Step 2: Build to surface the exact set of now-cross-module `internal` symbols**

Run: `swift build 2>&1 | grep -E "error:|is inaccessible|not found" | head -40`
Expected: a list of errors of the form `'RPCCodec' is inaccessible due to 'internal' protection level` (and similar for `LineReader`, `UDS`, `RPCRequest`, `RPCResponse`, `RPCNotification`, `closeFD`), raised from `ControlServer.swift` / `DaemonLifecycle.swift` (which stay in Core). This is the compiler enumerating D3's work.

- [ ] **Step 3: Make `RPC.swift` wire types `public`**

In `Sources/OrchestraKit/Control/RPC.swift`, add `public` to the types the daemon server + client cross the module boundary for, and their stored members. Concretely:

```swift
public struct RPCRequest: Codable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int?
    public var method: String
    public var params: JSONValue?
    public var source: String?
    public init(id: Int? = nil, method: String, params: JSONValue? = nil, source: String? = nil) {
        self.id = id; self.method = method; self.params = params; self.source = source
    }
}

public struct RPCResponse: Codable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int?
    public var result: JSONValue?
    public var error: RPCError?
    public init(id: Int? = nil, result: JSONValue? = nil, error: RPCError? = nil) {
        self.id = id; self.result = result; self.error = error
    }
}

public struct RPCNotification: Encodable, Sendable {
    public var jsonrpc = "2.0"
    public var method: String
    public var params: JSONValue?
    public init(method: String, params: JSONValue? = nil) { self.method = method; self.params = params }
}

public struct WireMessage: Decodable, Sendable {
    public var id: Int?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: RPCError?
}

public enum RPCCodec {
    public static var decoder: JSONDecoder { OrchestraJSON.decoder }
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try OrchestraJSON.wire.encode(value)
        data.append(0x0A)
        return data
    }
}
```

> Preserve the exact field defaults and behavior — only visibility changes plus the explicit memberwise `init`s that a `public` struct with cross-module construction needs (Swift synthesizes only an `internal` memberwise init). Add an `init` **only** for structs the daemon/CLI construct across the boundary; leave `WireMessage` (decode-only) without one.

- [ ] **Step 4: Make `UDSSocket.swift` `UDS` + `LineReader` `public`**

In `Sources/OrchestraKit/Control/UDSSocket.swift`:
- Change `enum UDS` → `public enum UDS` and add `public` to the `static` methods called cross-module: `listen(path:backlog:)`, `connect(path:)`, `accept(_:)`, `writeAll(_:_:)`, `read(_:into:)`. Leave the `private` posix* helpers and `suppressSIGPIPE`/`setPath`/`errnoString` private.
- Change `final class LineReader` → `public final class LineReader`; make its `init(fd:)` and `next()` `public`.

- [ ] **Step 5: Make `closeFD` `public`**

In `Sources/OrchestraKit/Platform.swift`, change `func closeFD(_ fd: Int32)` → `public func closeFD(_ fd: Int32)`.

- [ ] **Step 6: Rebuild until the seam is closed**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`. If further `inaccessible` errors appear (e.g. a member of `ConnectionState`, already `public`, or a helper missed above), add `public` to exactly that symbol and rebuild. Do not add `public` to anything the compiler does not demand — keep the Kit surface minimal.

- [ ] **Step 7: Run the tests (incl. `TransportReconnectTests`, which names `RPCCodec`/`RPCRequest`/`WireMessage`)**

Run: `swift test 2>&1 | tail -15`
Expected: same count, 0 failures. `TransportReconnectTests` sees the now-`public` types via `@_exported import OrchestraKit` (through `import OrchestraCore`).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(F1): move Transport/RPC/UDS/ControlClient into OrchestraKit; publicize cross-seam symbols"
```

---

## Task 3: Split `Commands.swift` into `CommandCatalog` (Kit) + `CommandRegistry` (Core)

**Files:**
- Create: `Sources/OrchestraKit/CommandCatalog.swift`
- Rename + rewrite: `Sources/OrchestraCore/Commands.swift` → `Sources/OrchestraCore/CommandRegistry.swift`
- Create: `Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift`
- Modify: `Sources/orchestra-mcp/main.swift`, `Package.swift` (MCP dep, D4)

**Interfaces:**
- Produces (Kit): `struct CommandSchema { public let name, summary: String; public let params: JSONValue }`, `enum CommandCatalog { public static let all: [CommandSchema]; public static func schema(_ name: String) -> CommandSchema? }` + `public static` schema builders (`schema`/`strProp`/`intProp`/`boolProp`/`refProp`/`colProp`) — the last uses `Column.allCases` (Kit).
- Produces (Core): `struct Command { public let schema: CommandSchema; public let run: @Sendable (OrchestraService, JSONValue, ActivitySource) async throws -> JSONValue; public var name: String { schema.name } … }` and `struct CommandRegistry` unchanged in its public API (`init()`, `command(_:)`, `commands`, `names`).
- Consumes: the catalog is paired with handlers by name in `CommandRegistry.build()`.

- [ ] **Step 1: Write the drift-guard test first (it will fail to compile until the split exists)**

Create `Tests/OrchestraCoreTests/CommandRegistryCatalogTests.swift`:

```swift
import XCTest
@testable import OrchestraCore   // @_exported brings in OrchestraKit's CommandCatalog

final class CommandRegistryCatalogTests: XCTestCase {
    // Every catalog schema has exactly one handler, and vice-versa — prevents drift after the split.
    func testRegistryCoversExactlyTheCatalog() {
        let catalogNames = Set(CommandCatalog.all.map(\.name))
        let registryNames = Set(CommandRegistry().names)
        XCTAssertEqual(catalogNames, registryNames,
                       "CommandRegistry handlers and CommandCatalog schemas must match 1:1")
    }

    // The registry surfaces the catalog's schema for each command (single source of truth).
    func testRegistryExposesCatalogSchema() {
        let reg = CommandRegistry()
        for schema in CommandCatalog.all {
            let cmd = reg.command(schema.name)
            XCTAssertNotNil(cmd, "missing handler for \(schema.name)")
            XCTAssertEqual(cmd?.summary, schema.summary)
            XCTAssertEqual(cmd?.params, schema.params)
        }
    }

    // The canonical set is complete (guards an accidental drop during the move).
    func testCatalogHasAllCommands() {
        XCTAssertEqual(Set(CommandCatalog.all.map(\.name)), [
            "list", "spawn", "move", "send", "inbox", "inbox-edit", "inbox-remove",
            "inbox-reorder", "wait", "handoff", "status", "archive", "reopen", "restart",
            "resume", "shell", "inspect", "closeShell", "exec", "sessions", "trustState",
            "batch-spawn", "trust",
        ])
    }
}
```

- [ ] **Step 2: Create `CommandCatalog.swift` in Kit with all 23 schemas + the builders**

Create `Sources/OrchestraKit/CommandCatalog.swift`. Move the schema builders and every command's `name`/`summary`/`params` **verbatim** from the current `Commands.swift` (the `params:` blocks and the `schema(...)`/`*Prop()` helpers). Structure:

```swift
import Foundation

/// The canonical command vocabulary — name + summary + JSON-schema params — with NO execution.
/// The daemon binds handlers to these in `CommandRegistry`; the MCP bridge builds tools from them;
/// a phone client builds/validates requests from them. Single source of truth for command shape.
public struct CommandSchema: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let params: JSONValue
    public init(name: String, summary: String, params: JSONValue) {
        self.name = name; self.summary = summary; self.params = params
    }
}

public enum CommandCatalog {
    public static func schema(_ name: String) -> CommandSchema? { byName[name] }
    private static let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static let all: [CommandSchema] = [
        CommandSchema(name: "list", summary: "List cards (optionally by column).",
                      params: schema(["col": colProp()], required: [])),
        CommandSchema(name: "spawn",
                      summary: "Spawn a new agent. Only `prompt` is free text — no title/desc.",
                      params: schema([
                          "prompt": strProp("Initial prompt — what the agent should start working on"),
                          "repo": strProp("Repository root (allowlisted). Omit for a freeform (cwd) card."),
                          "branch": strProp("Working branch. Omit for a freeform (cwd) card."),
                          "cwd": strProp("Freeform: run in this existing directory — no worktree is cut and "
                              + "the path is trusted via the sandbox (not the allowlist). Omit repo/branch when set."),
                          "access": strProp("'readWrite' (default) or 'readOnly' (agent cannot edit/write/commit)."),
                          "scratch": boolProp("Scratch: create a fresh throwaway ~/.orchestra/scratch/<id> dir, "
                              + "run there, and rm -rf it on archive. Omit repo/branch/cwd when set."),
                          "model": strProp("Model id (from the adapter's list)"),
                          "agent": strProp("Agent adapter to run: 'claude-code' (default) or 'codex'. Omit to "
                              + "infer from `model`, else use the configured default agent."),
                          "col": colProp(startInOnly: true),
                          "seed": strProp("Fork/fan-out context (the parent slice / handoff summary) the "
                              + "fresh card opens on — folded ahead of `prompt` into the launch turn."),
                      ], required: ["prompt"])),
        // … repeat for the remaining 21 commands, copying name/summary/params verbatim from the
        //   original Commands.swift (move, send, inbox, inbox-edit, inbox-remove, inbox-reorder,
        //   wait, handoff, status, archive, reopen, restart, resume, shell, inspect, closeShell,
        //   exec, sessions, trustState, batch-spawn, trust). Do NOT alter any description string.
    ]

    // MARK: - schema builders (moved verbatim from Commands.swift; now public for Kit consumers)
    public static func schema(_ props: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { .string($0) }),
        ])
    }
    public static func strProp(_ desc: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(desc)])
    }
    public static func intProp(_ desc: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(desc)])
    }
    public static func boolProp(_ desc: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(desc)])
    }
    public static func refProp() -> JSONValue {
        strProp("Card ref — UUID, shortId, or orchestra://task/<ref> URI")
    }
    public static func colProp(startInOnly: Bool = false) -> JSONValue {
        let cols = startInOnly ? ["plan", "impl"] : Column.allCases.map(\.rawValue)
        return .object([
            "type": .string("string"),
            "enum": .array(cols.map { .string($0) }),
            "description": .string(startInOnly ? "Start in: plan or impl" : "Column"),
        ])
    }
}
```

> The `// … repeat` comment marks a **mechanical copy**, not a placeholder: paste each remaining `CommandSchema(name:summary:params:)` using the exact literals from `Commands.swift`. The `testCatalogHasAllCommands` + `testRegistryExposesCatalogSchema` tests fail until all 23 are present and match, so completeness is machine-checked.

- [ ] **Step 3: Rewrite `Commands.swift` → `CommandRegistry.swift` (handlers only, paired to the catalog)**

```bash
git mv Sources/OrchestraCore/Commands.swift Sources/OrchestraCore/CommandRegistry.swift
```

Rewrite it so `Command` wraps a `CommandSchema` + a handler, and `build()` pairs each catalog entry with its handler by name. The handler *bodies* are the exact closures currently in `Commands.swift` — move each verbatim:

```swift
import Foundation

/// One executable command: a `CommandSchema` (from OrchestraKit) bound to a daemon handler.
public struct Command: Sendable {
    public let schema: CommandSchema
    public let run: @Sendable (OrchestraService, JSONValue, ActivitySource) async throws -> JSONValue
    public var name: String { schema.name }
    public var summary: String { schema.summary }
    public var params: JSONValue { schema.params }
}

public struct CommandRegistry: Sendable {
    public let commands: [Command]
    private let byName: [String: Command]

    public init() {
        self.commands = CommandRegistry.build()
        self.byName = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
    }
    public func command(_ name: String) -> Command? { byName[name] }
    public var names: [String] { commands.map(\.name) }

    private typealias Handler = @Sendable (OrchestraService, JSONValue, ActivitySource) async throws -> JSONValue

    private static func build() -> [Command] {
        let handlers: [String: Handler] = [
            "list": { svc, p, src in
                let col = p.optString("col").flatMap(Column.init(rawValue:))
                let tasks = await svc.list(col)
                return try JSONValue(encodable: tasks)
            },
            "spawn": { svc, p, src in
                let input = SpawnInput(
                    prompt: try p.string("prompt"),
                    repo: p.optString("repo") ?? "", branch: p.optString("branch") ?? "",
                    model: p.optString("model"),
                    startIn: p.optString("col").flatMap(StartIn.init(rawValue:)),
                    agentId: p.optString("agent"),
                    cwd: p.optString("cwd"),
                    access: p.optString("access").flatMap(CardAccess.init(rawValue:)) ?? .readWrite,
                    scratch: p["scratch"]?.boolValue ?? false,
                    seed: p.optString("seed"))
                let task = try await svc.spawn(input, source: src)
                return try JSONValue(encodable: task)
            },
            // … one entry per remaining command, body copied verbatim from the old Commands.swift
            //   closures (move, send, …, trust). Keys must exactly equal the CommandCatalog names.
        ]
        // Pair each catalog schema with its handler; a missing handler is a programmer error caught
        // here (and by CommandRegistryCatalogTests).
        return CommandCatalog.all.map { schema in
            guard let run = handlers[schema.name] else {
                fatalError("F1: no handler bound for command '\(schema.name)'")
            }
            return Command(schema: schema, run: run)
        }
    }
}
```

> Each handler body is the exact closure from the original `Commands.swift` (same `svc.*` calls, same error throwing, same return). Nothing about execution changes — only where the *schema* half lives.

- [ ] **Step 4: Repoint `orchestra-mcp` to the catalog + Kit-only dependency (D4)**

In `Sources/orchestra-mcp/main.swift`:
- Change `import OrchestraCore` → `import OrchestraKit`.
- Delete `let registry = CommandRegistry()`.
- Change the tools list to read the catalog:

```swift
_ = await server.withMethodHandler(ListTools.self) { _ in
    let tools = CommandCatalog.all.map { s in
        Tool(name: s.name, description: s.summary, inputSchema: toMCPValue(s.params))
    }
    return ListTools.Result(tools: tools)
}
```

In `Package.swift`, change the MCP target dependency from `"OrchestraCore"` to `"OrchestraKit"`:

```swift
        .executableTarget(
            name: "orchestra-mcp",
            dependencies: ["OrchestraKit", .product(name: "MCP", package: "swift-sdk")]
        ),
```

- [ ] **Step 5: Update the daemon dispatch call site (no logic change)**

`ControlServer.swift` uses `registry.command(req.method)` then `cmd.run(...)` — unchanged (the `Command` public API still exposes `name`/`summary`/`params`/`run`). Verify no other Core site referenced the old `Command(name:summary:params:){...}` initializer:

Run: `grep -rn "Command(name:" Sources/OrchestraCore/`
Expected: no matches (the only initializer usage was inside `Commands.swift`, now replaced).

- [ ] **Step 6: Build + run the drift test**

Run: `swift build 2>&1 | tail -10 && swift test --filter CommandRegistryCatalogTests 2>&1 | tail -15`
Expected: `Build complete!` and the 3 catalog tests pass. If `testRegistryCoversExactlyTheCatalog` fails, a command was dropped from either half — add it.

- [ ] **Step 7: Full test run**

Run: `swift test 2>&1 | tail -15`
Expected: baseline count **+3** (the new catalog tests), 0 failures.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(F1): split Command schema (OrchestraKit CommandCatalog) from execution (CommandRegistry); MCP → Kit-only"
```

---

## Task 4: iOS-isolation gate — prove `OrchestraKit` is client-safe

**Files:**
- Create: `scripts/typecheck-kit-ios.sh`

**Interfaces:**
- Consumes: the completed `OrchestraKit` target.
- Produces: a repeatable acceptance gate (source audit + iOS-SDK build of Kit in isolation).

- [ ] **Step 1: Write the guard script**

Create `scripts/typecheck-kit-ios.sh`:

```bash
#!/usr/bin/env bash
# F1 acceptance gate: OrchestraKit must be client-safe.
#  (1) zero Foundation.Process / posix_spawn / AppKit / UIKit references, and
#  (2) it typechecks against the iOS SDK in isolation.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== (1) source audit: forbidden references in OrchestraKit =="
if grep -rnE 'import AppKit|import UIKit|Foundation\.Process|posix_spawn|\bProcess\(' Sources/OrchestraKit/ ; then
  echo "FAIL: OrchestraKit contains a forbidden client-unsafe reference (see above)"; exit 1
fi
echo "ok: no Process/AppKit/UIKit references"

echo "== (2) iOS-SDK typecheck of the OrchestraKit target in isolation =="
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
swift build --target OrchestraKit \
  -Xswiftc -sdk -Xswiftc "$SDK" \
  -Xswiftc -target -Xswiftc arm64-apple-ios17.0
echo "ok: OrchestraKit typechecks for arm64-apple-ios17.0"
```

Make it executable:

```bash
chmod +x scripts/typecheck-kit-ios.sh
```

> `\bProcess\(` matches `Process(` but not `ProcessInfo` — `Config` legitimately uses `ProcessInfo.processInfo.environment`, which exists on iOS and is allowed. If the isolated iOS build proves flaky offline (SDK not present / cross-build quirk), the source-audit half (1) is the deterministic gate; part (2) can be run on any Mac with Xcode. Do not weaken part (1).

- [ ] **Step 2: Run the gate**

Run: `scripts/typecheck-kit-ios.sh`
Expected: `ok: no Process/AppKit/UIKit references` then `ok: OrchestraKit typechecks for arm64-apple-ios17.0`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "test(F1): add iOS-isolation gate for OrchestraKit (no Process/AppKit + iOS typecheck)"
```

---

## Task 5: Full-matrix verification (desktop + Linux + app)

**Files:** none (runs every acceptance gate end-to-end).

- [ ] **Step 1: `swift build` + `swift test` (macOS, offline)**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -15`
Expected: `Build complete!`; baseline+3 tests, 0 failures.

- [ ] **Step 2: macOS app build after the import re-point**

Run: `scripts/build-app.sh 2>&1 | tail -5`
Expected: succeeds (the app links `OrchestraCore`, which now transitively pulls `OrchestraKit`; `@_exported` means no App source changes were needed).

- [ ] **Step 3: Linux daemon cross-build still resolves the new target**

Run: `source ~/.swiftly/env.sh && scripts/build-linux-daemon.sh 2>&1 | tail -15`
Expected: `orchestrad`/`orchestra`/`orchestra-mcp` all cross-compile for musl. `OrchestraKit` is pulled transitively (daemon/CLI via `OrchestraCore`; MCP directly). If the swiftly/musl toolchain is unavailable in this environment, record that this gate must be run where the Linux SDK is installed (per the [linux-daemon-cross-build] memory) and confirm the `Package.swift` edits introduce no macOS-only API into the cross-built products.

- [ ] **Step 4: iOS gate (re-run)**

Run: `scripts/typecheck-kit-ios.sh`
Expected: both `ok:` lines.

- [ ] **Step 5: Confirm no stray behavior change — diff is moves + visibility + the one split**

Run: `git diff --stat main...HEAD | tail -30`
Expected: mostly renames (`Sources/OrchestraCore/… -> Sources/OrchestraKit/…`), `Package.swift`, the new `Exports.swift` / `CommandCatalog.swift` / `CommandRegistry.swift` / test / script. No changes under `Agents/`, `Diff/`, `Keyboard/`, `OrchestraService*`.

- [ ] **Step 6: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "chore(F1): verify desktop/Linux/app/iOS gates green after core split" --allow-empty
```

---

## Self-review

**Spec coverage** (against the card scope + acceptance):
- Client-safe `OrchestraKit` target `.macOS(.v14)+.iOS(.v17)` — Task 1. ✔
- Contains `Model.swift`, `Control/{Transport,ControlClient,RPC,UDSSocket,LineReader}` (LineReader lives inside `UDSSocket.swift`; RPCCodec inside `RPC.swift`), `Connection`, `ConnectionStore`, `RemoteCommands`, `Config` path resolvers, command *schema*, shared enums (`CardOrigin`/`CardAccess`/`DeadReason`/`WaitReason`/`TmuxTarget`/`ExecResult`) — all in `Model.swift`/moved files (Tasks 1–3). ✔
- Daemon-only code stays in Core; Core depends on Kit — Tasks 1–3, D1. ✔
- Fix imports across orchestrad/orchestra/orchestra-mcp/tests — solved wholesale by `@_exported` (D1) + the MCP repoint (D4). ✔
- Acceptance gates encoded as Tasks 4–5 (swift build/test, linux cross-build, iOS-isolation zero-Process/AppKit, build-app). ✔
- F2 home recommendation (separate `OrchestraUI`, keep Kit UI-free) — stated. ✔
- Global constraints (no `agent==` branches [F1 doesn't touch adapters], minimal wire change [none], no desktop/Linux regression, small commits) — honored. ✔

**Placeholder scan:** the two `// … repeat`/`// … one entry per` comments are explicit **mechanical-copy** markers backed by the drift-guard tests (`CommandRegistryCatalogTests`), which fail until all 23 commands are present and schema-matched — not open-ended TODOs. Full literals for `list`/`spawn` are shown; the rest are verbatim moves from a file in-repo.

**Type consistency:** `CommandSchema` (Kit) ↔ `Command.schema` (Core) names/fields match; `CommandRegistry` public API (`init`/`command(_:)`/`commands`/`names`) is unchanged so `ControlServer`/MCP call sites hold; `closeFD`/`LineReader`/`UDS`/`RPC*` publicization matches the exact symbols the compiler flags in Task 2 Step 2.

**Open risk flagged to reviewer:** D2 (the schema split) is the only non-mechanical change; if F1 must shrink, defer it (keep `Commands.swift` in Core) and add the Kit catalog in F3/M4 — noted in D2.
