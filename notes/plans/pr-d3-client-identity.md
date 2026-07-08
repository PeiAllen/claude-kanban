# PR D3 — Per-client identity on the wire — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every control client a stable, per-install `clientId` that rides each `RPCRequest`, and have `ControlServer` track connection→clientId so ownership (D4) can attribute calls and detect a client's disconnect — fully backward-compatible (a missing `clientId` is tolerated for CLI/MCP).

**Architecture:** One additive, optional wire field (`RPCRequest.clientId`), stamped by `ControlClient` on every request and preserved across reconnects. A tiny `ClientIdentity` helper generates+persists the id per install (a file), so the same id survives app relaunch. Server-side, each `PeerConnection` records its caller's `clientId`; the server exposes a liveness snapshot (`connectedClientIds()`) and a `onClientDisconnect` teardown hook — the exact seam D4's ownership lease plugs into.

**Tech Stack:** Swift 6, SwiftPM, `swift-testing` (`import Testing`), UDS NDJSON JSON-RPC. All work lands in `Sources/OrchestraCore/` (these files move to `OrchestraKit` post-F1; D3 is independent of the F-track and builds on `main`/`mobile-impl-orchestration`).

## Global Constraints

- **Design for every agent (Claude AND Codex).** No `if agent == "claude"` branches. (D3 is agent-neutral wire plumbing — no agent branching needed.)
- **Daemon wire protocol changes stay minimal.** D3 IS a wire change: keep it a single *optional, additive* field. No new framing, no new required fields.
- **Do not regress the desktop or the Linux daemon build.** `swift build` / `swift test` stay offline-green; `scripts/build-app.sh` (macOS) and `scripts/build-linux-daemon.sh` keep working.
- **Small commits.** One task = one commit.
- **Backward-compatible.** Old clients (no `clientId` key) and anonymous callers (CLI/MCP passing `nil`) must keep working unchanged; a missing `clientId` is always tolerated.

---

## Design decisions (read before implementing)

1. **Wire shape.** Add `var clientId: String?` to `RPCRequest`, directly after the existing `source`. It is optional, so:
   - The synthesized `Codable` encoder uses `encodeIfPresent` → when `nil` the key is **omitted entirely** from the NDJSON line (truly additive; CLI/MCP frames are byte-identical to today).
   - The synthesized decoder tolerates a missing key → `nil` (old clients decode fine).
   - The synthesized memberwise initializer gives optional properties an implicit `nil` default (this is why `RPCRequest(id: 1, method: "ping")` already compiles omitting `params`/`source`), so **every existing `RPCRequest(...)` call site keeps compiling** with no change.

2. **Handshake = every request.** Because `clientId` rides `RPCRequest`, it is present on `subscribe` *and* every other call. There is no separate handshake message. `ControlClient.subscribe()` re-issues its `subscribe` RPC through the normal `call()` path on reconnect, so the id is re-sent automatically — no extra code for the "re-sent across reconnects" requirement.

3. **Same id across reconnects.** `clientId` is a stored property on the `ControlClient` instance. A reconnect reuses the same instance → same id. Across *process relaunch*, `ClientIdentity.persistentId(at:)` reads the id back from disk.

4. **Where the id is generated/persisted.** A small pure helper `ClientIdentity.persistentId(at:)` does read-or-generate-and-write against a file path. `ControlClient` itself only *carries* an injected `clientId` (matching how `source` is injected) — it does no path logic or file policy. This keeps `ControlClient` platform-free (it moves to iOS-safe `OrchestraKit` in F1) and makes persistence trivially unit-testable. The macOS app resolves `Config.clientIdPath` and passes the result in.

5. **Anonymous callers stay anonymous.** `clientId` defaults to `nil` in every `ControlClient` initializer. CLI (`CLIRunner`), MCP (`orchestra-mcp/main.swift`), and the agent reporter (`ReportHelper`) keep the default and are **not modified** — they send no `clientId` and the server tolerates it.

6. **Server tracking + the D4 seam.** Each `PeerConnection` records the caller's `clientId` (set from the first request that carries one; idempotent thereafter). The server exposes exactly two things D4 consumes, both additive:
   - `PeerConnection.clientId` — readable inside `dispatch(_:_:source:)`, which already has `conn` in scope, so D4's inline ownership verbs can attribute a call to its connection's identity.
   - `ControlServer.onClientDisconnect: (@Sendable (String) -> Void)?` — fired **once** per connection teardown (read-loop EOF *or* a broken write) with the connection's `clientId`, so D4 can mark that client's leases stale.
   - `ControlServer.connectedClientIds() -> Set<String>` — a liveness snapshot for D4. **Note for D4:** a reconnecting client briefly disappears from this set (old connection torn down, new one not yet subscribed), which is exactly why D4 must use a heartbeat grace window rather than treating disconnect/absence as immediate ownership loss.

---

## File structure

| File | Change | Responsibility |
|---|---|---|
| `Sources/OrchestraCore/Control/RPC.swift` | modify | Add the optional `clientId` wire field to `RPCRequest`. |
| `Sources/OrchestraCore/Control/ClientIdentity.swift` | **create** | Pure generate-or-load-and-persist helper. |
| `Sources/OrchestraCore/Config.swift` | modify | Add `clientIdPath` resolver. |
| `Sources/OrchestraCore/Control/ControlClient.swift` | modify | Hold + stamp `clientId` on every request; new init params (defaulted `nil`). |
| `Sources/OrchestraCore/Control/ControlServer.swift` | modify | Record connection→clientId; `onClientDisconnect` hook; `connectedClientIds()`; unify teardown. |
| `App/BoardModel.swift` | modify | Resolve + persist the app's clientId once and pass it to both `ControlClient` init sites. |
| `Tests/OrchestraCoreTests/ClientIdentityTests.swift` | **create** | Wire-shape + persistence-helper unit tests. |
| `Tests/OrchestraCoreTests/TransportReconnectTests.swift` | modify | Add reconnect-preserves-id + anonymous-no-id tests (reuses the file's `FakeTransport`/`FakeBox`). |
| `Tests/OrchestraCoreTests/ClientIdentityServerTests.swift` | **create** | Server tracking + disconnect-detection integration tests over a real UDS. |

---

## Task 1: Add the optional `clientId` wire field to `RPCRequest`

**Files:**
- Modify: `Sources/OrchestraCore/Control/RPC.swift:9`
- Test: `Tests/OrchestraCoreTests/ClientIdentityTests.swift` (create)

**Interfaces:**
- Produces: `RPCRequest.clientId: String?` — optional, additive; omitted from the wire when `nil`; decodes to `nil` when absent. Consumed by Tasks 3–5 (client stamps it, server reads it).

- [ ] **Step 1: Write the failing test**

Create `Tests/OrchestraCoreTests/ClientIdentityTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("D3 — clientId wire shape + persistence helper")
struct ClientIdentityTests {

    @Test("RPCRequest carries clientId when set, omits it when nil, and tolerates a missing key")
    func clientIdWireShape() throws {
        // Set → present on the wire.
        let withId = RPCRequest(id: 1, method: "ping", clientId: "abc-123")
        let line = String(decoding: try RPCCodec.line(withId), as: UTF8.self)
        #expect(line.contains("\"clientId\":\"abc-123\""))

        // Nil (CLI/MCP style) → key omitted entirely (additive on the wire).
        let withoutId = RPCRequest(id: 2, method: "ping")
        let line2 = String(decoding: try RPCCodec.line(withoutId), as: UTF8.self)
        #expect(!line2.contains("clientId"))

        // An older client's frame (no clientId key) decodes with clientId == nil.
        let legacy = Data(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#.utf8)
        let decoded = try RPCCodec.decoder.decode(RPCRequest.self, from: legacy)
        #expect(decoded.clientId == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClientIdentityTests/clientIdWireShape`
Expected: FAIL to compile — `RPCRequest` has no `clientId` argument.

- [ ] **Step 3: Add the field**

In `Sources/OrchestraCore/Control/RPC.swift`, add `clientId` right after `source` (line 9):

```swift
struct RPCRequest: Codable, Sendable {
    var jsonrpc = "2.0"
    var id: Int?            // nil => notification (no response expected)
    var method: String
    var params: JSONValue?
    var source: String?    // calling client: app/cli/mcp (for activity attribution)
    var clientId: String?  // D3: stable per-install client identity; nil for anonymous CLI/MCP.
                           // Server tracks connection→clientId so D4 attributes ownership + detects disconnect.
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClientIdentityTests/clientIdWireShape`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Control/RPC.swift Tests/OrchestraCoreTests/ClientIdentityTests.swift
git commit -m "feat(d3): add optional clientId field to RPCRequest (additive wire)"
```

---

## Task 2: `ClientIdentity` persistence helper + `Config.clientIdPath`

**Files:**
- Create: `Sources/OrchestraCore/Control/ClientIdentity.swift`
- Modify: `Sources/OrchestraCore/Config.swift` (add `clientIdPath`, near `tasksPath` at `:84`)
- Test: `Tests/OrchestraCoreTests/ClientIdentityTests.swift` (add tests)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ClientIdentity.persistentId(at path: String) -> String` — returns the existing id at `path`, else generates a lowercased UUID, best-effort persists it, and returns it. Stable across calls.
  - `Config.clientIdPath: String` = `"\(dataDir)/client-id"`. Consumed by Task 6 (app wiring).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/OrchestraCoreTests/ClientIdentityTests.swift` (inside the `ClientIdentityTests` struct):

```swift
    @Test("persistentId generates once and is stable across calls")
    func persistentIdStable() {
        let dir = "/tmp/orch-cid-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/client-id"
        let a = ClientIdentity.persistentId(at: path)   // generates + writes (dir auto-created)
        let b = ClientIdentity.persistentId(at: path)   // reads back
        #expect(!a.isEmpty)
        #expect(a == b)
    }

    @Test("persistentId returns a pre-seeded id verbatim")
    func persistentIdSeeded() throws {
        let dir = "/tmp/orch-cid-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/client-id"
        try "seeded-id-42".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(ClientIdentity.persistentId(at: path) == "seeded-id-42")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "ClientIdentityTests/persistentId"`
Expected: FAIL to compile — `ClientIdentity` is undefined.

- [ ] **Step 3: Create the helper**

Create `Sources/OrchestraCore/Control/ClientIdentity.swift`:

```swift
import Foundation

/// A stable, per-install identifier a control client stamps on every `RPCRequest` (via
/// `ControlClient.clientId`) so the daemon can attribute ownership (D4) and detect when *this* client
/// disconnects. Generated once and persisted to a file; the SAME id is reused across reconnects and
/// app relaunches. Anonymous callers (CLI, MCP) pass `nil` and never touch this — a missing clientId
/// is always tolerated.
public enum ClientIdentity {
    /// Load the id persisted at `path`, or generate + persist a fresh one and return it.
    ///
    /// Best-effort persistence: if the id can't be written (e.g. a read-only filesystem), a freshly
    /// generated id is still returned for this process — identity just won't survive a relaunch.
    public static func persistentId(at path: String) -> String {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let s = String(data: data, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let fresh = UUID().uuidString.lowercased()
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? Data(fresh.utf8).write(to: URL(fileURLWithPath: path))
        return fresh
    }
}
```

- [ ] **Step 4: Add the Config resolver**

In `Sources/OrchestraCore/Config.swift`, after `tasksPath` (line 84), add:

```swift
    /// Per-install control-client identity (D3), a sibling of `tasksPath`. The app persists a stable
    /// clientId here so the daemon can attribute ownership + detect this client's disconnect (D4).
    public static var clientIdPath: String { "\(dataDir)/client-id" }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter "ClientIdentityTests/persistentId"`
Expected: PASS (both).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Control/ClientIdentity.swift Sources/OrchestraCore/Config.swift Tests/OrchestraCoreTests/ClientIdentityTests.swift
git commit -m "feat(d3): ClientIdentity persistence helper + Config.clientIdPath"
```

---

## Task 3: `ControlClient` carries + stamps `clientId` (preserved across reconnect)

**Files:**
- Modify: `Sources/OrchestraCore/Control/ControlClient.swift:9,26,31,77`
- Test: `Tests/OrchestraCoreTests/TransportReconnectTests.swift` (add a `FakeBox` accessor + 2 tests)

**Interfaces:**
- Consumes: `RPCRequest.clientId` (Task 1).
- Produces:
  - `ControlClient.clientId: String?` — stored, immutable per instance.
  - Both initializers gain a trailing `clientId: String? = nil` parameter.
  - Every `RPCRequest` built in `call(...)` carries this `clientId`; `subscribe()` inherits it (it calls through `call`), so reconnect re-subscribes with the same id.

- [ ] **Step 1: Add a test accessor to `FakeBox`**

In `Tests/OrchestraCoreTests/TransportReconnectTests.swift`, inside `final class FakeBox`, add (next to `subscribeCount`):

```swift
        /// The clientId carried by each `subscribe` frame that was written (in write order).
        var subscribeClientIds: [String?] {
            lock.withLock {
                writes.compactMap { try? RPCCodec.decoder.decode(RPCRequest.self, from: $0) }
                      .filter { $0.method == "subscribe" }
                      .map { $0.clientId }
            }
        }
```

- [ ] **Step 2: Write the failing tests**

In the same file, add to the `TransportReconnectTests` struct:

```swift
    @Test("clientId is stamped on requests and preserved across a reconnect")
    func clientIdAcrossReconnect() async throws {
        let box = FakeBox()
        let client = ControlClient(transport: { FakeTransport(box) }, source: .app, clientId: "phone-xyz")
        try client.connect()
        _ = client.subscribe()                                       // subscribe #1
        try await _Concurrency.Task.sleep(for: .milliseconds(120))
        box.dropCurrent()                                            // force a reconnect
        try await _Concurrency.Task.sleep(for: .milliseconds(700))   // backoff + reconnect + re-subscribe
        let ids = box.subscribeClientIds
        #expect(ids.count >= 2)                                      // subscribed on both transports
        #expect(ids.allSatisfy { $0 == "phone-xyz" })               // SAME id after reconnect
        client.close()
    }

    @Test("an anonymous client (nil clientId) writes no clientId — CLI/MCP back-compat")
    func anonymousClientNoId() async throws {
        let box = FakeBox()
        let client = ControlClient(transport: { FakeTransport(box) }, source: .cli)   // clientId defaults nil
        try client.connect()
        _ = client.subscribe()
        try await _Concurrency.Task.sleep(for: .milliseconds(120))
        #expect(box.subscribeClientIds.allSatisfy { $0 == nil })
        client.close()
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter "TransportReconnectTests/clientIdAcrossReconnect"`
Expected: FAIL to compile — `ControlClient(...)` has no `clientId:` argument.

- [ ] **Step 4: Add the property, init params, and stamp**

In `Sources/OrchestraCore/Control/ControlClient.swift`:

Add the stored property after `source` (line 9):

```swift
    public let source: ActivitySource
    public let clientId: String?
```

Update the convenience init (line 26):

```swift
    /// Back-compat convenience: a UDS client by socket path.
    public convenience init(socketPath: String = Config.socketPath, source: ActivitySource = .app,
                            clientId: String? = nil) {
        self.init(transport: { UDSTransport(socketPath: socketPath) }, source: source, clientId: clientId)
    }
```

Update the designated init (line 31):

```swift
    /// Designated init: a factory so reconnect can mint a FRESH transport each attempt.
    public init(transport: @escaping @Sendable () -> Transport, source: ActivitySource = .app,
                clientId: String? = nil) {
        self.makeTransport = transport
        self.source = source
        self.clientId = clientId
    }
```

Stamp it in `call(...)` (line 77):

```swift
        let req = RPCRequest(id: id, method: method, params: params, source: source.rawValue, clientId: clientId)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter "TransportReconnectTests/clientIdAcrossReconnect"` then `swift test --filter "TransportReconnectTests/anonymousClientNoId"`
Expected: PASS (both).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Control/ControlClient.swift Tests/OrchestraCoreTests/TransportReconnectTests.swift
git commit -m "feat(d3): ControlClient stamps clientId on every request, preserved across reconnect"
```

---

## Task 4: `ControlServer` records connection→clientId + exposes `connectedClientIds()`

**Files:**
- Modify: `Sources/OrchestraCore/Control/ControlServer.swift` (`PeerConnection` at `:222`; `handle` at `:80`; new `connectedClientIds()`)
- Test: `Tests/OrchestraCoreTests/ClientIdentityServerTests.swift` (create)

**Interfaces:**
- Consumes: `RPCRequest.clientId` (Task 1); `ControlClient.clientId` (Task 3).
- Produces (D4-facing):
  - `PeerConnection.clientId: String?` — thread-safe read of the connection's identity; `PeerConnection.setClientId(_:)` sets it once. Readable inside `dispatch(_:_:source:)` (which has `conn`).
  - `ControlServer.connectedClientIds() -> Set<String>` — snapshot of clientIds across current subscriber connections.

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/ClientIdentityServerTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("D3 — server tracks connection→clientId", .serialized)
struct ClientIdentityServerTests {
    static func sock() -> String { "/tmp/orch-\(UUID().uuidString.prefix(8)).sock" }

    @Test("server records the caller's clientId and exposes it via connectedClientIds()")
    func serverTracksClientId() async throws {
        let env = TestEnv.make()
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }

        let client = ControlClient(socketPath: path, source: .app, clientId: "phone-77")
        try client.connect(); defer { client.close() }
        _ = client.subscribe()
        _ = try await client.call("ping")
        try await _Concurrency.Task.sleep(for: .milliseconds(80))

        #expect(server.connectedClientIds().contains("phone-77"))
    }

    @Test("an anonymous CLI client contributes no clientId and still works")
    func serverToleratesMissingClientId() async throws {
        let env = TestEnv.make()
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        try server.start(); defer { server.stop() }

        let cli = ControlClient(socketPath: path, source: .cli)   // no clientId
        try cli.connect(); defer { cli.close() }
        _ = cli.subscribe()
        #expect(try await cli.call("ping")["ok"]?.boolValue == true)
        try await _Concurrency.Task.sleep(for: .milliseconds(80))

        #expect(server.connectedClientIds().isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClientIdentityServerTests/serverTracksClientId`
Expected: FAIL to compile — `ControlServer` has no `connectedClientIds()`.

- [ ] **Step 3: Add `clientId` storage to `PeerConnection`**

In `Sources/OrchestraCore/Control/ControlServer.swift`, in `final class PeerConnection` (around `:222`), add alongside the existing `closed`/`broken` state (which are guarded by its `lock`):

```swift
    private var _clientId: String?

    /// The caller's stable per-install identity (D3). Set once from the first request that carries a
    /// clientId; nil for anonymous CLI/MCP connections. Read by the ownership lease (D4).
    var clientId: String? { lock.withLock { _clientId } }

    /// Record the connection's clientId. Idempotent: a client sends the same id on every request, so
    /// only the first non-nil set sticks.
    func setClientId(_ id: String) { lock.withLock { if _clientId == nil { _clientId = id } } }
```

- [ ] **Step 4: Record it on every request**

In `handle(_ req:_ conn:)` (line 80), record the clientId before dispatch:

```swift
    private func handle(_ req: RPCRequest, _ conn: PeerConnection) async {
        if let cid = req.clientId { conn.setClientId(cid) }
        let source = ActivitySource(rawValue: req.source ?? "app") ?? .app
        // ...unchanged...
```

- [ ] **Step 5: Add the `connectedClientIds()` snapshot**

In `ControlServer`, next to `removeSubscriber` (line 216), add:

```swift
    /// Snapshot of the clientIds with at least one live subscriber connection. D4 uses this for
    /// liveness. NOTE: a reconnecting client briefly disappears here (old connection torn down before
    /// the new one subscribes), so D4 must use a heartbeat grace window, not treat absence as loss.
    public func connectedClientIds() -> Set<String> {
        lock.withLock { Set(subscribers.values.compactMap { $0.clientId }) }
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter ClientIdentityServerTests/serverTracksClientId` then `swift test --filter ClientIdentityServerTests/serverToleratesMissingClientId`
Expected: PASS (both).

- [ ] **Step 7: Commit**

```bash
git add Sources/OrchestraCore/Control/ControlServer.swift Tests/OrchestraCoreTests/ClientIdentityServerTests.swift
git commit -m "feat(d3): ControlServer records connection->clientId + connectedClientIds()"
```

---

## Task 5: `onClientDisconnect` — detect a client's disconnect (the D4 hook)

**Files:**
- Modify: `Sources/OrchestraCore/Control/ControlServer.swift` (add `onClientDisconnect`; unify teardown in `serve` at `:74` and the `subscribe` `onBroken` at `:110`; add a once-guard to `PeerConnection`)
- Test: `Tests/OrchestraCoreTests/ClientIdentityServerTests.swift` (add 2 tests)

**Interfaces:**
- Consumes: `PeerConnection.clientId` (Task 4).
- Produces (D4-facing): `ControlServer.onClientDisconnect: (@Sendable (String) -> Void)?` — fired **exactly once** per connection teardown (read-loop EOF or broken write) with the connection's `clientId`; never fired for an anonymous (nil-clientId) connection.

- [ ] **Step 1: Write the failing tests**

Add to `ClientIdentityServerTests` (`Tests/OrchestraCoreTests/ClientIdentityServerTests.swift`):

```swift
    @Test("closing a client fires onClientDisconnect with its clientId")
    func disconnectFiresCallback() async throws {
        let env = TestEnv.make()
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        let fired = ClientIdBox()
        server.onClientDisconnect = { id in _Concurrency.Task { await fired.add(id) } }
        try server.start(); defer { server.stop() }

        let client = ControlClient(socketPath: path, source: .app, clientId: "phone-gone")
        try client.connect()
        _ = client.subscribe()
        _ = try await client.call("ping")
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        client.close()                                              // EOF → server-side teardown
        try await _Concurrency.Task.sleep(for: .milliseconds(200))

        #expect(await fired.ids == ["phone-gone"])                 // fired exactly once, with the id
    }

    @Test("an anonymous client's disconnect fires nothing")
    func anonymousDisconnectSilent() async throws {
        let env = TestEnv.make()
        let path = Self.sock()
        let server = ControlServer(service: env.svc, socketPath: path)
        let fired = ClientIdBox()
        server.onClientDisconnect = { id in _Concurrency.Task { await fired.add(id) } }
        try server.start(); defer { server.stop() }

        let cli = ControlClient(socketPath: path, source: .cli)    // no clientId
        try cli.connect()
        _ = cli.subscribe()
        _ = try await cli.call("ping")
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        cli.close()
        try await _Concurrency.Task.sleep(for: .milliseconds(200))

        #expect(await fired.ids.isEmpty)
    }
```

And add this actor at the bottom of the file (top-level, after the struct):

```swift
actor ClientIdBox {
    private(set) var ids: [String] = []
    func add(_ s: String) { ids.append(s) }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClientIdentityServerTests/disconnectFiresCallback`
Expected: FAIL to compile — `onClientDisconnect` is undefined.

- [ ] **Step 3: Add the callback property**

In `Sources/OrchestraCore/Control/ControlServer.swift`, next to `onConfigChanged` (line 10):

```swift
    public var onConfigChanged: (@Sendable (Config) -> Void)?
    /// Fired once per connection teardown with the connection's clientId (nil-clientId connections
    /// never fire). D4 wires its ownership lease here to mark a disconnected client's leases stale.
    public var onClientDisconnect: (@Sendable (String) -> Void)?
```

- [ ] **Step 4: Add a once-guard to `PeerConnection`**

In `final class PeerConnection`, alongside the `clientId` storage from Task 4:

```swift
    private var disconnectNotified = false

    /// Returns true exactly once, so the server fires `onClientDisconnect` a single time even though
    /// teardown can be reached from both the read-loop EOF and a broken write.
    func markDisconnectNotified() -> Bool {
        lock.withLock { if disconnectNotified { return false }; disconnectNotified = true; return true }
    }
```

- [ ] **Step 5: Unify teardown**

Add a private `handleDisconnect` to `ControlServer` (near `removeSubscriber`, line 216):

```swift
    /// Single teardown path for a dropped connection: drop it as a subscriber, close it, and fire
    /// `onClientDisconnect` once if it had a known clientId. Reached from the read-loop EOF and from a
    /// broken write; the once-guard keeps the callback single-shot.
    private func handleDisconnect(_ conn: PeerConnection) {
        removeSubscriber(conn)
        conn.close()
        if let cid = conn.clientId, conn.markDisconnectNotified() {
            onClientDisconnect?(cid)
        }
    }
```

Route the read-loop end (`serve`, line 74) through it — replace:

```swift
        removeSubscriber(conn)
        conn.close()
    }
```

with:

```swift
        handleDisconnect(conn)
    }
```

And route the `subscribe` broken-write handler (line 110) through it — replace:

```swift
            conn.onBroken = { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.removeSubscriber(conn); conn.close()
            }
```

with:

```swift
            conn.onBroken = { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.handleDisconnect(conn)
            }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter ClientIdentityServerTests/disconnectFiresCallback` then `swift test --filter ClientIdentityServerTests/anonymousDisconnectSilent`
Expected: PASS (both).

- [ ] **Step 7: Run the full control suite (no regressions)**

Run: `swift test --filter ControlRoundTripTests` and `swift test --filter TransportReconnectTests`
Expected: PASS (existing round-trip, ring-replay, reconnect, and close tests still green — the teardown refactor is behavior-preserving for anonymous connections).

- [ ] **Step 8: Commit**

```bash
git add Sources/OrchestraCore/Control/ControlServer.swift Tests/OrchestraCoreTests/ClientIdentityServerTests.swift
git commit -m "feat(d3): ControlServer.onClientDisconnect fires once per teardown with clientId"
```

---

## Task 6: Wire the macOS app to persist + send its clientId

**Files:**
- Modify: `App/BoardModel.swift:101,106,190`

**Interfaces:**
- Consumes: `ClientIdentity.persistentId(at:)` + `Config.clientIdPath` (Task 2); `ControlClient(...,clientId:)` (Task 3).
- Produces: the desktop app now sends a stable per-install `clientId` on both the local and remote `ControlClient`; CLI/MCP/agent are intentionally left anonymous (default `nil`, unchanged).

> There is no App-target test target (tests live in `OrchestraCoreTests`/`IntegrationTests`), and the library-level behavior is already covered by Tasks 3–5. This task is a thin wiring change verified by a build.

- [ ] **Step 1: Add a stored clientId, resolved once**

In `App/BoardModel.swift`, add a property next to `client` (line 101):

```swift
    private(set) var client: ControlClient
    /// Stable per-install identity sent to the daemon so it can attribute ownership + detect this
    /// client's disconnect (D3/D4). Resolved once; the same id is reused for local and remote links.
    private let clientId = ClientIdentity.persistentId(at: Config.clientIdPath)
```

- [ ] **Step 2: Pass it at both `ControlClient` init sites**

In `init()` (line 106):

```swift
        client = ControlClient(socketPath: Config.socketPath, source: .app, clientId: clientId)
```

In `activate(_:)` (line 190):

```swift
            client = ControlClient(socketPath: sockPath, source: .app, clientId: clientId)
```

- [ ] **Step 3: Confirm CLI/MCP/agent stay anonymous (no edits)**

Verify these keep the default `nil` (no change expected — this is a read-only check):

Run: `grep -rn "ControlClient(" Sources/orchestra Sources/orchestra-mcp`
Expected: `CLIRunner.swift`, `ReportHelper.swift`, and `orchestra-mcp/main.swift` still pass only `socketPath:`/`source:` — no `clientId:`.

- [ ] **Step 4: Build the library + macOS app (no regressions)**

Run: `swift build`
Expected: builds clean.

Run: `scripts/build-app.sh`
Expected: the macOS app builds (if a lighter `scripts/typecheck-app.sh` exists, it may be used for a faster check).

- [ ] **Step 5: Commit**

```bash
git add App/BoardModel.swift
git commit -m "feat(d3): desktop app sends a persisted per-install clientId (CLI/MCP stay anonymous)"
```

---

## Final verification

- [ ] **Full offline test suite green:**

Run: `swift test`
Expected: all suites pass, including the new `ClientIdentityTests`, `ClientIdentityServerTests`, and the added `TransportReconnectTests` cases, with no regressions in `ControlRoundTripTests`.

- [ ] **Linux daemon still cross-compiles (no wire/build regression):**

Run: `source ~/.swiftly/env.sh && scripts/build-linux-daemon.sh`
Expected: builds (the change is additive Swift with no new platform APIs — `Data`/`FileManager`/`UUID` are Foundation, available on Linux).

- [ ] **macOS app builds:** `scripts/build-app.sh` green (from Task 6).

---

## Acceptance criteria mapping

| Acceptance requirement | Satisfied by |
|---|---|
| Server can **name which client sent a call** | Task 4 — `PeerConnection.clientId` recorded from `req.clientId` (readable in `dispatch`); `connectedClientIds()`. |
| Server can **detect that client's disconnect** | Task 5 — `onClientDisconnect(clientId)` fired once per teardown. |
| A client that **reconnects keeps the SAME clientId** | Task 3 — stored on the `ControlClient` instance, re-sent on re-`subscribe`; Task 2 persists it across relaunch. |
| **Missing clientId tolerated** (CLI/MCP still work) | Task 1 (optional field, omitted when nil) + Tasks 4/5 tests (`serverToleratesMissingClientId`, `anonymousDisconnectSilent`); CLI/MCP/agent unchanged (Task 6 Step 3). |
| Minimal, additive wire change | Task 1 — one optional field, key omitted when nil. |
| No desktop / Linux regressions | Final verification. |

## The interface D4 will consume (handoff summary)

- **Wire:** `RPCRequest.clientId: String?` — present on every request from an identified client (incl. `subscribe`); omitted for anonymous callers.
- **On the connection:** `PeerConnection.clientId: String?`, readable inside `ControlServer.dispatch(_:_:source:)` (which already receives `conn`). D4 adds its ownership verbs inline there and reads `conn.clientId` to attribute/validate — while the ownership RPCs also take an explicit `clientId` param per the design (`takeOverAgentTerminal(ref, clientId)` etc.), so the two can be cross-checked.
- **Disconnect:** `ControlServer.onClientDisconnect: (@Sendable (String) -> Void)?` — fired once when an identified connection tears down; D4 marks that client's leases stale.
- **Liveness:** `ControlServer.connectedClientIds() -> Set<String>`. **Caveat D4 must honor:** a reconnecting client momentarily leaves this set / triggers `onClientDisconnect`, so D4 uses a heartbeat + epoch grace window (design point 7) rather than treating a single disconnect as immediate ownership loss.
- **Persistence:** `ClientIdentity.persistentId(at: Config.clientIdPath)` — how a client gets its stable id.
