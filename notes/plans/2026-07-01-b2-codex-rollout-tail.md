# B2 — Codex rollout-tail telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tail a Codex agent's rollout JSONL file, convert each line to a normalized `StatusReport` through the frozen `adapter.parse` seam (`RawTelemetry.fileTail`), and merge it onto the card — so a Codex card shows live context %, running/idle status, and model, fully offline.

**Architecture:** The **daemon owns the transport** — a new `RolloutTailer` actor tracks a per-card byte offset into the rollout file and hands complete lines to `OrchestraService.pollTelemetry()`, which is driven by the existing 2-second daemon poll loop (alongside `reconcileLiveness`). The **`CodexAdapter` owns parse** — a new `parse(.fileTail(line:))` converts one rollout line into a `StatusReport`, tolerating field renames (`TaskComplete`→`TurnComplete`), computing `ctxPct` as tail tokens ÷ its own offline model table's `contextWindow` (E1), and mapping turn boundaries to running/idle. Seq comes from the line's `timestamp` so `report()`'s seq-gate keeps the freshest snapshot. No changes to A2's transport seam (the `RawTelemetry` enum / `parse` protocol method) — B2 only *adds* the `fileTail` producer + the Codex `fileTail` consumer.

**Tech Stack:** Swift 6, swift-testing (`@Suite`/`@Test`/`#expect`/`#require`), SwiftPM (offline). Runs via `scripts/test.sh`; app typecheck via `scripts/typecheck-app.sh`.

## Global Constraints

- **Offline always** — no network at build/test/runtime. The Codex model table is a **vendored** `Resources/codex-models.json`, `.copy`-bundled; the rollout fixture is in-repo (inline Swift strings + a written temp file). Copied verbatim from the offline pref (§6 / D7).
- **Never spawn a real agent** — `USE_REAL_CLAUDE` stays unset; no `codex`/`claude` process. `StubSessions` records argv; rollout files are hand-written to a temp `CODEX_HOME`. (Rule O5.)
- **Do NOT rebuild the A2 transport seam** — `RawTelemetry` (enum, `Agents/Telemetry.swift`) and `Adapter.parse(_:) -> StatusReport?` (protocol + `nil` default, `Agents/Adapter.swift`) are frozen. B2 adds the `fileTail` transport (daemon tailer) + `CodexAdapter.parse` only.
- **Claude telemetry stays byte-identical** — `pollTelemetry` gates on `capabilities.telemetry == .fileTail`, so Claude (`.hooksPush`) is never tailed. `ReportTests`/`ParseTests` must stay green unchanged.
- **Transport ≠ parse** — the tailer never inspects JSON; the adapter never reads files or offsets. The only thing crossing between them is a `String` line and a `StatusReport?`.
- **B1/A2/E1 symbols are as-built** (all merged): `CodexAdapter` (`id="codex"`, `.discovered`/`.fileTail`/`.tokens`, `sessionInfo`/`discover`/`rolloutPath`, `models()` loading `"codex-models"` via `ModelCatalog`), `RawTelemetry.fileTail(line:)`, `AgentModel.ctxPct(usedTokens:)`, `OrchestraService.report(_:_:)` seq-gate.

---

## File Structure

| File | Responsibility | New/Modify |
|------|----------------|------------|
| `Sources/OrchestraCore/Resources/codex-models.json` | Offline Codex model table (id → `contextWindow` + flags), the `ctxPct` denominator | Create |
| `Package.swift` | `.copy("Resources/codex-models.json")` so the table bundles | Modify |
| `Sources/OrchestraCore/Agents/CodexAdapter.swift` | `parse(.fileTail(line:))` — rollout line → `StatusReport` (ctxPct/status/model, rename-tolerant, timestamp-seq) | Modify |
| `Sources/OrchestraCore/RolloutTailer.swift` | Daemon-side transport: per-card byte-offset tailer; `newLines(cardId:path:)` returns new complete lines | Create |
| `Sources/OrchestraCore/OrchestraService.swift` | `let tailer = RolloutTailer()`; `pollTelemetry()` drives tail→parse→report for `.fileTail` cards | Modify |
| `Sources/orchestrad/main.swift` | Call `service.pollTelemetry()` in the existing 2s poll loop | Modify |
| `Tests/OrchestraCoreTests/CodexRolloutTests.swift` | Parse fixture, rename tolerance, seq-gate, `test_ctxpct_from_model_table`, idle signal, tailer offsets, tail→parse→report e2e | Create |

**Interfaces produced (later phases/PRs rely on these exact signatures):**
- `CodexAdapter.parse(_ raw: RawTelemetry) -> StatusReport?` (overrides the protocol `nil` default for `.fileTail`).
- `actor RolloutTailer { func newLines(cardId: UUID, path: String) -> [String]; func forget(_ cardId: UUID) }`
- `OrchestraService.pollTelemetry() async` (public, driven by the daemon loop; also callable from tests).

---

### Task 1: Vendored Codex model table (the ctxPct denominator)

**Files:**
- Create: `Sources/OrchestraCore/Resources/codex-models.json`
- Modify: `Package.swift:35` (add the `.copy` line)
- Test: `Tests/OrchestraCoreTests/CodexRolloutTests.swift` (new suite `CodexModelTableTests`)

**Interfaces:**
- Consumes: `CodexAdapter.models()` (already loads `ModelCatalog.load("codex-models")`), `AgentModel.contextWindow`, `AgentModel.ctxPct(usedTokens:)`.
- Produces: a non-empty offline table where `gpt-5-codex.contextWindow == 272000` (the value the parse divides by).

- [ ] **Step 1: Write the failing test**

Add to a new file `Tests/OrchestraCoreTests/CodexRolloutTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Codex model table — vendored offline (E1 denominator for B2)")
struct CodexModelTableTests {
    let adapter = CodexAdapter()

    @Test("known Codex model resolves to its offline context window")
    func knownModelHasWindow() {
        let m = adapter.model(for: "gpt-5-codex")
        #expect(m.contextWindow == 272_000)
        #expect(m.displayName == "GPT-5 Codex")
    }

    @Test("unknown Codex model id falls back (no fabricated window)")
    func unknownFallsBack() {
        let m = adapter.model(for: "totally-made-up")
        #expect(m.id == "totally-made-up")
        #expect(m.contextWindow == nil)
    }

    @Test("table is loaded OFFLINE from the bundled local file (no network)")
    func offlineLocalResource() throws {
        let url = try #require(Bundle.module.url(forResource: "codex-models", withExtension: "json"))
        #expect(url.isFileURL)
        #expect(!ModelCatalog.load("codex-models").isEmpty)
    }

    @Test("every table entry carries a positive context window")
    func populated() {
        #expect(adapter.models().allSatisfy { ($0.contextWindow ?? 0) > 0 })
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter CodexModelTableTests`
Expected: FAIL — `Bundle.module.url(forResource: "codex-models"...)` is nil (resource not bundled), and `model(for:).contextWindow` is nil (the B1 fallback list has no `contextWindow`).

- [ ] **Step 3: Create the resource**

`Sources/OrchestraCore/Resources/codex-models.json` (mirror the `claude-code-models.json` shape; values are vendored/offline — GPT-5-family context window 272k):

```json
[
  { "id": "gpt-5-codex", "displayName": "GPT-5 Codex", "family": "gpt", "contextWindow": 272000,
    "flags": { "toolCall": true, "reasoning": true, "vision": false } },
  { "id": "gpt-5", "displayName": "GPT-5", "family": "gpt", "contextWindow": 272000,
    "flags": { "toolCall": true, "reasoning": true, "vision": true } },
  { "id": "o3", "displayName": "o3", "family": "gpt", "contextWindow": 200000,
    "flags": { "toolCall": true, "reasoning": true, "vision": false } }
]
```

- [ ] **Step 4: Bundle it**

`Package.swift`, in the `OrchestraCore` target `resources:` array, after line 35:

```swift
                .copy("Resources/claude-code-models.json"),
                .copy("Resources/codex-models.json"),
```

- [ ] **Step 5: Run to verify it passes**

Run: `./scripts/test.sh --filter CodexModelTableTests`
Expected: PASS (4 tests). If a stale `.build` masks the new resource, `rm -rf .build` **in this worktree only** and re-run.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Resources/codex-models.json Package.swift Tests/OrchestraCoreTests/CodexRolloutTests.swift
git commit -m "feat(b2): vendor offline codex-models.json (ctxPct denominator)"
```

---

### Task 2: `CodexAdapter.parse(.fileTail)` — rollout line → StatusReport

**Files:**
- Modify: `Sources/OrchestraCore/Agents/CodexAdapter.swift` (add `parse` + private helpers, after `newSessionId()`)
- Test: `Tests/OrchestraCoreTests/CodexRolloutTests.swift` (new suite `CodexRolloutParseTests`)

**Interfaces:**
- Consumes: `RawTelemetry.fileTail(line:)`, `JSONValue.parse(_:)`, `StatusReport(seq:ctxPct:modelId:desc:status:)`, `AgentModel.ctxPct(usedTokens:)`, `self.model(for:)`.
- Produces: `func parse(_ raw: RawTelemetry) -> StatusReport?` on `CodexAdapter`.

**Rollout line shape (the fixture contract).** Each line is one JSON object with an optional `timestamp` and a `type`; the meaningful sub-kind for `event_msg` lives at `payload.type`. The parse is **rename-tolerant**: it lowercases + strips `_` from both `type` fields and matches on substrings, so `TaskComplete`/`turn_complete`/`TurnComplete` all mean "idle", and token totals are read from `total_token_usage.total_tokens` OR a renamed `total_tokens`.

Recognized signals (in priority order):
| Line kind (normalized) | → `StatusReport` |
|---|---|
| `turncomplete` / `taskcomplete` | `status: .waiting` (**idle signal**) |
| `tokencount` / `tokenusage` | `ctxPct` (tokens ÷ model window) + `modelId` |
| `taskstarted` / `turnstarted` | `status: .running` |
| `responseitem` / `functioncall` (has `name`) | `status: .running`, `desc: "Running <name>"` |
| anything else | `nil` (dropped, incl. `session_meta`) |

`seq` = the line `timestamp` in **microseconds** since epoch (monotonic since the tailer delivers lines in file order); absent/unparseable → `0` (still applies, since in-order delivery needs no gate).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/OrchestraCoreTests/CodexRolloutTests.swift`:

```swift
@Suite("Codex rollout parse — fileTail line → StatusReport")
struct CodexRolloutParseTests {
    let a = CodexAdapter()

    private func tail(_ s: String) -> StatusReport? { a.parse(.fileTail(line: s)) }

    @Test("test_rollout_to_statusreport: task_started → running")
    func taskStartedRunning() throws {
        let r = try #require(tail(#"{"timestamp":"2026-07-01T10:00:02.000Z","type":"event_msg","payload":{"type":"task_started"}}"#))
        #expect(r.snapshot?.status == .running)
    }

    @Test("token_count → ctxPct (tokens ÷ table window) + modelId")
    func tokenCountCtx() throws {
        // 68000 / 272000 = 25%
        let line = #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5-codex","total_token_usage":{"total_tokens":68000}}}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.ctxPct == 25.0)
        #expect(r.snapshot?.modelId == "gpt-5-codex")
    }

    @Test("test_ctxpct_from_model_table: ctxPct denominator is the OFFLINE model window, not the rollout's")
    func ctxPctFromModelTable() throws {
        // Rollout carries a bogus in-line window; parse must ignore it and use codex-models.json (272000).
        let line = #"{"timestamp":"2026-07-01T10:00:06.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5-codex","model_context_window":999,"total_token_usage":{"total_tokens":136000}}}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.ctxPct == 50.0)   // 136000 / 272000, NOT 136000/999
    }

    @Test("function_call → running + desc")
    func functionCallDesc() throws {
        let line = #"{"timestamp":"2026-07-01T10:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"shell"}}"#
        let r = try #require(tail(line))
        #expect(r.snapshot?.status == .running)
        #expect(r.snapshot?.desc == "Running shell")
    }

    @Test("idle signal: TurnComplete → waiting")
    func idleSignal() throws {
        let r = try #require(tail(#"{"timestamp":"2026-07-01T10:00:09.000Z","type":"event_msg","payload":{"type":"TurnComplete"}}"#))
        #expect(r.snapshot?.status == .waiting)
    }

    @Test("rename tolerance: old TaskComplete AND new TurnComplete both mean idle")
    func renameToleranceTurn() throws {
        #expect(tail(#"{"type":"event_msg","payload":{"type":"TaskComplete"}}"#)?.snapshot?.status == .waiting)
        #expect(tail(#"{"type":"event_msg","payload":{"type":"turn_complete"}}"#)?.snapshot?.status == .waiting)
    }

    @Test("rename tolerance: total_token_usage.total_tokens AND a flat total_tokens both parse")
    func renameToleranceTokens() throws {
        let nested = #"{"type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5-codex","total_token_usage":{"total_tokens":68000}}}}"#
        let flat   = #"{"type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5-codex","total_tokens":68000}}}"#
        #expect(tail(nested)?.snapshot?.ctxPct == 25.0)
        #expect(tail(flat)?.snapshot?.ctxPct == 25.0)
    }

    @Test("seq-gate mapping: later timestamp → strictly larger seq")
    func seqFromTimestamp() throws {
        let t1 = try #require(tail(#"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"task_started"}}"#))
        let t2 = try #require(tail(#"{"timestamp":"2026-07-01T10:00:06.000Z","type":"event_msg","payload":{"type":"task_started"}}"#))
        #expect((t2.snapshot?.seq ?? 0) > (t1.snapshot?.seq ?? 0))
    }

    @Test("unhandled + junk lines drop to nil")
    func junkDropsNil() {
        #expect(tail("not json at all") == nil)
        #expect(tail("") == nil)
        #expect(tail(#"{"type":"session_meta","payload":{"id":"x"}}"#) == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter CodexRolloutParseTests`
Expected: FAIL — `CodexAdapter` has no `parse` override; every `tail(...)` returns `nil` (protocol default).

- [ ] **Step 3: Implement `parse` in `CodexAdapter`**

In `Sources/OrchestraCore/Agents/CodexAdapter.swift`, add after `public func newSessionId() -> String? { nil }` (line 54):

```swift
    // MARK: telemetry parse (fileTail) — the daemon tails the rollout JSONL; THIS converts one line.

    /// Codex telemetry is `fileTail`: the daemon-side `RolloutTailer` hands one rollout JSONL line at a
    /// time; this converts it to a normalized `StatusReport`. AGENT-DEPENDENT (D3) — the mapping lives
    /// here, never in core. Rename-tolerant (Codex's rollout schema drifts: `TaskComplete`→`TurnComplete`,
    /// nested vs flat token totals). `ctxPct` uses THIS adapter's OFFLINE model table as the denominator
    /// (E1), never the rollout's own window. `seq` is the line timestamp (µs) so out-of-order/duplicate
    /// lines lose to the freshest via `report()`'s seq-gate. Any unrecognized line → nil (dropped).
    public func parse(_ raw: RawTelemetry) -> StatusReport? {
        guard case let .fileTail(line) = raw else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let jv = try? JSONValue.parse(Data(trimmed.utf8)) else { return nil }
        let payload = jv["payload"] ?? jv
        let seq = Self.rolloutSeq(jv)
        // Normalize BOTH the top-level and payload `type` (lower-cased, `_` stripped) for rename tolerance.
        let kinds = [jv["type"]?.stringValue, payload["type"]?.stringValue]
            .compactMap { $0 }.map(Self.norm)
        func any(_ needles: String...) -> Bool { kinds.contains { k in needles.contains { k.contains($0) } } }

        // Idle signal FIRST (a completed turn ends `.running`, rename-tolerant).
        if any("turncomplete", "taskcomplete") {
            return StatusReport(seq: seq, status: .waiting)
        }
        // Token usage → ctxPct (÷ offline model window) + modelId. No status (avoids churn vs turn edges).
        if any("tokencount", "tokenusage") {
            let info = payload["info"] ?? payload
            let mid = (info["model"] ?? payload["model"])?.stringValue
            let total = Self.tokenTotal(info)
            let pct = (mid != nil && total != nil) ? model(for: mid!).ctxPct(usedTokens: total!) : nil
            guard pct != nil || mid != nil else { return nil }
            return StatusReport(seq: seq, ctxPct: pct, modelId: mid)
        }
        // Turn start → running.
        if any("taskstarted", "turnstarted") {
            return StatusReport(seq: seq, status: .running)
        }
        // A tool/function call mid-turn → running (+ a coarse desc).
        if any("functioncall", "responseitem") {
            if let name = payload["name"]?.stringValue, !name.isEmpty {
                return StatusReport(seq: seq, desc: "Running \(name)", status: .running)
            }
            return StatusReport(seq: seq, status: .running)
        }
        return nil
    }

    /// Lower-case + drop underscores so `task_complete` / `TaskComplete` / `TurnComplete` normalize alike.
    private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "_", with: "")
    }

    /// Total tokens from a usage `info` object, tolerating the nested (`total_token_usage.total_tokens`)
    /// and flat (`total_tokens` / `tokens`) shapes the rollout schema has used.
    private static func tokenTotal(_ info: JSONValue) -> Int? {
        info["total_token_usage"]?["total_tokens"]?.intValue
            ?? info["total_tokens"]?.intValue
            ?? info["tokens"]?.intValue
    }

    /// Monotonic seq from the line's RFC3339 `timestamp`, in microseconds since epoch. Absent/unparseable
    /// → 0 (still applies: the tailer delivers lines in file order, so a 0-seq snapshot is never stale).
    private static func rolloutSeq(_ jv: JSONValue) -> UInt64 {
        guard let ts = jv["timestamp"]?.stringValue else { return 0 }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let d = withFrac.date(from: ts) ?? plain.date(from: ts) else { return 0 }
        return UInt64(max(0, d.timeIntervalSince1970 * 1_000_000))
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter CodexRolloutParseTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Agents/CodexAdapter.swift Tests/OrchestraCoreTests/CodexRolloutTests.swift
git commit -m "feat(b2): CodexAdapter.parse(.fileTail) — rollout line → StatusReport (rename-tolerant, offline ctxPct)"
```

---

### Task 3: `RolloutTailer` — the daemon-side byte-offset transport

**Files:**
- Create: `Sources/OrchestraCore/RolloutTailer.swift`
- Test: `Tests/OrchestraCoreTests/CodexRolloutTests.swift` (new suite `RolloutTailerTests`)

**Interfaces:**
- Consumes: `FileHandle`, a rollout file path.
- Produces: `actor RolloutTailer { func newLines(cardId: UUID, path: String) -> [String]; func forget(_ cardId: UUID) }`.

**Contract:** `newLines` returns only **complete** (newline-terminated) lines appended since the last call for that card, advancing the per-card offset by exactly the bytes consumed. A trailing partial line (no newline yet) is held until completed. If the file shrank below the stored offset (rotation/truncation), reset to 0.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/OrchestraCoreTests/CodexRolloutTests.swift`:

```swift
@Suite("RolloutTailer — per-card byte-offset transport")
struct RolloutTailerTests {
    private func tmpFile() -> String {
        NSTemporaryDirectory() + "rollout-\(UUID().uuidString).jsonl"
    }
    private func append(_ path: String, _ text: String) {
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(Data(text.utf8)); try? fh.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    @Test("first read returns all complete lines")
    func firstRead() async {
        let path = tmpFile(); let id = UUID()
        append(path, "a\nb\nc\n")
        let t = RolloutTailer()
        #expect(await t.newLines(cardId: id, path: path) == ["a", "b", "c"])
    }

    @Test("second read returns only newly-appended lines")
    func incremental() async {
        let path = tmpFile(); let id = UUID()
        append(path, "a\nb\n")
        let t = RolloutTailer()
        _ = await t.newLines(cardId: id, path: path)
        append(path, "c\nd\n")
        #expect(await t.newLines(cardId: id, path: path) == ["c", "d"])
    }

    @Test("a trailing partial line is held until it is completed")
    func partialHeld() async {
        let path = tmpFile(); let id = UUID()
        append(path, "a\nb")                 // "b" has no newline yet
        let t = RolloutTailer()
        #expect(await t.newLines(cardId: id, path: path) == ["a"])
        append(path, "bb\n")                 // completes -> "bbb"
        #expect(await t.newLines(cardId: id, path: path) == ["bbb"])
    }

    @Test("no new bytes → empty")
    func nothingNew() async {
        let path = tmpFile(); let id = UUID()
        append(path, "a\n")
        let t = RolloutTailer()
        _ = await t.newLines(cardId: id, path: path)
        #expect(await t.newLines(cardId: id, path: path) == [])
    }

    @Test("missing file → empty, no crash")
    func missingFile() async {
        let t = RolloutTailer()
        #expect(await t.newLines(cardId: UUID(), path: "/no/such/rollout.jsonl") == [])
    }

    @Test("truncation/rotation below offset resets to 0")
    func truncationResets() async {
        let path = tmpFile(); let id = UUID()
        append(path, "x\ny\nz\n")
        let t = RolloutTailer()
        _ = await t.newLines(cardId: id, path: path)
        try? "n\n".write(toFile: path, atomically: true, encoding: .utf8)   // shorter file
        #expect(await t.newLines(cardId: id, path: path) == ["n"])
    }

    @Test("offsets are independent per card")
    func perCard() async {
        let path = tmpFile(); let a = UUID(); let b = UUID()
        append(path, "1\n2\n")
        let t = RolloutTailer()
        _ = await t.newLines(cardId: a, path: path)
        #expect(await t.newLines(cardId: b, path: path) == ["1", "2"])   // b starts fresh
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter RolloutTailerTests`
Expected: FAIL — `RolloutTailer` is undefined (compile error).

- [ ] **Step 3: Implement `RolloutTailer`**

Create `Sources/OrchestraCore/RolloutTailer.swift`:

```swift
import Foundation

/// The daemon-side telemetry TRANSPORT for `fileTail` agents (Codex). It owns nothing agent-specific:
/// it tails a rollout/transcript file, tracking a per-card byte offset, and hands complete lines to the
/// caller, which passes each to `adapter.parse(.fileTail(line:))`. The split of concerns is the seam —
/// the transport never inspects JSON (that's the adapter's parse), the adapter never touches files.
///
/// `newLines` returns only NEWLINE-TERMINATED lines appended since the last call for that card; a
/// trailing partial line is held until the writer completes it (rollout writes are line-at-a-time but
/// a poll can land mid-write). A file shorter than the stored offset (rotation/truncation) resets to 0.
public actor RolloutTailer {
    private var offsets: [UUID: UInt64] = [:]

    public init() {}

    public func newLines(cardId: UUID, path: String) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        var start = offsets[cardId] ?? 0
        if size < start { start = 0 }                       // rotation/truncation → re-read from the top
        guard size > start else { offsets[cardId] = size; return [] }

        try? fh.seek(toOffset: start)
        let data = fh.readDataToEndOfFile()
        guard let lastNL = data.lastIndex(of: 0x0A) else {  // no complete line yet — hold the partial
            return []
        }
        let consumable = data[...lastNL]                    // through the final newline (inclusive)
        offsets[cardId] = start + UInt64(consumable.count)
        return String(decoding: consumable, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Drop a card's cursor (on death/archive) so a later id reusing the path re-reads from 0.
    public func forget(_ cardId: UUID) { offsets[cardId] = nil }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter RolloutTailerTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/RolloutTailer.swift Tests/OrchestraCoreTests/CodexRolloutTests.swift
git commit -m "feat(b2): RolloutTailer — daemon-side per-card byte-offset transport"
```

---

### Task 4: Wire the tailer into the service + daemon poll (tail → parse → report)

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift:16` (add `let tailer`), and add `pollTelemetry()` (near `resolveTrust`, before `spawn`)
- Modify: `Sources/orchestrad/main.swift:43` (call `pollTelemetry()` in the poll loop)
- Test: `Tests/OrchestraCoreTests/CodexRolloutTests.swift` (new suite `CodexTelemetryE2ETests`)

**Interfaces:**
- Consumes: `store.all()`, `registry.get(_:)`, `adapter.capabilities.telemetry`, `adapter.sessionInfo(_:current:prior:)?.transcriptPath`, `tailer.newLines(cardId:path:)`, `adapter.parse(.fileTail(line:))`, `self.report(_:_:)`.
- Produces: `OrchestraService.pollTelemetry() async`.

- [ ] **Step 1: Write the failing test (end-to-end tail→parse→report + seq-gate)**

Add to `Tests/OrchestraCoreTests/CodexRolloutTests.swift`. This spawns a Codex card (stub sessions, isolated temp `CODEX_HOME`), writes a rollout file the adapter's `discover()` finds, then drives `pollTelemetry()`:

```swift
@Suite("Codex telemetry e2e — tail → parse → report → board")
struct CodexTelemetryE2ETests {

    /// Spawn a codex card with an isolated CODEX_HOME + StubSessions, and return the pieces.
    private func makeEnv() async throws -> (svc: OrchestraService, card: Task, rollout: String) {
        let base = NSTemporaryDirectory() + "codex-tel-\(UUID().uuidString)"
        let work = base + "/work"
        let codexHome = base + "/codexhome"
        let day = codexHome + "/sessions/2026/07/01"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        let sid = UUID().uuidString.lowercased()
        let rollout = "\(day)/rollout-2026-07-01T10-00-00-\(sid).jsonl"
        FileManager.default.createFile(atPath: rollout, contents: nil)

        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)])
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: codexHome)
        let svc = OrchestraService(config: config,
                                   store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [codex]),
                                   worktrees: StubWorktrees(root: config.worktreesRoot),
                                   sessions: StubSessions(),
                                   trust: TrustLedger(path: base + "/trust.json"))
        let card = try await svc.spawn(SpawnInput(prompt: "look", agentId: "codex",
                                                  model: "gpt-5-codex",
                                                  cwd: PathResolver.canonical(work)))
        return (svc, card, rollout)
    }

    private func append(_ path: String, _ line: String) {
        let fh = FileHandle(forWritingAtPath: path)!
        fh.seekToEndOfFile(); fh.write(Data((line + "\n").utf8)); try? fh.close()
    }

    @Test("pollTelemetry tails a Codex rollout and updates the card's ctxPct + status")
    func tailUpdatesBoard() async throws {
        let (svc, card, rollout) = try await makeEnv()
        append(rollout, #"{"timestamp":"2026-07-01T10:00:02.000Z","type":"event_msg","payload":{"type":"task_started"}}"#)
        append(rollout, #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5-codex","total_token_usage":{"total_tokens":68000}}}}"#)
        await svc.pollTelemetry()

        let after = try #require(await svc.list().first { $0.id == card.id })
        #expect(after.ctxPct == 25.0)
        #expect(after.status == .running)
    }

    @Test("idle signal reaches the board: TurnComplete → waiting")
    func idleReachesBoard() async throws {
        let (svc, card, rollout) = try await makeEnv()
        append(rollout, #"{"timestamp":"2026-07-01T10:00:09.000Z","type":"event_msg","payload":{"type":"TurnComplete"}}"#)
        await svc.pollTelemetry()
        let after = try #require(await svc.list().first { $0.id == card.id })
        #expect(after.status == .waiting)
    }

    @Test("seq-gate holds end-to-end: a stale (earlier-timestamp) ctx line can't overwrite a fresher one")
    func seqGateHoldsE2E() async throws {
        let (svc, card, rollout) = try await makeEnv()
        // Fresh ctx first (later ts, 50%), then a STALE ctx (earlier ts, 10%) appended after.
        append(rollout, #"{"timestamp":"2026-07-01T10:00:20.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5-codex","total_token_usage":{"total_tokens":136000}}}}"#)
        await svc.pollTelemetry()
        append(rollout, #"{"timestamp":"2026-07-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5-codex","total_token_usage":{"total_tokens":27200}}}}"#)
        await svc.pollTelemetry()

        let after = try #require(await svc.list().first { $0.id == card.id })
        #expect(after.ctxPct == 50.0)   // the stale 10% snapshot was dropped by the seq-gate
    }

    @Test("a Claude (hooksPush) card is NOT tailed by pollTelemetry")
    func claudeNotTailed() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "b"))
        await env.svc.pollTelemetry()   // must be a no-op for hooksPush; no crash, no change
        let after = try #require(await env.svc.list().first { $0.id == t.id })
        #expect(after.status == t.status)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter CodexTelemetryE2ETests`
Expected: FAIL — `pollTelemetry` is undefined on `OrchestraService`.

- [ ] **Step 3: Add the `tailer` property**

`Sources/OrchestraCore/OrchestraService.swift`, after line 16 (`let authRate = AuthRateMonitor()`):

```swift
    /// Daemon-side rollout TRANSPORT for `fileTail` agents (Codex). Tracks a per-card byte offset; the
    /// poll loop hands its lines to `adapter.parse`. Claude (`hooksPush`) never touches it.
    let tailer = RolloutTailer()
```

- [ ] **Step 4: Add `pollTelemetry()`**

`Sources/OrchestraCore/OrchestraService.swift`, add just before `// MARK: - spawn` (line 100):

```swift
    // MARK: - telemetry (fileTail transport)

    /// One tick of the daemon-side rollout tail. For every live `fileTail` card (Codex), read the lines
    /// appended to its rollout file since last tick and merge each through the adapter's own `parse`
    /// (agent-dependent, D3) via `report` (seq-gated). Push agents (Claude `hooksPush`) are skipped —
    /// their telemetry arrives out-of-band via the `_report` endpoint, so this stays Claude-inert.
    /// Driven by the daemon's 2s poll loop, alongside `reconcileLiveness`.
    public func pollTelemetry() async {
        let tasks = await store.all()
        for t in tasks where !t.archived && t.status != .dead {
            guard let adapter = try? registry.get(t.agentId),
                  adapter.capabilities.telemetry == .fileTail else { continue }
            // Resolve the rollout path from the adapter (uses the tracked id, else discovers the newest).
            let ctx = AdapterContext(cwd: t.cwd, model: t.model.id, sessionId: t.agentSessionId,
                                     name: t.title, access: t.access)
            guard let path = adapter.sessionInfo(ctx, current: t.agentSessionId,
                                                 prior: t.priorSessionIds)?.transcriptPath,
                  FileManager.default.fileExists(atPath: path) else { continue }
            for line in await tailer.newLines(cardId: t.id, path: path) {
                if let patch = adapter.parse(.fileTail(line: line)) {
                    try? await report(t.id, patch)
                }
            }
        }
    }
```

- [ ] **Step 5: Drive it from the daemon loop**

`Sources/orchestrad/main.swift`, in the poll loop (after line 43 `await service.reconcileLiveness()`):

```swift
        await service.reconcileLiveness()
        await service.pollTelemetry()
```

- [ ] **Step 6: Run to verify it passes**

Run: `./scripts/test.sh --filter CodexTelemetryE2ETests`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Sources/orchestrad/main.swift Tests/OrchestraCoreTests/CodexRolloutTests.swift
git commit -m "feat(b2): pollTelemetry drives rollout tail→parse→report; wire into daemon poll"
```

---

### Task 5: Full-suite verification + docs sync

**Files:**
- Modify: `notes/designs/agent-provider-interface/02-contract.md` (record B2 as-built under the `Adapter.parse` / telemetry contract)

- [ ] **Step 1: Full unit suite green**

Run: `./scripts/test.sh` (UNSANDBOXED shell — swift build/test needs it).
Expected: PASS. Known flake: if the ONLY failure is `RecoveryTests "resume success: confirmed within grace"`, re-run `./scripts/test.sh --filter RecoveryTests` in isolation to confirm green, then treat as green.

- [ ] **Step 2: App typecheck green**

Run: `./scripts/typecheck-app.sh` (self-pins CLT; no `DEVELOPER_DIR`).
Expected: PASS. (B2 touches no App/ Swift — this guards the core changes compile against the app.)

- [ ] **Step 3: Advisory UX e2e (telemetry-touching PR, per O6)**

Run: `./scripts/orch-ux-e2e.sh --run-id b2tail`
Expected: advisory — a screenshot step may fail on a headless/locked window server (environmental, NOT a defect). Unit tests + typecheck are the gate.

- [ ] **Step 4: Record B2 as-built in the contract doc**

In `notes/designs/agent-provider-interface/02-contract.md`, under the `Adapter.parse(raw) -> StatusReport` **As-built** note, append a B2 line: `CodexAdapter.parse` owns the `fileTail` conversion (rename-tolerant, timestamp-seq, ctxPct ÷ offline `codex-models.json` window); the daemon-side `RolloutTailer` (per-card byte offset) + `OrchestraService.pollTelemetry()` are the `fileTail` transport, driven by the 2s poll loop; Claude push path unchanged.

- [ ] **Step 5: Commit**

```bash
git add notes/designs/agent-provider-interface/02-contract.md
git commit -m "docs(b2): record rollout-tail parse + tailer transport as-built"
```

---

## Self-Review

**Spec coverage** (04-tests "adapter.parse tail (Codex)" row + I13):
- rollout JSONL fixture → StatusReport → Task 2 (`test_rollout_to_statusreport`) + Task 4 e2e. ✓
- rename tolerance (`TaskComplete`→`TurnComplete`, token field) → Task 2 (`renameToleranceTurn`, `renameToleranceTokens`). ✓
- seq-gate holds → Task 2 (`seqFromTimestamp`) + Task 4 (`seqGateHoldsE2E`). ✓
- `test_ctxpct_from_model_table` (tokens ÷ contextWindow) → Task 1 + Task 2 (`tokenCountCtx`, `ctxPctFromModelTable`). ✓
- idle signal → Task 2 (`idleSignal`) + Task 4 (`idleReachesBoard`). ✓
- offline / no network → Task 1 (`offlineLocalResource`), vendored fixture (inline + temp file). ✓
- daemon owns transport / adapter owns parse → Task 3 (tailer, no JSON) + Task 2 (parse, no files); Claude-inert → Task 4 (`claudeNotTailed`). ✓

**Placeholder scan:** none — every step has full code + exact commands.

**Type consistency:** `parse(_ raw: RawTelemetry) -> StatusReport?` matches the frozen protocol; `RolloutTailer.newLines(cardId:path:)` / `forget(_:)` and `pollTelemetry()` are used identically across tasks; `StatusReport(seq:ctxPct:modelId:desc:status:)` uses the flat initializer's real labels; `AgentModel.ctxPct(usedTokens:)` matches Model.swift. ✓
