# First-Class Agent Hooks — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the agent hook system a first-class, core-owned **channel** — core owns the `HookEvent` vocabulary + `HookResponse` + one adapter-free dispatch; adapters own only format (`parse`/`sessionSource`/`encode`) at the edge and render their own hook file.

**Architecture:** Convert at the edge, dispatch in core. The `_report` client resolves its adapter from a baked `--agent <id>`, `parse`s the payload, sends a typed `hook(ref, event, report, source)` RPC, and `encode`s any returned `HookResponse` to stdout. Raw agent JSON never crosses the wire. The daemon's `handleHook` applies telemetry and composes existing `sessionBrief`/`drainForStop` into a neutral `HookResponse`. Hook-file render+install folds into each adapter's `prepareToLaunch`; `AdapterContext.hooksPath` (a Claude-ism) becomes agent-agnostic `orchestraBin`.

**Tech Stack:** Swift 6, Swift Testing (`@Test`/`#expect`), SwiftPM. Package at repo root; `swift build`, `swift test --filter <Suite>`.

**Design source of truth:** `notes/designs/first-class-hooks/` (layers 01–04, all approved). This plan operationalizes `03-implementation.md` (build order) + `02-contract.md` (per-file, file:line) + `04-tests.md`.

## Global Constraints

- **Behaviour-preserving refactor.** Same orientation text, same telemetry `StatusReport`s, same drain payload/caps. No user-facing change. Existing suites stay green.
- **No pre-change-session back-compat** — old sessions will be cleared; no fallback path.
- **A1 capability freeze holds** — no `AgentCapabilities` fields/variants added; only additive **defaulted** protocol members.
- **`_report` stays best-effort** — always exits 0; never fails the agent.
- **statusline never waits on the network** — its display renders locally, before any RPC.
- **No `git -C`**, commit only when a task says so, branch is `first-class-hooks` (already an isolated worktree).

## File Structure

| File | Responsibility | New/Modify |
|------|----------------|------------|
| `Sources/OrchestraCore/Control/HookChannel.swift` | `HookEvent`, `SessionSource`, `HookResponse`, `HookEnvelope` | **New** |
| `Sources/OrchestraCore/Agents/Adapter.swift` | `AdapterContext` (`orchestraBin`), protocol +`encode`/`sessionSource` defaults | Modify |
| `Sources/OrchestraCore/Agents/SessionBrief.swift` | Remove the envelope fn (moved to `HookEnvelope`) | Modify |
| `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift` | render in `prepareToLaunch`; `parse` kind cases; explicit `encode`; `Config.hooksPath` reads | Modify |
| `Sources/OrchestraCore/Agents/CodexAdapter.swift` | render in `prepareToLaunch`; explicit `encode` | Modify |
| `Sources/OrchestraCore/Control/HooksRenderer.swift` | `agentId:` param + `__AGENT_ID__` substitution | Modify |
| `Sources/OrchestraCore/Resources/claude-hooks.json`, `codex-hooks.json` | `--agent`; split events | Modify |
| `Sources/OrchestraCore/OrchestraService.swift` | `orchestraBin` init + `handleHook`; ctx sites | Modify |
| `Sources/OrchestraCore/OrchestraService+Recovery.swift` | ctx sites | Modify |
| `Sources/OrchestraCore/Control/ControlServer.swift` | add `hook`, remove `report`/`drain`/`sessionBrief` | Modify |
| `Sources/orchestra/ReportHelper.swift` | thin edge client | Modify |
| `Sources/orchestrad/main.swift` | delete `HooksRenderer` calls | Modify |
| `Tests/OrchestraCoreTests/*` | new + updated suites | Modify |

---

### Task 1: Core channel types

**Files:**
- Create: `Sources/OrchestraCore/Control/HookChannel.swift`
- Test: `Tests/OrchestraCoreTests/HookChannelTests.swift`

**Interfaces:**
- Produces: `enum HookEvent: String` (`statusline`/`session`/`prompt`/`pretool`/`posttool`/`notification`/`stop`/`sessionend`); `enum SessionSource: String` (`startup`/`resume`/`clear`/`compact`/`other`); `struct HookResponse { additionalContext: String?; continuation: String? }`; `enum HookEnvelope { additionalContext(String)->String; block(String)->String }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OrchestraCoreTests/HookChannelTests.swift
import Testing
@testable import OrchestraCore

@Suite struct HookChannelTests {
    @Test("HookEvent raw values map --event strings") func events() {
        #expect(HookEvent(rawValue: "session") == .sessionStart)
        #expect(HookEvent(rawValue: "pretool") == .preToolUse)
        #expect(HookEvent(rawValue: "posttool") == .postToolUse)
        #expect(HookEvent(rawValue: "stop") == .stop)
        #expect(HookEvent(rawValue: "orient") == nil)          // collapsed away
        #expect(HookEvent.sessionStart.rawValue == "session")
    }
    @Test("SessionSource parses, defaults handled by caller") func source() {
        #expect(SessionSource(rawValue: "compact") == .compact)
        #expect(SessionSource(rawValue: "startup") == .startup)
        #expect(SessionSource(rawValue: "bogus") == nil)
    }
    @Test("HookResponse round-trips") func response() throws {
        let r = HookResponse(additionalContext: "hi")
        let back = try JSONValue(encodable: r).decode(HookResponse.self)
        #expect(back == r)
    }
    @Test("HookEnvelope encodes the shared shapes") func envelope() {
        #expect(HookEnvelope.additionalContext("X").contains("\"additionalContext\":\"X\""))
        #expect(HookEnvelope.additionalContext("X").contains("\"hookEventName\":\"SessionStart\""))
        #expect(HookEnvelope.block("go").contains("\"decision\":\"block\""))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter HookChannelTests` → FAIL (types undefined).

- [ ] **Step 3: Implement**

```swift
// Sources/OrchestraCore/Control/HookChannel.swift
import Foundation

/// The core-owned hook vocabulary. rawValue == the `--event` string baked into the rendered hook file
/// (and the key the daemon dispatches on). No agent identity anywhere.
public enum HookEvent: String, Sendable, Codable, CaseIterable {
    case statusLine   = "statusline"
    case sessionStart = "session"      // Claude "session" + Codex "orient" collapse here
    case userPrompt   = "prompt"
    case preToolUse   = "pretool"
    case postToolUse  = "posttool"
    case notification = "notification"
    case stop         = "stop"
    case sessionEnd   = "sessionend"
}

/// How a sessionStart fired — gates orientation (skip on `.compact`).
public enum SessionSource: String, Sendable, Codable {
    case startup, resume, clear, compact, other
}

/// The agent-neutral receive payload core computes and the adapter encodes. Exactly one field is set.
public struct HookResponse: Sendable, Codable, Equatable {
    public var additionalContext: String?   // sessionStart → orientation
    public var continuation: String?         // stop → inbox-drain block reason
    public init(additionalContext: String? = nil, continuation: String? = nil) {
        self.additionalContext = additionalContext; self.continuation = continuation
    }
}

/// The stdout envelopes Claude & Codex share today. A shared HELPER adapters CALL from `encode` — never
/// an implicit default, so a divergent future agent can't silently inherit this shape (A1 philosophy).
public enum HookEnvelope {
    /// Claude/Codex SessionStart hooks read `hookSpecificOutput.additionalContext` from stdout.
    public static func additionalContext(_ context: String) -> String {
        let obj = JSONValue.object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("SessionStart"),
                "additionalContext": .string(context),
            ])
        ])
        if let data = try? obj.rawData(), let s = String(data: data, encoding: .utf8) { return s }
        return ""
    }
    /// The Stop-hook `decision:block` continuation.
    public static func block(_ reason: String) -> String { StopDrain.blockJSON(reason: reason) }
}
```

- [ ] **Step 4: Run to verify it passes** — `swift test --filter HookChannelTests` → PASS.

- [ ] **Step 5: Commit** — `git add … && git commit -m "feat(hooks): add HookEvent/HookResponse/HookEnvelope core channel types"`

---

### Task 2: Adapter seam — `encode` + `sessionSource`, envelope move

**Files:**
- Modify: `Sources/OrchestraCore/Agents/Adapter.swift` (protocol + extension)
- Modify: `Sources/OrchestraCore/Agents/SessionBrief.swift` (remove `claudeSessionStartJSON`)
- Modify: `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift` (add explicit `encode`)
- Modify: `Sources/OrchestraCore/Agents/CodexAdapter.swift` (add explicit `encode`)
- Test: `Tests/OrchestraCoreTests/AdapterEncodeTests.swift`; update `SessionBriefTests.swift` (`envelope`/`envelopeEscaping` move to `HookChannelTests` or stay pointing at `HookEnvelope`)

**Interfaces:**
- Produces: `Adapter.encode(_ r: HookResponse, for e: HookEvent) -> String?` (default `nil`); `Adapter.sessionSource(_ payload: JSONValue) -> SessionSource?` (default `.other`).
- Consumes: `HookResponse`, `HookEvent`, `HookEnvelope` (Task 1).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OrchestraCoreTests/AdapterEncodeTests.swift
import Testing
import Foundation
@testable import OrchestraCore

@Suite struct AdapterEncodeTests {
    @Test("Claude encode wraps additionalContext + continuation") func claudeEncode() {
        let a = ClaudeCodeAdapter()
        #expect(a.encode(HookResponse(additionalContext: "hi"), for: .sessionStart)?
                    .contains("\"additionalContext\":\"hi\"") == true)
        #expect(a.encode(HookResponse(continuation: "go"), for: .stop)?
                    .contains("\"decision\":\"block\"") == true)
        #expect(a.encode(HookResponse(), for: .stop) == nil)
    }
    @Test("Codex encode matches (shared envelope)") func codexEncode() {
        #expect(CodexAdapter().encode(HookResponse(additionalContext: "hi"), for: .sessionStart)?
                    .contains("\"additionalContext\":\"hi\"") == true)
    }
    @Test("sessionSource reads payload[source], defaults .other") func source() {
        let a = ClaudeCodeAdapter()
        #expect(a.sessionSource(.object(["source": .string("compact")])) == .compact)
        #expect(a.sessionSource(.object([:])) == .other)
    }
    @Test("StubAdapter inherits fail-safe defaults (nil encode, .other source)") func stubDefaults() {
        let s = StubAdapter(transcriptDir: NSTemporaryDirectory())
        #expect(s.encode(HookResponse(additionalContext: "x"), for: .sessionStart) == nil)  // no silent Claude shape
        #expect(s.sessionSource(.object([:])) == .other)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter AdapterEncodeTests` → FAIL (no `encode`/`sessionSource`).

- [ ] **Step 3: Implement — protocol + defaults** (`Adapter.swift`)

Add to the protocol (after `parse`, `Adapter.swift:46`):
```swift
    /// Encode core's agent-neutral `HookResponse` into THIS agent's hook stdout. Default `nil` (fail-
    /// safe, like `parse`) — no implicit inheritance of another agent's envelope. Claude/Codex implement
    /// it via `HookEnvelope`.
    func encode(_ response: HookResponse, for event: HookEvent) -> String?
    /// Normalize the raw SessionStart payload's source at the edge, so core never reads raw fields.
    func sessionSource(_ payload: JSONValue) -> SessionSource?
```
Add to the `public extension Adapter` (`Adapter.swift:60`):
```swift
    func encode(_ response: HookResponse, for event: HookEvent) -> String? { nil }
    func sessionSource(_ payload: JSONValue) -> SessionSource? {
        payload["source"]?.stringValue.flatMap(SessionSource.init(rawValue:)) ?? .other
    }
```

- [ ] **Step 4: Implement — move the envelope + add explicit `encode`s**

Delete `SessionBrief.claudeSessionStartJSON(_:)` (`SessionBrief.swift:35-44`) — its body now lives in `HookEnvelope.additionalContext` (Task 1). `SessionBrief` keeps only `sentence`.

Add to `ClaudeCodeAdapter` (a natural spot: right after `parse`):
```swift
    public func encode(_ r: HookResponse, for event: HookEvent) -> String? {
        if let c = r.additionalContext { return HookEnvelope.additionalContext(c) }
        if let cont = r.continuation   { return HookEnvelope.block(cont) }
        return nil
    }
```
Add the **identical** method to `CodexAdapter` (Codex 0.135+ shares the envelope). `sessionSource` is inherited by both.

- [ ] **Step 5: Update `SessionBriefTests`** — its `envelope`/`envelopeEscaping` tests referenced `claudeSessionStartJSON`; point them at `HookEnvelope.additionalContext` (or delete them — Task 1's `HookChannelTests.envelope` + `AdapterEncodeTests` cover it). Keep `perColumn`/`readOnlyClause`/`liveColumn`/`unknownNil`/`noPositionalFold` untouched.

- [ ] **Step 6: Run** — `swift test --filter AdapterEncodeTests` and `--filter SessionBriefTests` → PASS.

- [ ] **Step 7: Commit** — `git commit -m "feat(hooks): adapter encode/sessionSource seam; move envelope to HookEnvelope"`

---

### Task 3: `AdapterContext.orchestraBin` + render fold + template/parse splits (the atomic block)

> One compile-coupled change: removing `hooksPath` breaks every ctx constructor. Do it all, then build.

**Files:**
- Modify: `Adapter.swift` (`AdapterContext`), `ClaudeCodeAdapter.swift`, `CodexAdapter.swift`, `HooksRenderer.swift`, `Resources/claude-hooks.json`, `Resources/codex-hooks.json`, `OrchestraService.swift`, `OrchestraService+Recovery.swift`
- Test: update `DaemonLifecycleTests.swift` (`hooksRender`), `CodexHooksTests` (in `SessionBriefTests.swift`)

**Interfaces:**
- Produces: `AdapterContext.orchestraBin: String`; `HooksRenderer.render(orchestraBin:agentId:to:)`, `renderCodex(orchestraBin:agentId:to:)`.
- Consumes: nothing new.

- [ ] **Step 1: Swap the field** (`Adapter.swift:12,19,22`)

Replace `public let hooksPath: String` → `public let orchestraBin: String`. In `init`, replace the `hooksPath: String = Config.hooksPath` param with `orchestraBin: String = siblingBinary("orchestra")`, and the assignment `self.hooksPath = hooksPath` → `self.orchestraBin = orchestraBin`.

- [ ] **Step 2: Fix the 3 launch ctx sites** — add `orchestraBin: orchestraBin`, drop `hooksPath:`

`OrchestraService.swift:270-273` (spawn), `OrchestraService+Recovery.swift:64` (resume), `:136` (restart). (The service gains `orchestraBin` in Task 4; until then these can pass `orchestraBin: siblingBinary("orchestra")` — but Task 4 lands the stored property, so prefer ordering Task 4's init change first if compiling between steps. For a single commit, do both.)

- [ ] **Step 3: Fix the 3 query ctx sites** — drop `hooksPath:` (they take the `siblingBinary` default)

`OrchestraService.swift:515` (sessions), `OrchestraService+Recovery.swift:223` (isResumable), `ClaudeCodeAdapter.swift:210-211` (`sessionInfo` sub-ctx — just remove `hooksPath: ctx.hooksPath`).

- [ ] **Step 4: Claude reads → `Config.hooksPath`; render in `prepareToLaunch`; parse splits**

- `ClaudeCodeAdapter.swift:116` `ctx.hooksPath` → `Config.hooksPath`; `:159` `settingsFlags` `ctx.hooksPath` → `Config.hooksPath`.
- `prepareToLaunch` first line (before the overlay merge): `try? HooksRenderer.render(orchestraBin: ctx.orchestraBin, agentId: id)`.
- `parse` (`:50` switch): rename `case "tool":` → `case "pretool", "posttool":` and `case "notify":` → `case "notification", "stop":` (bodies unchanged).

- [ ] **Step 5: Codex renders in `prepareToLaunch`**

In `CodexAdapter.prepareToLaunch`, immediately before the existing `CodexHooks.install(...)` line: `try? HooksRenderer.renderCodex(orchestraBin: ctx.orchestraBin, agentId: id)`.

- [ ] **Step 6: `HooksRenderer` gains `agentId`**

Add `agentId: String` param to `render` and `renderCodex`; after the `__ORCHESTRA_BIN__` replace, add `.replacingOccurrences(of: "__AGENT_ID__", with: agentId)`. Update both fallback templates + both bundled JSON resources to: add `--agent __AGENT_ID__` to every command; Claude `Stop`→`--event stop`, `Notification`→`--event notification`, `PreToolUse`→`--event pretool`, `PostToolUse`→`--event posttool`; Codex SessionStart→`--event session`.

Example rendered Claude command: `__ORCHESTRA_BIN__ _report --event stop --agent __AGENT_ID__`.

- [ ] **Step 7: Update the renderer tests**

`DaemonLifecycleTests.hooksRender`: call `HooksRenderer.render(orchestraBin: "/opt/orchestra", agentId: "claude-code")`; assert `--agent claude-code` present, `__AGENT_ID__`/`__ORCHESTRA_BIN__` absent, distinct `--event stop`/`--event notification`/`--event pretool`/`--event posttool` present, valid JSON. `CodexHooksTests`: `renderCodex(orchestraBin:agentId:"codex")` emits `--event session --agent codex` with `startup|resume` matcher; `CodexHooks.install` no-clobber unchanged.

- [ ] **Step 8: Build + run** — `swift build` (fixes any missed ctx site the compiler flags), then `swift test --filter DaemonLifecycleTests` and `--filter SessionBriefTests` (holds `CodexHooksTests`) → PASS.

- [ ] **Step 9: Commit** — `git commit -m "refactor(hooks): AdapterContext.orchestraBin; render in prepareToLaunch; event-vocabulary splits"`

---

### Task 4: `OrchestraService.handleHook` + `orchestraBin`

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (`init` + new method)
- Test: `Tests/OrchestraCoreTests/HandleHookTests.swift`

**Interfaces:**
- Consumes: `HookEvent`, `HookResponse`, `SessionSource`; existing `report(_:_:)`, `sessionBrief(_:)`, `drainForStop(_:)`, `resolveRef(_:)`.
- Produces: `handleHook(_ ref: String, event: HookEvent, report: StatusReport?, source: SessionSource?) async -> HookResponse?`; `OrchestraService.orchestraBin: String`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OrchestraCoreTests/HandleHookTests.swift
import Testing
import Foundation
@testable import OrchestraCore

@Suite struct HandleHookTests {
    // reuse the standard in-memory service fixture pattern from ControlRoundTripTests / ReportTests
    @Test("sessionStart returns live orientation; compact skips") func sessionStart() async throws {
        let (svc, card) = try await makeServiceWithCard()   // helper mirrors existing test setup
        let r = await svc.handleHook(card.shortId, event: .sessionStart, report: nil, source: .startup)
        #expect(r?.additionalContext?.contains(card.shortId) == true)
        let c = await svc.handleHook(card.shortId, event: .sessionStart, report: nil, source: .compact)
        #expect(c == nil)
    }
    @Test("stop drains inbox into continuation") func stop() async throws {
        let (svc, card) = try await makeServiceWithCard()
        try await svc.inboxAppend(card.id, text: "queued")   // existing inbox API
        let r = await svc.handleHook(card.shortId, event: .stop, report: nil, source: nil)
        #expect(r?.continuation?.contains("queued") == true)
    }
    @Test("telemetry event applies report, returns nil") func telemetry() async throws {
        let (svc, card) = try await makeServiceWithCard()
        let rep = StatusReport(status: .running)
        let r = await svc.handleHook(card.shortId, event: .postToolUse, report: rep, source: nil)
        #expect(r == nil)
        #expect(await svc.snapshot(card.id)?.status == .running)  // report landed (use existing accessor)
    }
    @Test("unknown ref → nil, no throw") func unknownRef() async {
        let (svc, _) = try! await makeServiceWithCard()
        #expect(await svc.handleHook("nope", event: .stop, report: nil, source: nil) == nil)
    }
}
```
> Note: `makeServiceWithCard`, `inboxAppend`, `snapshot` stand in for the exact fixture/accessors used by the existing `ControlRoundTripTests`/`ReportTests` — copy their concrete setup when implementing (see those files).

- [ ] **Step 2: Run to verify it fails** — `swift test --filter HandleHookTests` → FAIL.

- [ ] **Step 3: Implement — `init` + `handleHook`**

`OrchestraService.init` (`:49`): add param `orchestraBin: String = siblingBinary("orchestra")`; store `self.orchestraBin = orchestraBin` (add `public let orchestraBin: String` near the other stored props, `:7-10`).

Add near `sessionBrief`/`drainForStop` (`:369-391`):
```swift
    /// The core-owned hook channel dispatch — adapter-free. The `_report` edge sends a typed event; this
    /// applies telemetry to the store and composes the receive-direction content into a neutral
    /// `HookResponse`. Both directions in one place; no `if agentId`.
    public func handleHook(_ ref: String, event: HookEvent,
                           report: StatusReport?, source: SessionSource?) async -> HookResponse? {
        guard let task = try? await resolveRef(ref) else { return nil }
        if let report { try? await self.report(task.id, report) }
        switch event {
        case .sessionStart where source != .compact:
            return await sessionBrief(task.id).map { HookResponse(additionalContext: $0) }
        case .stop:
            return await drainForStop(task.id).map { HookResponse(continuation: $0) }
        default:
            return nil
        }
    }
```

- [ ] **Step 4: Run** — `swift test --filter HandleHookTests` → PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(hooks): OrchestraService.handleHook + orchestraBin"`

---

### Task 5: `ControlServer` — unify the `hook` RPC

**Files:**
- Modify: `Sources/OrchestraCore/Control/ControlServer.swift` (add `hook`, remove `report`/`drain`/`sessionBrief`)
- Test: update `Tests/OrchestraCoreTests/ControlRoundTripTests.swift`

**Interfaces:**
- Consumes: `service.handleHook`; `HookEvent`, `HookResponse`, `SessionSource`, `StatusReport`.

- [ ] **Step 1: Update the round-trip test first**

In `ControlRoundTripTests`, replace the `sessionBrief`/`drain` RPC drives with `hook`:
```swift
    @Test("hook RPC: sessionStart returns orientation") func hookSessionStart() async throws {
        // spawn a card over the socket (existing helper), then:
        let resp = try await client.call("hook", .object([
            "ref": .string(shortId), "event": .string("session"), "source": .string("startup")]))
        #expect(resp?["response"]?["additionalContext"]?.stringValue?.contains(shortId) == true)
    }
    @Test("hook RPC: stop drains; retired methods gone") func hookStopAndRemoval() async throws {
        // append inbox, then hook stop → continuation present
        let stop = try await client.call("hook", .object(["ref": .string(shortId), "event": .string("stop")]))
        #expect(stop?["response"]?["continuation"]?.stringValue != nil)
        // the three retired RPCs must now be method-not-found
        await #expect(throws: (any Error).self) { _ = try await client.call("sessionBrief", .object(["ref": .string(shortId)])) }
    }
```
Keep the existing subscribe/backfill/diff/meta tests. Delete the old direct `sessionBrief`/`drain` assertions.

- [ ] **Step 2: Run to verify it fails** — `swift test --filter ControlRoundTripTests` → FAIL (no `hook` method).

- [ ] **Step 3: Implement** — in `dispatch(...)` add, and delete the `report`/`drain`/`sessionBrief` cases (`ControlServer.swift:145-189`):

```swift
        case "hook":
            guard let p = req.params, let ref = p.optString("ref"),
                  let kind = p.optString("event"), let event = HookEvent(rawValue: kind) else {
                throw OrchestraError.invalidParams("hook needs ref + event")
            }
            let report = p["report"].flatMap { try? $0.decode(StatusReport.self) }
            let source = p.optString("source").flatMap(SessionSource.init(rawValue:))
            let resp = await service.handleHook(ref, event: event, report: report, source: source)
            return .object(["response": (try? resp.map { try JSONValue(encodable: $0) }) ?? .null ?? .null])
```
> The double `?? .null` flattens `Optional<Optional<JSONValue>>` from `resp.map`; simplify with an explicit `if let resp { return .object(["response": try JSONValue(encodable: resp)]) } ; return .object(["response": .null])` if preferred.

- [ ] **Step 4: Run** — `swift test --filter ControlRoundTripTests` → PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(hooks): unify report/drain/sessionBrief into one hook RPC"`

---

### Task 6: `ReportHelper` — thin edge client

**Files:**
- Modify: `Sources/orchestra/ReportHelper.swift` (rewrite `run`; generalize `boundedSend`; delete `emitSessionBrief`)
- Verify: `scripts/orch-test.sh` isolated-daemon smoke

**Interfaces:**
- Consumes: `AgentRegistry`, `HookEvent`, `HookResponse`, `SessionSource`; the `hook` RPC.

- [ ] **Step 1: Generalize `boundedSend`** — signature `boundedSend(sock:method:params:budgetMs:)`; body `client.call(method, params)` (was hardcoded `"report"`, `:169`).

- [ ] **Step 2: Rewrite `run`** (`:12-70`) to the uniform flow:

```swift
    static func run(_ args: [String]) async {
        let env = ProcessInfo.processInfo.environment
        let flags = Flags(args)
        let kind = flags.value("event") ?? "statusline"
        let raw = readAllStdin()
        let payload = (try? JSONValue.parse(raw)) ?? .object([:])

        if kind == "statusline" {                                   // local display FIRST — never waits
            writeStdout(Data(renderStatusLine(payload: payload, raw: raw).utf8))
        }
        guard let taskId = env["ORCHESTRA_TASK_ID"], !taskId.isEmpty,
              let event = HookEvent(rawValue: kind),
              let agentId = flags.value("agent"),
              let adapter = try? AgentRegistry().get(agentId) else { return }
        let sock = env["ORCHESTRA_SOCK"] ?? Config.socketPath

        let report = adapter.parse(.hooksPush(kind: kind, payload: payload))   // raw dies here (edge)
        let source = event == .sessionStart ? adapter.sessionSource(payload) : nil
        var fields: [String: JSONValue] = ["ref": .string(taskId), "event": .string(kind)]
        if let report { fields["report"] = (try? JSONValue(encodable: report)) ?? .null }
        if let source { fields["source"] = .string(source.rawValue) }
        let params = JSONValue.object(fields)

        if event == .statusLine {                                   // pure send, no response
            await boundedSend(sock: sock, method: "hook", params: params, budgetMs: 50)
            return
        }
        guard let resp = await boundedCall(sock: sock, method: "hook", params: params, budgetMs: 2000),
              let response = resp["response"].flatMap({ try? $0.decode(HookResponse.self) }),
              let out = adapter.encode(response, for: event) else { return }
        writeStdout(Data(out.utf8))
    }
```
Delete `emitSessionBrief` (`:76-83`).

- [ ] **Step 3: Build** — `swift build` → success.

- [ ] **Step 4: Smoke via isolated daemon** — `scripts/orch-test.sh` (disposable HOME + tmux socket): spawn a card; `orchestra _report --event session --agent claude-code` with a stub SessionStart payload → stdout is the `additionalContext` envelope with the column/id; queue an inbox message + `_report --event stop --agent claude-code` → `decision:block` stdout, card back to `waiting`; `_report --event statusline` prints a line with no daemon and doesn't hang. (Extend the script per its existing patterns; see the Orchestra isolated-testing memory.)

- [ ] **Step 5: Commit** — `git commit -m "refactor(hooks): _report becomes a thin edge client over the hook RPC"`

---

### Task 7: Daemon stops rendering

**Files:**
- Modify: `Sources/orchestrad/main.swift`

- [ ] **Step 1: Delete** `let orchestraBin = siblingBinary("orchestra")` (`:10`) and both startup `HooksRenderer` blocks (`:14-19`).
- [ ] **Step 2:** `onConfigChanged` (`:22-26`) keeps only `try? ConfigStore.save(cfg)`.
- [ ] **Step 3: Build + full suite in isolation** — `swift build`; `swift test` (run the flaky resume/recovery suites with `--filter` if the full run trips them). Expect green.
- [ ] **Step 4: Commit** — `git commit -m "refactor(hooks): daemon no longer renders hook files (adapters own it)"`

---

### Task 8: Docs sync (Definition of Done)

**Files:**
- Modify: `docs/02-architecture.md`, `docs/04-cards-worktrees-sessions.md`, `docs/06-clients-cli-mcp.md`, `docs/09-design-decisions.md` (+ `docs/index.md` if TOC touched)

- [ ] **Step 1:** Update the four chapters: `docs/02` (daemon renders nothing; the channel), `docs/06` (the `hook` RPC + `--agent` + `_report` edge client), `docs/04` (`AdapterContext.orchestraBin`; the Codex-hooks seam), `docs/09` (channel design principle: core owns protocol, adapter owns format; fail-safe `encode`). Backfill the previously-undocumented `CodexHooks`/`SessionBrief`/channel seam. Rule: if prose and code disagree, code wins.
- [ ] **Step 2:** `swift build && swift test` once more (green), then **Commit** — `git commit -m "docs: document the first-class hook channel [manual]"`. (The `[docs-sync]` auto-hook only fires on `main`; this is a manual on-branch update.)

---

## Self-Review notes

- **Spec coverage:** Tasks 1–8 map 1:1 to `03-implementation.md` steps 1–9 (step 3's atomic block = Task 3; step 8 tests are folded into each task's TDD; step 9 docs = Task 8).
- **Type consistency:** `HookEvent`/`HookResponse`/`SessionSource`/`HookEnvelope` names + signatures are identical across Tasks 1→8. `handleHook`, `encode`, `sessionSource` signatures match `02-contract.md`.
- **Ordering:** Task 3 is compile-coupled — expect `swift build` to surface any missed ctx site; the 6 sites are enumerated in `02-contract.md`. Land Task 4's `orchestraBin` init in the same commit as Task 3 if compiling between them matters (the plan notes this).
- **Verify-at-impl:** query-ctx `orchestraBin` uses the `siblingBinary` default; confirm Codex's SessionStart payload `source` handling (benign → `.other`). See `03-implementation.md` open items.
