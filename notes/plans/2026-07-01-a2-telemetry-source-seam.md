# A2 — Telemetry-Source Seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Relocate the raw→`StatusReport` telemetry parse out of the `orchestra` CLI target and into the **adapter** (per-agent, `adapter.parse`), establishing the transport/parse boundary the design (D6) calls for — while keeping Claude telemetry **byte-identical**.

**Architecture:** Orchestra's telemetry has two halves. The **transport** (Orchestra-owned) obtains *raw* bytes — for Claude that is the `hooksPush` transport: the agent's hooks run `orchestra _report`, which reads the hook JSON and pushes it. The **parse** (agent-dependent) converts raw → normalized two-tier `StatusReport`. Today the parse lives in the CLI (`ReportHelper.map`). A2 moves it behind a new defaulted `Adapter.parse(_: RawTelemetry) -> StatusReport?` protocol method; `ClaudeCodeAdapter.parse` carries the relocated logic verbatim, and the `_report` push transport calls `adapter.parse` instead of a local function. The daemon's `report` merge path (seq-gate) is **not touched**.

**Tech Stack:** Swift 6, SwiftPM (`OrchestraCore` library + `orchestra` CLI target), swift-testing (`@Suite`/`@Test`/`#expect`/`#require`), run via `scripts/test.sh`.

## Global Constraints

- **Behavior-preservation is the bar.** Claude telemetry stays byte-identical: `ReportTests`, `AdapterTests`, `RecoveryTests` stay **green unchanged** (do not edit them). `ReportTests` calls `svc.report(_:StatusReport)` directly — the merge path in `OrchestraService+Report.swift` and `ControlServer` `case "report"` must remain **unchanged**.
- **`parse` is added DEFAULTED (additive, not a mutation).** The new protocol requirement ships with a `nil`-returning default in `extension Adapter`, so no conformer breaks. Only `ClaudeCodeAdapter` (real) and `StubAdapter` (test) get explicit implementations.
- **Do NOT over-build.** No Codex adapter, no rollout tailer, no PTY scrape, no daemon-side re-wire of the `report` command. `EventReport` carries **NO** turn/approval fields (deferred to a later PR, out of this forest). The `RawTelemetry` envelope includes only `.hooksPush` (Claude, this PR) + `.fileTail` (needed by the ownership test and by B2 next) — **not** `.ptyScrape` (no v1 consumer).
- **Tests never spawn a real vendor agent.** `USE_REAL_CLAUDE` stays unset; `StubSessions`/`StubAdapter` only.
- **Build/test needs an UNSANDBOXED shell** (`sandbox-exec sandbox_apply` error → re-run with sandbox disabled). `typecheck-app.sh` may need `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.
- Scratch/experiments go in `./.scratch/` only.

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Sources/OrchestraCore/Agents/Telemetry.swift` | **NEW** — the `RawTelemetry` envelope: the raw unit each transport hands to `adapter.parse`. | Create |
| `Sources/OrchestraCore/Agents/Adapter.swift` | Add `parse(_:) -> StatusReport?` to the `Adapter` protocol + a `nil` default in the extension. | Modify |
| `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift` | Implement `parse` for `.hooksPush` — the relocated `map`+`toolDesc` logic (byte-identical). | Modify |
| `Sources/orchestra/ReportHelper.swift` | Delete `map`+`toolDesc`; the push transport calls `ClaudeCodeAdapter().parse(.hooksPush(...))`. `renderStatusLine`/`globalStatusLineCommand`/`statusLineTimeout`/`boundedSend` stay (they are agent-side statusline *display*, not parse). | Modify |
| `Tests/OrchestraCoreTests/Stubs.swift` | Add a `parse` to `StubAdapter` (parses `.fileTail` into a marker report) so the ownership test can show a non-Claude parse. | Modify |
| `Tests/OrchestraCoreTests/ParseTests.swift` | **NEW** — `test_adapter_owns_parse`, `test_claude_report_unchanged`, `test_parse_report_reaches_board`. | Create |

**Why the parse belongs in the adapter, called by the push transport (not the daemon).** For `hooksPush`, the transport is inherently the ephemeral `orchestra _report` process the hook spawns (design §6: "Claude: hooks → orchestra _report — agent PUSHES"). That process obtains the raw bytes and is the natural place to call the adapter's parse; the daemon receives an already-normalized `StatusReport` on the untouched `report` endpoint. B2's `fileTail` transport is daemon-side and will call the *same* `adapter.parse` seam from the tailer — different transport location, one parse contract. This keeps A2 minimal and byte-identical while establishing the exact boundary B2 plugs into.

---

### Task 1: The parse seam — `RawTelemetry` + defaulted `Adapter.parse`, proven per-adapter

**Files:**
- Create: `Sources/OrchestraCore/Agents/Telemetry.swift`
- Modify: `Sources/OrchestraCore/Agents/Adapter.swift`
- Modify: `Tests/OrchestraCoreTests/Stubs.swift`
- Test: `Tests/OrchestraCoreTests/ParseTests.swift` (create)

**Interfaces:**
- Produces:
  - `enum RawTelemetry: Sendable { case hooksPush(kind: String, payload: JSONValue); case fileTail(line: String) }`
  - `Adapter.parse(_ raw: RawTelemetry) -> StatusReport?` (protocol requirement) + `extension Adapter { func parse(_:) -> StatusReport? { nil } }` default.
  - `StubAdapter.parse` — returns `StatusReport(desc: "tail:<line>", status: .running)` for `.fileTail`, `nil` otherwise.
- Consumes: `StatusReport`, `JSONValue`, `AgentCapabilities` (all existing in `OrchestraCore`).

- [ ] **Step 1: Write the failing test** — `Tests/OrchestraCoreTests/ParseTests.swift`

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Adapter telemetry parse — per-adapter ownership + Claude byte-identity + board round-trip")
struct ParseTests {

    // I12 — parse is the ADAPTER's, not a core function: the same raw goes to different adapters
    // and yields different results; a Claude adapter cannot produce a fileTail (Codex-shaped) report.
    @Test("adapter owns parse: same raw, different adapters → different reports")
    func test_adapter_owns_parse() throws {
        // Claude has no fileTail transport → nil for a tailed line.
        #expect(ClaudeCodeAdapter().parse(.fileTail(line: #"{"usage":123}"#)) == nil)

        // A tail-shaped stub parses the SAME raw into a report the Claude adapter can't produce.
        let tailCaps = AgentCapabilities(
            sessionId: .discovered, telemetry: .fileTail, contextUsage: .tokens,
            wakeTransport: .sendKeys, inboxDrain: .stopHook,
            readOnlyEnforcement: .sandboxed, authMode: .subscription)
        let stub = StubAdapter(transcriptDir: NSTemporaryDirectory(), capabilities: tailCaps)
        #expect(stub.parse(.fileTail(line: "hello")) == StatusReport(desc: "tail:hello", status: .running))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter ParseTests` (unsandboxed)
Expected: FAIL — compile error, `RawTelemetry` and `parse` do not exist.

- [ ] **Step 3: Create `Sources/OrchestraCore/Agents/Telemetry.swift`**

```swift
import Foundation

/// The raw, un-parsed unit of telemetry an Orchestra **transport** hands to `Adapter.parse`. Each case
/// is one transport shape, keyed by `AgentCapabilities.Telemetry`:
///   - `hooksPush`  — an agent-pushed hook event (`orchestra _report`): the event `kind` + its JSON
///                    `payload`. The transport is the ephemeral push process; parse is the adapter's.
///   - `fileTail`   — one line the daemon tailed from a rollout/transcript file (Codex, next PR B2).
/// The **transport** owns only obtaining these bytes (push endpoint / tailer); the **adapter** owns the
/// agent-dependent conversion to a normalized `StatusReport` (D3). `ptyScrape` has no v1 consumer and
/// is intentionally omitted until a scrape adapter needs it.
public enum RawTelemetry: Sendable {
    case hooksPush(kind: String, payload: JSONValue)
    case fileTail(line: String)
}
```

- [ ] **Step 4: Add the protocol requirement + default to `Adapter.swift`**

In `public protocol Adapter`, add after `func resume(_ ctx: AdapterContext) -> [String]?` (line 40):

```swift
    /// Convert one unit of raw transport telemetry into a normalized `StatusReport` (the D3 parse core).
    /// AGENT-DEPENDENT: each adapter owns its own mapping. The Orchestra transport (push endpoint /
    /// tailer / scrape, keyed by `capabilities.telemetry`) supplies only the raw bytes and merges the
    /// result via `OrchestraService.report`. DEFAULTED to `nil` (additive — no conformer breaks) so an
    /// adapter opts in per transport it actually receives.
    func parse(_ raw: RawTelemetry) -> StatusReport?
```

In `public extension Adapter` (after `prepareToLaunch` default, line 51), add:

```swift
    func parse(_ raw: RawTelemetry) -> StatusReport? { nil }
```

- [ ] **Step 5: Add `parse` to `StubAdapter` in `Stubs.swift`**

In `final class StubAdapter`, after `resume(_:)` (line 92), add:

```swift
    /// A recognizable, NON-Claude parse: turns a tailed line into a marker report, proving parse is
    /// per-adapter (a Claude adapter returns nil for the same `.fileTail` raw).
    func parse(_ raw: RawTelemetry) -> StatusReport? {
        if case let .fileTail(line) = raw { return StatusReport(desc: "tail:\(line)", status: .running) }
        return nil
    }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `./scripts/test.sh --filter ParseTests` (unsandboxed)
Expected: PASS (`test_adapter_owns_parse`). `ClaudeCodeAdapter().parse(.fileTail(...))` hits the defaulted `nil` (Claude implements no explicit parse yet — added in Task 2).

- [ ] **Step 7: Commit**

```bash
git add Sources/OrchestraCore/Agents/Telemetry.swift Sources/OrchestraCore/Agents/Adapter.swift \
        Tests/OrchestraCoreTests/Stubs.swift Tests/OrchestraCoreTests/ParseTests.swift
git commit -m "feat(seam): add RawTelemetry envelope + defaulted Adapter.parse (A2 telemetry seam)"
```

---

### Task 2: Relocate the Claude parse into `ClaudeCodeAdapter` — byte-identical

**Files:**
- Modify: `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift`
- Test: `Tests/OrchestraCoreTests/ParseTests.swift`

**Interfaces:**
- Produces: `ClaudeCodeAdapter.parse(_ raw: RawTelemetry) -> StatusReport?` handling `.hooksPush` with the exact logic of the former `ReportHelper.map` (kinds: `statusline`, `session`, `prompt`, `tool`, `notify`, `sessionend`) + a private `toolDesc`.
- Consumes: `RawTelemetry`, `StatusReport`, `JSONValue` (all in `OrchestraCore`).

- [ ] **Step 1: Write the failing test** — append to `ParseTests` in `Tests/OrchestraCoreTests/ParseTests.swift`

```swift
    // I12 / test_claude_report_unchanged — Claude push parse produces the SAME StatusReport the former
    // `ReportHelper.map` did. Deterministic kinds are compared whole; statusline's `seq` is a wall-clock
    // stamp (DispatchTime.now), so its fields are checked individually.
    @Test("Claude push parse: hook payload → StatusReport byte-identical to the former ReportHelper.map")
    func test_claude_report_unchanged() throws {
        let a = ClaudeCodeAdapter()

        let tool = try JSONValue.parse(Data(#"{"tool_name":"Edit","tool_input":{"file_path":"/x/Foo.swift"}}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "tool", payload: tool))
                == StatusReport(desc: "Editing Foo.swift", status: .running))

        let bash = try JSONValue.parse(Data(#"{"tool_name":"Bash","tool_input":{"command":"ls -la"}}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "tool", payload: bash))
                == StatusReport(desc: "Running: ls -la", status: .running))

        let notify = try JSONValue.parse(Data(#"{"message":"done"}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "notify", payload: notify))
                == StatusReport(desc: "done", status: .waiting))

        let prompt = try JSONValue.parse(Data(#"{"prompt":"hi there"}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "prompt", payload: prompt))
                == StatusReport(status: .running, promptText: "hi there"))

        let session = try JSONValue.parse(Data(#"{"session_id":"sid","source":"resume"}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "session", payload: session))
                == StatusReport(sessionId: "sid", sessionSource: "resume"))

        // sessionend: transition reasons (clear/resume/compact) drop to nil; genuine exit carries.
        let clear = try JSONValue.parse(Data(#"{"reason":"clear"}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "sessionend", payload: clear)) == nil)
        let exit = try JSONValue.parse(Data(#"{"reason":"exit"}"#.utf8))
        #expect(a.parse(.hooksPush(kind: "sessionend", payload: exit))
                == StatusReport(endReason: "exit"))

        // statusline: seq is a live timestamp → assert the parsed fields, not the whole struct.
        let sl = try JSONValue.parse(Data(#"""
        {"session_id":"sid","context_window":{"used_percentage":42.0},
         "model":{"id":"m","display_name":"M"},"session_name":"Card"}
        """#.utf8))
        let r = try #require(a.parse(.hooksPush(kind: "statusline", payload: sl)))
        #expect(r.snapshot?.ctxPct == 42)
        #expect(r.snapshot?.modelId == "m")
        #expect(r.snapshot?.modelDisplay == "M")
        #expect(r.snapshot?.sessionName == "Card")
        #expect((r.snapshot?.seq ?? 0) > 0)
        #expect(r.event?.sessionId == "sid")

        // Unknown kind → nil (unchanged default branch).
        #expect(a.parse(.hooksPush(kind: "bogus", payload: .object([:]))) == nil)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter ParseTests` (unsandboxed)
Expected: FAIL — `ClaudeCodeAdapter().parse(.hooksPush(...))` currently returns `nil` (default), so the `#expect(... == StatusReport(...))` assertions fail.

- [ ] **Step 3: Implement `ClaudeCodeAdapter.parse`**

In `ClaudeCodeAdapter.swift`, add this **MARK section** immediately after `newSessionId()` (line 36), keeping the logic identical to the former `ReportHelper.map`/`toolDesc`:

```swift
    // MARK: telemetry parse (hooksPush) — relocated from the `orchestra` CLI `ReportHelper.map`.

    /// Claude telemetry is `hooksPush`: the `_report` transport pushes each hook event (kind + JSON
    /// payload); this converts it to a normalized two-tier `StatusReport`. Byte-identical to the former
    /// CLI `ReportHelper.map` so `ReportTests` and live Claude reporting are unchanged. Claude has no
    /// `fileTail` transport, so any non-`hooksPush` raw returns nil.
    public func parse(_ raw: RawTelemetry) -> StatusReport? {
        guard case let .hooksPush(kind, p) = raw else { return nil }
        switch kind {
        case "statusline":
            let seq = DispatchTime.now().uptimeNanoseconds
            return StatusReport(
                seq: seq,
                sessionId: p["session_id"]?.stringValue,
                transcriptPath: p["transcript_path"]?.stringValue,
                ctxPct: p["context_window"]?["used_percentage"]?.doubleValue,
                modelId: p["model"]?["id"]?.stringValue,            // launch id (for resume/restart)
                modelDisplay: p["model"]?["display_name"]?.stringValue,  // UI label only
                sessionName: p["session_name"]?.stringValue)
        case "session":
            return StatusReport(
                sessionId: p["session_id"]?.stringValue,
                transcriptPath: p["transcript_path"]?.stringValue,
                sessionSource: p["source"]?.stringValue)
        case "prompt":
            return StatusReport(status: .running, promptText: p["prompt"]?.stringValue)
        case "tool":
            let tool = p["tool_name"]?.stringValue ?? "tool"
            return StatusReport(desc: toolDesc(tool: tool, input: p["tool_input"]), status: .running)
        case "notify":
            return StatusReport(desc: p["message"]?.stringValue, status: .waiting)
        case "sessionend":
            let reason = p["reason"]?.stringValue ?? "other"
            // Transition reasons are ignored (the matching SessionStart handles them).
            if ["clear", "resume", "compact"].contains(reason) { return nil }
            return StatusReport(endReason: reason)
        default:
            return nil
        }
    }

    private func toolDesc(tool: String, input: JSONValue?) -> String {
        switch tool {
        case "Edit", "Write", "MultiEdit":
            if let f = input?["file_path"]?.stringValue { return "Editing \((f as NSString).lastPathComponent)" }
            return "Editing"
        case "Bash":
            if let c = input?["command"]?.stringValue { return "Running: \(String(c.prefix(40)))" }
            return "Running a command"
        case "Read":
            if let f = input?["file_path"]?.stringValue { return "Reading \((f as NSString).lastPathComponent)" }
            return "Reading"
        case "WebSearch": return "Web search"
        case "Grep", "Glob": return "Searching"
        default: return tool
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter ParseTests` (unsandboxed)
Expected: PASS — both `test_adapter_owns_parse` and `test_claude_report_unchanged`.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift Tests/OrchestraCoreTests/ParseTests.swift
git commit -m "feat(seam): ClaudeCodeAdapter.parse owns hooksPush telemetry (byte-identical map relocation)"
```

---

### Task 3: Rewire the `_report` push transport to call `adapter.parse`; delete the CLI copy

**Files:**
- Modify: `Sources/orchestra/ReportHelper.swift`
- Test: `Tests/OrchestraCoreTests/ParseTests.swift` (round-trip)

**Interfaces:**
- Consumes: `ClaudeCodeAdapter().parse(.hooksPush(kind:payload:))` (from Task 2).
- Produces: the `_report` push transport now delegates parse to the adapter; `ReportHelper.map`/`toolDesc` are **deleted**. The daemon `report` endpoint + `OrchestraService.report` merge are untouched.

- [ ] **Step 1: Write the failing test** — append the round-trip to `ParseTests`

```swift
    // I14 / spawn→telemetry→board — a parse-produced StatusReport reaches service.report and updates
    // the board (proves the transport→parse→merge path end to end, using the real Claude parse).
    @Test("spawn → ClaudeCodeAdapter.parse(raw) → service.report → board card updates")
    func test_parse_report_reaches_board() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "Task", repo: repo, branch: "b"))

        let raw = RawTelemetry.hooksPush(
            kind: "tool",
            payload: try JSONValue.parse(Data(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)))
        let report = try #require(ClaudeCodeAdapter().parse(raw))
        try await env.svc.report(t.id, report)

        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.desc == "Running: ls")
        #expect(after.status == .running)
    }
```

- [ ] **Step 2: Run test to verify it passes already** (it exercises Task-2 code + the untouched merge)

Run: `./scripts/test.sh --filter ParseTests` (unsandboxed)
Expected: PASS — this test does not depend on the CLI rewire; it guards that the parse output still merges through `service.report`. (Written now so Step 3's CLI edit is covered by a green round-trip.)

- [ ] **Step 3: Rewire `ReportHelper.run` and delete `map`/`toolDesc`**

In `Sources/orchestra/ReportHelper.swift`:

Replace line 27:

```swift
        guard let report = map(kind: kind, payload: payload) else { return }  // dropped (e.g. transition SessionEnd)
```

with (the push transport now delegates the agent-dependent conversion to the adapter):

```swift
        // Parse is the ADAPTER's (agent-dependent, D3). This `_report` process IS the Claude hooksPush
        // transport; it supplies raw bytes and lets the adapter normalize them. Daemon-side transports
        // (Codex rollout tail, next PR) call the same `adapter.parse` seam.
        guard let report = ClaudeCodeAdapter().parse(.hooksPush(kind: kind, payload: payload))
        else { return }  // dropped (e.g. transition SessionEnd, unknown kind)
```

Then **delete** the `// MARK: mapping` block — the entire `static func map(kind:payload:) -> StatusReport?` (lines 38–70) and `static func toolDesc(tool:input:) -> String` (lines 72–87). Leave the `// MARK: statusLine display` section (`statusLineTimeout`, `renderStatusLine`, `globalStatusLineCommand`) and `// MARK: bounded send` (`boundedSend`) intact — they are agent-side statusline *display* + transport, not parse.

- [ ] **Step 4: Verify the CLI target compiles and the round-trip stays green**

Run: `./scripts/test.sh --filter ParseTests` (unsandboxed)
Expected: PASS. (`swift build` of the `orchestra` target now has no `map`/`toolDesc`; `ReportHelper.run` calls the adapter.)

- [ ] **Step 5: Confirm no dangling references to the deleted functions**

Run: `grep -rn "ReportHelper.map\|\.map(kind\|toolDesc" Sources Tests`
Expected: no matches.

- [ ] **Step 6: Commit**

```bash
git add Sources/orchestra/ReportHelper.swift Tests/OrchestraCoreTests/ParseTests.swift
git commit -m "refactor(telemetry): _report push transport delegates parse to adapter; drop CLI map/toolDesc"
```

---

### Task 4: Full green gate + as-built recording

**Files:**
- Modify: `notes/designs/agent-provider-interface/02-contract.md` (record A2 as-built symbols)

- [ ] **Step 1: Full unit suite green (the merge gate)**

Run: `./scripts/test.sh` (unsandboxed — if `sandbox-exec sandbox_apply` error, re-run with the sandbox disabled)
Expected: PASS — all suites, crucially `ReportTests`, `AdapterTests`, `RecoveryTests` **unchanged and green** (behavior-preservation proof), plus the new `ParseTests`.

- [ ] **Step 2: App typecheck green**

Run: `DEVELOPER_DIR=/Library/Developer/CommandLineTools ./scripts/typecheck-app.sh` (unsandboxed; the `DEVELOPER_DIR` aligns the OrchestraCore module SDK with the app typecheck SDK — drop it if the script passes without)
Expected: PASS.

- [ ] **Step 3: UX e2e (advisory acceptance — not a merge gate, per rule O6)**

Run: `./scripts/orch-ux-e2e.sh --run-id a2telem` (unsandboxed, concurrency-safe per-run id)
Expected: PASS (spawn→telemetry→board round-trips through the real UI). If it fails for TCC/window-server reasons unrelated to A2, record it as advisory — the unit gate (Steps 1–2) governs merge readiness.

- [ ] **Step 4: Record A2 as-built symbols in the contract layer**

In `notes/designs/agent-provider-interface/02-contract.md`, under the `Adapter.parse(raw) -> StatusReport` contract (Area 1 · Retrieve), add an **As-built (A2, shipped)** note recording the real symbols:

```markdown
- **As-built (A2, shipped):** `RawTelemetry` (`Agents/Telemetry.swift`) — `enum RawTelemetry {case hooksPush(kind:payload:); case fileTail(line:)}`. `Adapter.parse(_ raw: RawTelemetry) -> StatusReport?` added to the protocol with a `nil` default (additive). `ClaudeCodeAdapter.parse` owns the `hooksPush` conversion (relocated verbatim from the former `orchestra` CLI `ReportHelper.map`/`toolDesc`); the `_report` push transport calls it. Daemon `report` endpoint + `OrchestraService.report` merge unchanged (ReportTests byte-identical). `fileTail` parse + rollout tailer land in B2.
```

- [ ] **Step 5: Commit**

```bash
git add notes/designs/agent-provider-interface/02-contract.md
git commit -m "docs(a2): record telemetry-source seam as-built symbols (parse relocation)"
```

---

## Self-Review

**Spec coverage (A2 row of the 03-implementation forest table):**
- ✅ "telemetry **transport** (push/tail) + **`adapter.parse`** ownership; Claude=push" — `RawTelemetry` (push+tail cases) + `Adapter.parse`; push transport calls `ClaudeCodeAdapter.parse` (Tasks 1–3).
- ✅ "transport/parse boundary" — transport supplies `RawTelemetry`, adapter owns `parse` (Task 1 doc + `test_adapter_owns_parse`).
- ✅ "tailer lifecycle" — covered in the plan: `.fileTail` case reserved; the tailer itself is B2 (daemon-side, calls the same `adapter.parse`). Documented in File Structure rationale + as-built note; not built here (scope).
- ✅ "parse is per-adapter — relocate `ReportHelper.map` from the `orchestra` CLI target into the adapter (cross-target move)" — Task 2 (into `ClaudeCodeAdapter`, OrchestraCore) + Task 3 (delete CLI copy).
- ✅ "`parse` added **defaulted** (additive, not a mutation)" — Task 1, `nil` default in `extension Adapter`.
- ✅ "`ReportTests` byte-identical" — Global Constraints + Task 4 Step 1; merge path untouched.
- ✅ Unit tests named in the process: `test_adapter_owns_parse`, `test_claude_report_unchanged`, spawn→telemetry→board round-trip (`test_parse_report_reaches_board`).
- ✅ e2e via `scripts/orch-ux-e2e.sh --run-id a2telem` (Task 4 Step 3).
- ✅ Guardrail: `EventReport` gains **no** turn/approval fields (untouched).

**Placeholder scan:** none — every code step shows exact code; every command shows expected output.

**Type consistency:** `RawTelemetry` cases (`hooksPush(kind:payload:)`, `fileTail(line:)`), `parse(_ raw: RawTelemetry) -> StatusReport?`, and `StatusReport(...)` flat constructor usage are consistent across Tasks 1–3 and match the existing `Model.swift` initializer signatures and `JSONValue` accessors (`.stringValue`, `.doubleValue`, subscript) verified in source.

## Execution Handoff

Per the task process, this plan is executed **inline in this session** (single-agent PR card), then the card moves to `review` for the orchestrator to merge — no subagent dispatch. Use superpowers:test-driven-development per task.
