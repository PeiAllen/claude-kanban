# E1 — Per-Adapter Offline Model Table Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each `Adapter` an offline, vendored-in-repo model table (context-window + capability flags) on `Adapter.models()`, so `ctxPct` for token-reporting agents can be computed as `usedTokens ÷ adapter.model(for:).contextWindow` with no network fetch at build or runtime.

**Architecture:** Extend `AgentModel` with optional `contextWindow: Int?` + a `ModelFlags` capability struct (`toolCall`/`reasoning`/`vision`). Move `ClaudeCodeAdapter`'s hardcoded model list into a vendored JSON resource (`Resources/claude-code-models.json`), loaded once via `Bundle.module` through a small reusable `ModelCatalog.load(_:)` helper. Unknown ids fall back to the existing `AgentModel(id:)` heuristic (no `contextWindow`). Add `AgentModel.ctxPct(usedTokens:)` computing the percentage from the offline denominator.

**Tech Stack:** Swift 6, SwiftPM (`.copy` resource → `Bundle.module`), swift-testing (`@Suite`/`@Test`/`#expect`).

## Global Constraints

- **Offline at build AND runtime** — no models.dev / LiteLLM / any network fetch. The table is a vendored in-repo JSON `.copy`-bundled resource; loaded only via `Bundle.module` (a local `file://` URL). (E1 scope; D7; §6)
- **E1 is a ROOT off `main`** — do NOT introduce `AgentCapabilities` (that is A1's frozen contract) or touch the telemetry transport/parse seam (A2/B2). E1 only extends `Adapter.models()` / `AgentModel`.
- **Additions are defaulted, never mutations** — new `AgentModel` fields are optional (`Int?` / defaulted struct) so existing `tasks.json` (bare-string + object `model` forms) and every `AdapterContext`/`Task` call site keep working. `AdapterTests`, `ReportTests`, `TaskMigrationTests` stay green unchanged.
- **PR-update path** — the model table is edited by editing `Resources/claude-code-models.json` in a PR; no code change needed to add/adjust a model's window.
- Tests never spawn a real vendor agent; `USE_REAL_CLAUDE` stays unset.
- Verify green with `./scripts/test.sh` + `./scripts/typecheck-app.sh` (swift build/test needs an UNSANDBOXED shell — re-run without sandbox on `sandbox-exec: Operation not permitted`).

---

### Task 1: Extend `AgentModel` with `contextWindow` + `ModelFlags` + `ctxPct(usedTokens:)`

**Files:**
- Modify: `Sources/OrchestraCore/Model.swift:46-91` (the `AgentModel` struct)
- Test: `Tests/OrchestraCoreTests/ModelTableTests.swift` (new)

**Interfaces:**
- Produces:
  - `struct ModelFlags: Codable, Sendable, Equatable, Hashable { var toolCall: Bool; var reasoning: Bool; var vision: Bool; init(toolCall: Bool = false, reasoning: Bool = false, vision: Bool = false) }`
  - `AgentModel.contextWindow: Int?` (max context tokens; `nil` = unknown)
  - `AgentModel.flags: ModelFlags?` (capability flags; `nil` = unknown)
  - `AgentModel.init(id:displayName:family:contextWindow:flags:)` — full memberwise init, `contextWindow`/`flags` defaulted `nil`
  - `AgentModel.init(id:)` — unchanged signature, leaves `contextWindow`/`flags` `nil` (the unknown-model fallback)
  - `func AgentModel.ctxPct(usedTokens: Int) -> Double?` — `usedTokens ÷ contextWindow × 100`, clamped `0…100`; `nil` when `contextWindow` is `nil`/≤0

- [ ] **Step 1: Write the failing test**

Create `Tests/OrchestraCoreTests/ModelTableTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Model table — AgentModel context window + ctxPct")
struct ModelTableAgentModelTests {

    @Test("full init carries contextWindow + flags")
    func fullInit() {
        let m = AgentModel(id: "x", displayName: "X", family: "claude",
                           contextWindow: 200_000,
                           flags: ModelFlags(toolCall: true, reasoning: true, vision: false))
        #expect(m.contextWindow == 200_000)
        #expect(m.flags?.toolCall == true)
        #expect(m.flags?.vision == false)
    }

    @Test("heuristic init leaves contextWindow nil (unknown-model fallback)")
    func heuristicInitHasNoWindow() {
        let m = AgentModel(id: "some-unknown-model")
        #expect(m.contextWindow == nil)
        #expect(m.flags == nil)
    }

    @Test("ctxPct divides usedTokens by contextWindow, clamped 0...100")
    func ctxPctMath() {
        let m = AgentModel(id: "x", displayName: "X", family: "claude", contextWindow: 200_000)
        #expect(m.ctxPct(usedTokens: 50_000) == 25.0)
        #expect(m.ctxPct(usedTokens: 0) == 0.0)
        #expect(m.ctxPct(usedTokens: 999_999_999) == 100.0)   // clamped
    }

    @Test("ctxPct is nil when contextWindow unknown (don't divide by a guess)")
    func ctxPctUnknownWindow() {
        #expect(AgentModel(id: "unknown").ctxPct(usedTokens: 1000) == nil)
        #expect(AgentModel(id: "z", displayName: "Z", family: "other", contextWindow: 0)
                    .ctxPct(usedTokens: 1000) == nil)
    }

    @Test("legacy bare-string + object model still decode (defaulted fields absent)")
    func backwardCompatDecode() throws {
        let bare = try OrchestraJSON.decoder.decode(AgentModel.self, from: Data("\"claude-opus-4-8\"".utf8))
        #expect(bare.id == "claude-opus-4-8")
        #expect(bare.contextWindow == nil)
        let obj = try OrchestraJSON.decoder.decode(
            AgentModel.self, from: Data("{\"id\":\"m\",\"displayName\":\"M\",\"family\":\"claude\"}".utf8))
        #expect(obj.contextWindow == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter ModelTableAgentModelTests`
Expected: FAIL to COMPILE — `AgentModel` has no `contextWindow`/`flags`/`ctxPct`, `ModelFlags` undefined.

- [ ] **Step 3: Write minimal implementation**

In `Sources/OrchestraCore/Model.swift`, immediately BEFORE `public struct AgentModel`:

```swift
/// Per-model capability flags from the offline model table (models.dev-shaped). All default false
/// so an absent/partial table entry is safe.
public struct ModelFlags: Codable, Sendable, Equatable, Hashable {
    public var toolCall: Bool
    public var reasoning: Bool
    public var vision: Bool
    public init(toolCall: Bool = false, reasoning: Bool = false, vision: Bool = false) {
        self.toolCall = toolCall; self.reasoning = reasoning; self.vision = vision
    }
}
```

Add the two stored properties to `AgentModel` (after `family`):

```swift
    public var contextWindow: Int?   // max context tokens (offline table); nil = unknown → gauge hidden
    public var flags: ModelFlags?    // capability flags (offline table); nil = unknown
```

Replace the full memberwise init with a defaulted one, and update `init(id:)` to pass nils:

```swift
    public init(id: String, displayName: String, family: String,
                contextWindow: Int? = nil, flags: ModelFlags? = nil) {
        self.id = id; self.displayName = displayName; self.family = family
        self.contextWindow = contextWindow; self.flags = flags
    }

    /// Derive a sensible label + family from a bare id (used for un-cataloged ids + legacy data).
    /// This is the UNKNOWN-MODEL FALLBACK: no contextWindow, no flags.
    public init(id: String) {
        self.init(id: id, displayName: AgentModel.humanize(id), family: AgentModel.detectFamily(id))
    }
```

In `AgentModel.init(from:)`, the object branch: set the new fields via `decodeIfPresent` (add after the `family` line, before the closing brace of the object branch). The bare-string branch already returns early, leaving them `nil`:

```swift
        self.contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow)
        self.flags = try c.decodeIfPresent(ModelFlags.self, forKey: .flags)
```

Add `ctxPct` after `humanize`, inside `AgentModel`:

```swift
    /// Context-window usage percent (0…100) for a token count, using this model's OFFLINE
    /// `contextWindow` as the denominator (the token-reporting agents' ctxPct path — D7/§6).
    /// nil when the window is unknown so the caller hides the gauge rather than dividing by a guess.
    public func ctxPct(usedTokens: Int) -> Double? {
        guard let cw = contextWindow, cw > 0 else { return nil }
        return min(100, max(0, Double(usedTokens) / Double(cw) * 100))
    }
```

> Note: `AgentModel` has a custom `init(from:)` but NO custom `encode(to:)`, so Swift synthesizes
> `encode` from the stored properties. Synthesized encoding of `Int?`/`ModelFlags?` uses
> `encodeIfPresent`, so a `nil` window is omitted from `tasks.json` — no persistence bloat, and
> `CodingKeys` auto-extends to include `contextWindow`/`flags` (the `init(from:)` references to
> `CodingKeys.self` keep resolving).

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter ModelTableAgentModelTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Model.swift Tests/OrchestraCoreTests/ModelTableTests.swift
git commit -m "feat(models): AgentModel gains offline contextWindow + flags + ctxPct(usedTokens:)"
```

---

### Task 2: Vendored JSON table + `ModelCatalog.load(_:)` loader; `ClaudeCodeAdapter.models()` reads it

**Files:**
- Create: `Sources/OrchestraCore/Resources/claude-code-models.json`
- Create: `Sources/OrchestraCore/Agents/ModelCatalog.swift`
- Modify: `Package.swift:32-36` (add the resource to the `.copy` list)
- Modify: `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift:22-31` (`models()` reads the table)
- Test: `Tests/OrchestraCoreTests/ModelTableTests.swift` (append a suite)

**Interfaces:**
- Consumes: `AgentModel(id:displayName:family:contextWindow:flags:)`, `ModelFlags` (Task 1)
- Produces:
  - `enum ModelCatalog { static func load(_ resource: String) -> [AgentModel] }` — decodes `Bundle.module`'s `<resource>.json` (an array of `AgentModel`) once (cached); returns `[]` if the resource is missing/unreadable.
  - `Resources/claude-code-models.json` — the vendored, PR-updated Claude model table.
  - `ClaudeCodeAdapter.models()` now returns the table (context windows populated).

- [ ] **Step 1: Write the failing test**

Append to `Tests/OrchestraCoreTests/ModelTableTests.swift`:

```swift
@Suite("Model table — vendored offline catalog")
struct ModelCatalogTests {
    let adapter = ClaudeCodeAdapter()

    @Test("known model resolves to its offline context window")
    func knownModelHasWindow() {
        let m = adapter.model(for: "claude-opus-4-8")
        #expect(m.contextWindow == 200_000)
        #expect(m.displayName == "Opus 4.8")
    }

    @Test("unknown model id falls back (heuristic, no window)")
    func unknownModelFallsBack() {
        let m = adapter.model(for: "totally-made-up-model")
        #expect(m.id == "totally-made-up-model")
        #expect(m.contextWindow == nil)   // fallback: gauge hidden, never a fabricated denominator
    }

    @Test("models() is non-empty and every entry carries a positive context window")
    func tableIsPopulated() {
        let models = adapter.models()
        #expect(!models.isEmpty)
        #expect(models.allSatisfy { ($0.contextWindow ?? 0) > 0 })
    }

    @Test("table is loaded OFFLINE from a bundled local file (no network fetch)")
    func offlineLocalResource() throws {
        let url = try #require(Bundle.module.url(forResource: "claude-code-models", withExtension: "json"))
        #expect(url.isFileURL)                       // local vendored file, not a remote endpoint
        #expect(FileManager.default.fileExists(atPath: url.path))
        // And ModelCatalog reads exactly that file with no network.
        #expect(!ModelCatalog.load("claude-code-models").isEmpty)
    }

    @Test("test_ctxpct_from_model_table: tokens ÷ table contextWindow = ctxPct in the StatusReport")
    func ctxPctFromModelTable() throws {
        // The token-reporting (Codex-shaped) denominator path E1 provides for B2:
        let model = adapter.model(for: "claude-opus-4-8")        // offline table → 200_000
        let usedTokens = 40_000
        let pct = try #require(model.ctxPct(usedTokens: usedTokens))
        #expect(pct == 20.0)                                     // 40_000 / 200_000 * 100
        // …lands as the StatusReport.snapshot.ctxPct a tail adapter would emit:
        let report = StatusReport(ctxPct: pct, modelId: model.id)
        #expect(report.snapshot?.ctxPct == 20.0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter ModelCatalogTests`
Expected: FAIL — `ModelCatalog` undefined; `model(for: "claude-opus-4-8").contextWindow` is `nil` (models() still hardcoded without windows); resource not bundled.

- [ ] **Step 3a: Create the vendored JSON table**

Create `Sources/OrchestraCore/Resources/claude-code-models.json` (context windows are the published Claude Code figures; PR-update this file to change them):

```json
[
  { "id": "claude-opus-4-8",   "displayName": "Opus 4.8",   "family": "claude", "contextWindow": 200000,
    "flags": { "toolCall": true, "reasoning": true, "vision": true } },
  { "id": "claude-sonnet-4-6", "displayName": "Sonnet 4.6", "family": "claude", "contextWindow": 200000,
    "flags": { "toolCall": true, "reasoning": true, "vision": true } },
  { "id": "claude-haiku-4-5",  "displayName": "Haiku 4.5",  "family": "claude", "contextWindow": 200000,
    "flags": { "toolCall": true, "reasoning": true, "vision": true } },
  { "id": "claude-opus-4-7",   "displayName": "Opus 4.7",   "family": "claude", "contextWindow": 200000,
    "flags": { "toolCall": true, "reasoning": true, "vision": true } }
]
```

- [ ] **Step 3b: Register the resource in `Package.swift`**

In the `OrchestraCore` target's `resources:` array (after `claude-hooks.json`):

```swift
                .copy("Resources/claude-code-models.json"),
```

- [ ] **Step 3c: Create `ModelCatalog`**

Create `Sources/OrchestraCore/Agents/ModelCatalog.swift`:

```swift
import Foundation

/// Loads a per-adapter OFFLINE model table from a vendored, PR-updated JSON resource
/// (`Resources/<name>.json`, `.copy`-bundled). No network fetch — build or runtime (D7 / §6).
/// The table is the source of truth for each model's context window + capability flags; edit the
/// JSON in a PR to add or adjust a model. Decoded once per resource name and cached.
enum ModelCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [AgentModel]] = [:]

    /// Decode `Bundle.module`'s `<resource>.json` as `[AgentModel]`. Returns `[]` if the resource is
    /// absent or unreadable (callers keep their own fallback), never throws into launch paths.
    static func load(_ resource: String) -> [AgentModel] {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[resource] { return hit }
        let models = decode(resource)
        cache[resource] = models
        return models
    }

    private static func decode(_ resource: String) -> [AgentModel] {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let models = try? JSONDecoder().decode([AgentModel].self, from: data)
        else { return [] }
        return models
    }
}
```

- [ ] **Step 3d: `ClaudeCodeAdapter.models()` reads the table**

Replace the hardcoded `models()` body in `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift`:

```swift
    /// Claude Code's selectable models + their OFFLINE context windows / capability flags, from the
    /// vendored `Resources/claude-code-models.json` (PR-updated, no network). The hardcoded list is a
    /// last-resort fallback so `models()` is never empty if the resource fails to bundle.
    public func models() -> [AgentModel] {
        let table = ModelCatalog.load("claude-code-models")
        return table.isEmpty ? Self.fallbackModels : table
    }

    private static let fallbackModels: [AgentModel] = [
        AgentModel(id: "claude-opus-4-8", displayName: "Opus 4.8", family: "claude"),
        AgentModel(id: "claude-sonnet-4-6", displayName: "Sonnet 4.6", family: "claude"),
        AgentModel(id: "claude-haiku-4-5", displayName: "Haiku 4.5", family: "claude"),
        AgentModel(id: "claude-opus-4-7", displayName: "Opus 4.7", family: "claude"),
    ]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter ModelCatalogTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the FULL suite (behavior-preservation gate) + typecheck**

Run: `./scripts/test.sh` then `./scripts/typecheck-app.sh`
Expected: all green — `AdapterTests` (`models() non-empty`), `ReportTests`, `TaskMigrationTests` unchanged.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/OrchestraCore/Resources/claude-code-models.json \
        Sources/OrchestraCore/Agents/ModelCatalog.swift \
        Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift \
        Tests/OrchestraCoreTests/ModelTableTests.swift
git commit -m "feat(models): vendored offline Claude model table via ModelCatalog + Bundle.module"
```

---

## Self-Review

- **Spec coverage:** offline no-fetch → Task 2 (`.copy` bundle, `offlineLocalResource` test, no URLSession anywhere); PR-update path → `claude-code-models.json` is the SSOT (`models()` reads it); unknown-model fallback → `AgentModel(id:)` heuristic + `unknownModelFallsBack` test. Required unit tests: known→window (`knownModelHasWindow`), unknown→fallback (`unknownModelFallsBack`), offline build+runtime (`offlineLocalResource` + `.copy` resource), `test_ctxpct_from_model_table` (`ctxPctFromModelTable`). ✓
- **Placeholder scan:** none — all code + JSON + commands are literal. ✓
- **Type consistency:** `contextWindow: Int?`, `flags: ModelFlags?`, `ctxPct(usedTokens:) -> Double?`, `ModelCatalog.load(_:) -> [AgentModel]` used identically across tasks. ✓
- **Scope discipline:** no `AgentCapabilities`, no telemetry/parse changes — E1 stays a clean root off `main`. ✓
