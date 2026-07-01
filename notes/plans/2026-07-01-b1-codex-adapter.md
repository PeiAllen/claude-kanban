# B1 · Codex Adapter (launch) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `CodexAdapter` that mirrors `ClaudeCodeAdapter` — Codex launch/resume argv, discovered rollout session-id, pinned `CODEX_HOME`, `trust_level` mirrored **from `ctx.trustCwd`**, and read-only-first (`-s read-only -a never`) — and register it as `agentId = "codex"`.

**Architecture:** Codex is the second adapter behind the frozen A1 seam. It is a `.discovered`-session, `.fileTail`-telemetry agent (vs Claude's `.seeded`/`.hooksPush`). Launch is always read-only in this first cut (approvals + write are deferred). Trust is resolved by **core** (`resolveTrust → ctx.trustCwd`) and only *applied* by the adapter into Codex's native `[projects."<cwd>"].trust_level = "trusted"` inside `prepareToLaunch` — the adapter never reads `TrustLedger`. `CODEX_HOME` is pinned via the (previously-unused) `Adapter.env` property, which this PR wires into the tmux launch so per-agent env actually reaches the process.

**Tech Stack:** Swift 6, swift-testing (`@Suite`/`@Test`) + XCTest, SwiftPM. Tests use `StubSessions` (records argv **+ env**); no real `codex`/`claude` binary ever spawns (`USE_REAL_CLAUDE` unset).

## Global Constraints

- **Adapter NEVER reads `TrustLedger`.** Core resolves trust into `ctx.trustCwd`; the adapter only mirrors that flag. (design §4.1 / I10)
- **Read-only-first.** B1 ships read-only only — EVERY Codex launch clamps to `-s read-only -a never` regardless of `ctx.access`. Approvals/write land in a later PR.
- **Claude stays byte-identical.** Claude's `env` is empty, so the env-wiring change adds zero `-e` entries to Claude's tmux command. `ReportTests`/`AdapterTests`/`RecoveryTests` stay green unchanged.
- **No real binaries in tests.** `StubSessions` records argv/env; `binOverride`/`codexHome` inject fakes.
- **Do NOT build** the rollout tailer/parse (B2) or send-keys wake (C4). `parse` is left defaulted (nil).
- **Registered id is `"codex"`** (Claude's is `"claude-code"`).

---

## File Structure

- `Sources/OrchestraCore/Agents/CodexAdapter.swift` — **new.** `CodexAdapter` + `extension AgentCapabilities { static let codex }` + `enum CodexTrust`. Mirrors `ClaudeCodeAdapter.swift`.
- `Sources/OrchestraCore/Agents/Adapter.swift` — **modify** the default `AgentRegistry` adapter list to include `CodexAdapter()`.
- `Sources/OrchestraCore/Protocols.swift` — **modify** `SessionManaging.ensure` to take `env:`; add a 2-arg convenience default so existing callers are untouched.
- `Sources/OrchestraCore/SessionManager.swift` — **modify** `ensure` to accept `env` and emit `-e KEY=VALUE` per entry.
- `Sources/OrchestraCore/OrchestraService.swift` — **modify** the spawn launch to pass `env: adapter.env`.
- `Sources/OrchestraCore/OrchestraService+Recovery.swift` — **modify** the resume + restart launches to pass `env: adapter.env`.
- `Tests/OrchestraCoreTests/Stubs.swift` — **modify** `StubSessions` to implement the 3-arg `ensure` and record `ensureEnv`.
- `Tests/OrchestraCoreTests/CodexAdapterTests.swift` — **new.** All B1 unit tests.

---

## Task 1: `CodexAdapter` argv + capabilities + registry

**Files:**
- Create: `Sources/OrchestraCore/Agents/CodexAdapter.swift`
- Modify: `Sources/OrchestraCore/Agents/Adapter.swift:71`
- Test: `Tests/OrchestraCoreTests/CodexAdapterTests.swift`

**Interfaces:**
- Consumes: `Adapter`, `AdapterContext`, `AgentCapabilities`, `AgentModel`, `AgentSessionInfo`, `Config`, `ModelCatalog`.
- Produces:
  - `CodexAdapter(binOverride: String? = nil, codexHome: String? = nil)` with `id == "codex"`, `bin == "codex"`.
  - `start(ctx) -> [String]` = `[bin, "-s", "read-only", "-a", "never", ("-m", model)?, prompt?]`.
  - `resume(ctx) -> [String]?` = `[bin, "resume", sid, "-s", "read-only", "-a", "never", ("-m", model)?]`; nil when `ctx.sessionId == nil`.
  - `var env: [String: String]` = `["CODEX_HOME": codexHome]`.
  - `AgentCapabilities.codex` = `(.discovered, .fileTail, .tokens, .sendKeys, .sessionSeed, .sandboxed, .subscription)`.

- [ ] **Step 1: Write the failing tests** (`CodexAdapterTests.swift`)

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("CodexAdapter — argv, capabilities, registry")
struct CodexAdapterArgvTests {
    let adapter = CodexAdapter()

    // True iff `flag` is immediately followed by `value` in argv.
    private func adjacent(_ argv: [String], _ flag: String, _ value: String) -> Bool {
        guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return false }
        return argv[i + 1] == value
    }

    @Test("registry resolves agentId=codex")
    func registryResolvesCodex() throws {
        let reg = AgentRegistry()
        #expect(try reg.get("codex").id == "codex")
        #expect(reg.list().contains { $0.id == "codex" })
        #expect(try reg.get("claude-code").id == "claude-code")   // both registered
    }

    @Test("capabilities are Codex's discovered/fileTail/sendKeys tuple")
    func capabilities() {
        let c = CodexAdapter().capabilities
        #expect(c == .codex)
        #expect(c.sessionId == .discovered)
        #expect(c.telemetry == .fileTail)
        #expect(c.contextUsage == .tokens)
        #expect(c.wakeTransport == .sendKeys)
        #expect(c.inboxDrain == .sessionSeed)
        #expect(c.readOnlyEnforcement == .sandboxed)
        #expect(c.authMode == .subscription)
    }

    @Test("discovered agents do not mint a session id")
    func newSessionIdIsNil() {
        #expect(CodexAdapter().newSessionId() == nil)
    }

    @Test("models() is non-empty (fallback when no vendored table)")
    func models() { #expect(!adapter.models().isEmpty) }

    @Test("start(ctx) is read-only-first with adjacent flags, model, and trailing prompt")
    func startArgv() {
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-5-codex",
                                 prompt: "Add OAuth login\nwith Google")
        let argv = adapter.start(ctx)
        #expect(argv.first == "codex")
        #expect(adjacent(argv, "-s", "read-only"))
        #expect(adjacent(argv, "-a", "never"))
        #expect(adjacent(argv, "-m", "gpt-5-codex"))
        #expect(argv.last == "Add OAuth login\nwith Google")   // launch positional prompt
    }

    @Test("start clamps to read-only even when ctx.access is readWrite (read-only-first)")
    func startReadOnlyFirst() {
        let ctx = AdapterContext(cwd: "/wt", access: .readWrite)
        let argv = adapter.start(ctx)
        #expect(adjacent(argv, "-s", "read-only"))
        #expect(adjacent(argv, "-a", "never"))
    }

    @Test("start with no prompt has no trailing positional")
    func startNoPrompt() {
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-5-codex", prompt: nil)
        let argv = adapter.start(ctx)
        #expect(argv.last == "gpt-5-codex")   // last token is the -m value, no prompt
    }

    @Test("resume(ctx) is `resume <id>` read-only-first, NO prompt")
    func resumeArgv() throws {
        let ctx = AdapterContext(cwd: "/wt", model: "gpt-5", sessionId: "sess-9",
                                 prompt: "should be ignored")
        let argv = try #require(adapter.resume(ctx))
        #expect(adjacent(argv, "resume", "sess-9"))
        #expect(adjacent(argv, "-s", "read-only"))
        #expect(adjacent(argv, "-a", "never"))
        #expect(adjacent(argv, "-m", "gpt-5"))
        #expect(!argv.contains("should be ignored"))
    }

    @Test("resume returns nil without a session id")
    func resumeNilNoId() {
        #expect(adapter.resume(AdapterContext(cwd: "/wt", sessionId: nil)) == nil)
    }

    @Test("env pins CODEX_HOME")
    func envPinsCodexHome() {
        let a = CodexAdapter(codexHome: "/tmp/ch")
        #expect(a.env["CODEX_HOME"] == "/tmp/ch")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter CodexAdapterArgvTests`
Expected: FAIL — `CodexAdapter` undefined / `AgentCapabilities.codex` undefined.

- [ ] **Step 3: Write `CodexAdapter.swift`**

```swift
import Foundation

/// The built-in Codex adapter. Mirrors `ClaudeCodeAdapter` for the second agent: it builds read-only
/// launch/resume argv (`-s read-only -a never`), pins `CODEX_HOME` (via `env`), discovers the session
/// id from the rollout dir post-launch (Codex is `.discovered`, not seeded), and mirrors the CORE's
/// trust decision (`ctx.trustCwd`) into Codex's native per-project `trust_level` — never reading the
/// `TrustLedger`. B1 ships READ-ONLY ONLY (approvals/write deferred), so every launch clamps read-only.
public struct CodexAdapter: Adapter {
    public let id = "codex"
    public let name = "Codex"
    public let icon = "chevron.left.forwardslash.chevron.right"
    public let bin = "codex"
    public let enabled = true

    /// Codex's capability tuple (B1 as-built). Differs from Claude on every launch-relevant axis:
    /// discovered session id, rollout file-tail telemetry, token-based ctx, send-keys wake.
    public var capabilities: AgentCapabilities { .codex }

    /// Test injection (fake binary / isolated home) — never spawns real Codex.
    let binOverride: String?
    let codexHomeOverride: String?

    public init(binOverride: String? = nil, codexHome: String? = nil) {
        self.binOverride = binOverride
        self.codexHomeOverride = codexHome
    }

    private var binary: String { binOverride ?? bin }

    /// Orchestra pins CODEX_HOME so Codex's config + session rollouts live in a known location the
    /// daemon controls (config trust write here; rollout tail in B2). Defaults to `$HOME/.codex`; an
    /// isolated daemon already redirects `$HOME`, so this is isolated along with it.
    var codexHome: String { codexHomeOverride ?? "\(Config.home)/.codex" }

    /// The pinned CODEX_HOME is delivered to the process as an environment variable (wired into the
    /// tmux launch via `SessionManaging.ensure(env:)`). Claude leaves this empty (default).
    public var env: [String: String] { ["CODEX_HOME": codexHome] }

    /// Codex's selectable models. B2/E1 vendor `Resources/codex-models.json` (offline table); until
    /// then this hardcoded list keeps `models()` non-empty so model resolution never fails.
    public func models() -> [AgentModel] {
        let table = ModelCatalog.load("codex-models")
        return table.isEmpty ? Self.fallbackModels : table
    }

    private static let fallbackModels: [AgentModel] = [
        AgentModel(id: "gpt-5-codex", displayName: "GPT-5 Codex", family: "gpt"),
        AgentModel(id: "gpt-5", displayName: "GPT-5", family: "gpt"),
        AgentModel(id: "o3", displayName: "o3", family: "gpt"),
    ]

    /// Codex's session id is `.discovered` (read back from the rollout dir after launch), so Orchestra
    /// mints nothing pre-launch — unlike Claude's `.seeded` `--session-id`.
    public func newSessionId() -> String? { nil }

    // Read-only-first: B1 ships read-only ONLY (approvals deferred), so EVERY launch clamps to these
    // flags regardless of `ctx.access`. `-s read-only` selects Codex's OS-sandboxed read-only mode;
    // `-a never` disables the approval round-trip (which B1 does not implement).
    private var readOnlyFlags: [String] { ["-s", "read-only", "-a", "never"] }

    private func modelFlag(_ model: String?) -> [String] {
        guard let m = model, !m.isEmpty else { return [] }
        return ["-m", m]
    }

    public func start(_ ctx: AdapterContext) -> [String] {
        var argv = [binary]
        argv += readOnlyFlags
        argv += modelFlag(ctx.model)
        if let p = ctx.prompt, !p.isEmpty { argv.append(p) }   // launch positional prompt
        return argv
    }

    public func resume(_ ctx: AdapterContext) -> [String]? {
        guard let sid = ctx.sessionId else { return nil }
        var argv = [binary, "resume", sid]
        argv += readOnlyFlags
        argv += modelFlag(ctx.model)
        return argv   // no prompt — the rollout holds the task
    }

    /// Prep runs isolation FIRST (ensure the pinned CODEX_HOME exists), THEN mirrors the core's trust
    /// decision into it. The adapter applies `ctx.trustCwd` only — it never reads the `TrustLedger`.
    public func prepareToLaunch(_ ctx: AdapterContext) throws {
        try? FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        CodexTrust.apply(trusted: ctx.trustCwd, cwd: ctx.cwd, codexHome: codexHome)
    }

    public func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
        let sid = current ?? discover()
        guard let sid else {
            return AgentSessionInfo(agentId: id, sessionId: nil, transcriptPath: nil,
                                    priorSessionIds: prior, priorTranscripts: [], resumeCmd: nil)
        }
        let resumeCtx = AdapterContext(cwd: ctx.cwd, model: ctx.model, sessionId: sid,
                                       name: ctx.name, access: ctx.access)
        return AgentSessionInfo(
            agentId: id,
            sessionId: sid,
            transcriptPath: rolloutPath(for: sid),
            priorSessionIds: prior,
            priorTranscripts: [],
            resumeCmd: resume(resumeCtx))
    }

    // MARK: rollout discovery — $CODEX_HOME/sessions/**/rollout-<timestamp>-<uuid>.jsonl

    var sessionsDir: String { "\(codexHome)/sessions" }

    /// Newest rollout's embedded session UUID, or nil. The `.discovered` fallback when Orchestra has no
    /// tracked id yet. NOTE: like Claude's `discover`, "newest" is ambiguous if multiple Codex cards
    /// share one CODEX_HOME — safe only as the `current == nil` fallback (tracked cards pass `current`).
    func discover() -> String? {
        let newest = rolloutFiles().max { mtime($0) < mtime($1) }
        guard let newest else { return nil }
        return sessionId(fromRollout: newest)
    }

    func rolloutPath(for sessionId: String) -> String? {
        rolloutFiles().first { self.sessionId(fromRollout: $0) == sessionId }
    }

    private func rolloutFiles() -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: sessionsDir) else { return [] }
        var out: [String] = []
        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            if (rel as NSString).lastPathComponent.hasPrefix("rollout-") {
                out.append("\(sessionsDir)/\(rel)")
            }
        }
        return out
    }

    /// Extract the trailing UUID from `rollout-<timestamp>-<uuid>.jsonl`. Returns nil if the tail is
    /// not a valid UUID (never a fabricated id).
    func sessionId(fromRollout path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(".jsonl".count))
        let candidate = String(stem.suffix(36))
        return UUID(uuidString: candidate) != nil ? candidate.lowercased() : nil
    }

    private func mtime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
    }
}

public extension AgentCapabilities {
    /// Codex's shipped capabilities (B1 as-built). Discovered session id (rollout), file-tail telemetry
    /// (rollout JSONL, parsed in B2), token-based context usage, send-keys wake (C4), seed-folded inbox
    /// drain (no Stop hook), an OS-sandboxed read-only guarantee, and subscription auth.
    static let codex = AgentCapabilities(
        sessionId: .discovered,
        telemetry: .fileTail,
        contextUsage: .tokens,
        wakeTransport: .sendKeys,
        inboxDrain: .sessionSeed,
        readOnlyEnforcement: .sandboxed,
        authMode: .subscription)
}

/// Manages Codex's per-project trust in `$CODEX_HOME/config.toml` (`[projects."<path>"].trust_level`).
/// The adapter only ever *applies* the core's already-resolved decision (`ctx.trustCwd`) — it never
/// reads the Orchestra `TrustLedger` (core owns resolution; see `OrchestraService.resolveTrust`). The
/// Codex analogue of `ClaudeTrust`.
enum CodexTrust {
    /// Apply the core's trust decision to Codex's native per-project trust. Writes `trust_level` for
    /// `cwd` iff `trusted`; otherwise a no-op (Codex will prompt / the card clamps).
    static func apply(trusted: Bool, cwd: String, codexHome: String) {
        guard trusted else { return }
        record(cwd, codexHome: codexHome)
    }

    /// Mark `cwd` trusted by appending a `[projects."<cwd>"]` table with `trust_level = "trusted"`.
    /// Idempotent + non-clobbering: if the section header already exists we leave the file untouched
    /// (mirrors `ClaudeTrust.grant` bailing when already trusted / unparseable), so we never corrupt a
    /// user's existing config.toml.
    static func record(_ cwd: String, codexHome: String) {
        let path = "\(codexHome)/config.toml"
        let header = "[projects.\"\(tomlEscape(cwd))\"]"
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if text.contains(header) { return }                       // already managed → no clobber
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\n\(header)\ntrust_level = \"trusted\"\n"
        try? FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func tomlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

- [ ] **Step 4: Register in the default registry** — `Sources/OrchestraCore/Agents/Adapter.swift:71`

Change:
```swift
    public init(adapters: [any Adapter] = [ClaudeCodeAdapter()]) {
```
to:
```swift
    public init(adapters: [any Adapter] = [ClaudeCodeAdapter(), CodexAdapter()]) {
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter CodexAdapterArgvTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Agents/CodexAdapter.swift Sources/OrchestraCore/Agents/Adapter.swift Tests/OrchestraCoreTests/CodexAdapterTests.swift
git commit -m "feat(codex): CodexAdapter argv + capabilities + registry (B1)"
```

---

## Task 2: Rollout session-id discovery

**Files:**
- Modify: `Sources/OrchestraCore/Agents/CodexAdapter.swift` (already has `discover`/`sessionInfo` from Task 1)
- Test: `Tests/OrchestraCoreTests/CodexAdapterTests.swift`

**Interfaces:**
- Consumes: `CodexAdapter.sessionInfo(ctx, current:, prior:)`, `discover()`, `sessionId(fromRollout:)`.
- Produces: session id resolution — `current` wins; else newest `rollout-*-<uuid>.jsonl` under `$CODEX_HOME/sessions`.

- [ ] **Step 1: Write the failing tests** (append to `CodexAdapterTests.swift`)

```swift
@Suite("CodexAdapter — rollout session-id discovery")
struct CodexAdapterDiscoveryTests {
    /// Make an isolated CODEX_HOME with a rollout file, returning (home, adapter).
    private func makeHome() -> (home: String, adapter: CodexAdapter) {
        let home = NSTemporaryDirectory() + "codexhome-\(UUID().uuidString)"
        return (home, CodexAdapter(codexHome: home))
    }
    private func writeRollout(_ home: String, day: String, sessionId: String, mtime: Date? = nil) {
        let dir = "\(home)/sessions/\(day)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/rollout-2026-07-01T10-00-00-\(sessionId).jsonl"
        try? "{}".write(toFile: path, atomically: true, encoding: .utf8)
        if let m = mtime {
            try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: path)
        }
    }

    @Test("sessionInfo discovers the session id from the newest rollout file")
    func discoversFromRollout() throws {
        let (home, adapter) = makeHome()
        let sid = UUID().uuidString.lowercased()
        writeRollout(home, day: "2026/07/01", sessionId: sid)
        let info = try #require(adapter.sessionInfo(AdapterContext(cwd: "/wt"), current: nil, prior: []))
        #expect(info.sessionId == sid)
        #expect(info.transcriptPath?.hasSuffix("-\(sid).jsonl") == true)
        #expect(info.resumeCmd?.contains("resume") == true)
        #expect(info.resumeCmd?.contains(sid) == true)
    }

    @Test("discovery picks the NEWEST rollout by mtime")
    func discoversNewest() throws {
        let (home, adapter) = makeHome()
        let older = UUID().uuidString.lowercased()
        let newer = UUID().uuidString.lowercased()
        writeRollout(home, day: "2026/06/30", sessionId: older, mtime: Date(timeIntervalSince1970: 1000))
        writeRollout(home, day: "2026/07/01", sessionId: newer, mtime: Date(timeIntervalSince1970: 2000))
        #expect(adapter.discover() == newer)
    }

    @Test("current id wins over discovery")
    func currentWins() throws {
        let (home, adapter) = makeHome()
        writeRollout(home, day: "2026/07/01", sessionId: UUID().uuidString.lowercased())
        let info = try #require(adapter.sessionInfo(AdapterContext(cwd: "/wt"), current: "explicit-id", prior: ["old"]))
        #expect(info.sessionId == "explicit-id")
        #expect(info.priorSessionIds == ["old"])
    }

    @Test("no rollouts → nil session id, nil resume")
    func noRollouts() {
        let (_, adapter) = makeHome()   // empty home
        let info = adapter.sessionInfo(AdapterContext(cwd: "/wt"), current: nil, prior: [])
        #expect(info?.sessionId == nil)
        #expect(info?.resumeCmd == nil)
    }

    @Test("a non-UUID rollout tail is rejected (never a fabricated id)")
    func rejectsNonUuidTail() {
        let (home, adapter) = makeHome()
        let dir = "\(home)/sessions/2026/07/01"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "{}".write(toFile: "\(dir)/rollout-2026-07-01T10-00-00-not-a-uuid.jsonl",
                        atomically: true, encoding: .utf8)
        #expect(adapter.discover() == nil)
    }
}
```

- [ ] **Step 2: Run to verify** — most pass from Task 1's implementation; confirm.

Run: `./scripts/test.sh --filter CodexAdapterDiscoveryTests`
Expected: PASS (discovery code shipped in Task 1). If any fail, fix `discover`/`sessionId(fromRollout:)`.

- [ ] **Step 3: Commit**

```bash
git add Tests/OrchestraCoreTests/CodexAdapterTests.swift
git commit -m "test(codex): rollout session-id discovery (B1)"
```

---

## Task 3: `trust_level` mirrors `ctx.trustCwd` (and never reads `TrustLedger`) + isolation ordering

**Files:**
- Modify: `Sources/OrchestraCore/Agents/CodexAdapter.swift` (`prepareToLaunch`/`CodexTrust` from Task 1)
- Test: `Tests/OrchestraCoreTests/CodexAdapterTests.swift`

**Interfaces:**
- Consumes: `CodexAdapter.prepareToLaunch(ctx)`, `CodexTrust.apply/record`.
- Produces: `$CODEX_HOME/config.toml` gains `[projects."<cwd>"]` + `trust_level = "trusted"` iff `ctx.trustCwd`.

- [ ] **Step 1: Write the failing tests** (append to `CodexAdapterTests.swift`)

```swift
@Suite("CodexAdapter — trust mirror + isolation")
struct CodexAdapterTrustTests {
    private func makeHome() -> (home: String, adapter: CodexAdapter) {
        let home = NSTemporaryDirectory() + "codexhome-\(UUID().uuidString)"
        return (home, CodexAdapter(codexHome: home))
    }
    private func configText(_ home: String) -> String {
        (try? String(contentsOfFile: "\(home)/config.toml", encoding: .utf8)) ?? ""
    }

    @Test("test_adapter_applies_ctx_trust: trustCwd=true writes trust_level from ctx, into the isolated home")
    func appliesCtxTrust() throws {
        let (home, adapter) = makeHome()
        let ctx = AdapterContext(cwd: "/Users/x/wt/app/feat", trustCwd: true)
        try adapter.prepareToLaunch(ctx)
        // Isolation: the pinned CODEX_HOME was created (ordering: home exists before trust write).
        #expect(FileManager.default.fileExists(atPath: home))
        let toml = configText(home)
        #expect(toml.contains("[projects.\"/Users/x/wt/app/feat\"]"))
        #expect(toml.contains("trust_level = \"trusted\""))
    }

    @Test("trustCwd=false does NOT write trust (mirrors, never grants what core didn't)")
    func untrustedNoWrite() throws {
        let (home, adapter) = makeHome()
        try adapter.prepareToLaunch(AdapterContext(cwd: "/wt", trustCwd: false))
        #expect(!configText(home).contains("trust_level"))
    }

    @Test("mirror is idempotent + non-clobbering: existing config content survives")
    func idempotentNonClobbering() throws {
        let (home, adapter) = makeHome()
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try "model = \"gpt-5\"\n".write(toFile: "\(home)/config.toml", atomically: true, encoding: .utf8)
        let ctx = AdapterContext(cwd: "/wt", trustCwd: true)
        try adapter.prepareToLaunch(ctx)
        try adapter.prepareToLaunch(ctx)   // second apply must not duplicate the section
        let toml = configText(home)
        #expect(toml.contains("model = \"gpt-5\""))                  // user content preserved
        #expect(toml.components(separatedBy: "[projects.\"/wt\"]").count == 2)  // exactly one section
    }
}
```

- [ ] **Step 2: Run to verify** — passes from Task 1's `prepareToLaunch`/`CodexTrust`.

Run: `./scripts/test.sh --filter CodexAdapterTrustTests`
Expected: PASS. (Structural "never reads TrustLedger" is guaranteed by construction — `CodexAdapter` holds no `TrustLedger` reference and `prepareToLaunch`'s only trust input is `ctx.trustCwd`.)

- [ ] **Step 3: Commit**

```bash
git add Tests/OrchestraCoreTests/CodexAdapterTests.swift
git commit -m "test(codex): trust_level mirrors ctx.trustCwd + isolation ordering (B1)"
```

---

## Task 4: Wire `Adapter.env` (CODEX_HOME) into the tmux launch

**Files:**
- Modify: `Sources/OrchestraCore/Protocols.swift:12-30`
- Modify: `Sources/OrchestraCore/SessionManager.swift:51-65`
- Modify: `Sources/OrchestraCore/OrchestraService.swift:159`
- Modify: `Sources/OrchestraCore/OrchestraService+Recovery.swift:78,127`
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` (`StubSessions`)
- Test: `Tests/OrchestraCoreTests/CodexAdapterTests.swift`

**Interfaces:**
- Consumes: `Adapter.env`.
- Produces:
  - `SessionManaging.ensure(_ task:, argv:, env:) -> (name, created)` (new requirement) + a 2-arg convenience default forwarding `env: [:]`.
  - `StubSessions.ensureEnv[name] -> [String: String]`.
  - Spawn/resume/restart launches pass `env: adapter.env`; each env entry becomes a tmux `-e KEY=VALUE`.

- [ ] **Step 1: Write the failing test** (append to `CodexAdapterTests.swift`)

```swift
@Suite("CodexAdapter — spawn wires CODEX_HOME + read-only argv")
struct CodexSpawnWiringTests {
    @Test("spawn(agentId: codex) resolves the adapter, passes CODEX_HOME env + read-only argv to the session")
    func spawnWiresHomeAndArgv() async throws {
        let base = NSTemporaryDirectory() + "codex-spawn-\(UUID().uuidString)"
        let work = base + "/work"
        let codexHome = base + "/codexhome"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)])
        let sessions = StubSessions()
        let codex = CodexAdapter(binOverride: "fake-codex", codexHome: codexHome)
        let svc = OrchestraService(config: config,
                                   store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [codex]),
                                   worktrees: StubWorktrees(root: config.worktreesRoot),
                                   sessions: sessions,
                                   trust: TrustLedger(path: base + "/trust.json"))
        let t = try await svc.spawn(SpawnInput(prompt: "look around", agentId: "codex",
                                               cwd: PathResolver.canonical(work)))
        #expect(t.agentId == "codex")
        let name = sessions.sessionName(t.id)
        let argv = try #require(sessions.ensureArgv[name])
        #expect(argv.first == "fake-codex")
        #expect(argv.contains("read-only"))
        #expect(argv.contains("never"))
        // env wiring: the pinned CODEX_HOME reaches the launch.
        #expect(sessions.ensureEnv[name]?["CODEX_HOME"] == codexHome)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter CodexSpawnWiringTests`
Expected: FAIL — `StubSessions.ensureEnv` undefined (and env not threaded).

- [ ] **Step 3: Add the `env` seam to `SessionManaging`** — `Protocols.swift`

Replace the `ensure` requirement + extension:
```swift
public protocol SessionManaging: Sendable {
    func sessionName(_ id: UUID) -> String
    @discardableResult
    func ensure(_ task: Task, argv: [String], env: [String: String]) throws -> (name: String, created: Bool)
    func isAlive(_ name: String) throws -> Bool
    @discardableResult
    func newShellWindow(_ name: String, cwd: String) throws -> String
    func closeShellWindow(_ name: String, window: String) throws
    func windows(_ name: String) throws -> [TmuxTarget]
    func list() throws -> [SessionInfo]
    func capture(_ name: String, window: String) throws -> String
    func sendKeys(_ name: String, text: String, window: String) throws
    func kill(_ name: String) throws
}

public extension SessionManaging {
    // Default so test stubs needn't implement it; the real `SessionManager` overrides.
    func closeShellWindow(_ name: String, window: String) throws {}
    /// Convenience: launch with no extra environment (keep-alive shells, existing callers/tests).
    @discardableResult
    func ensure(_ task: Task, argv: [String]) throws -> (name: String, created: Bool) {
        try ensure(task, argv: argv, env: [:])
    }
}
```

- [ ] **Step 4: Emit `-e` per env entry** — `SessionManager.swift` `ensure`

```swift
    @discardableResult
    public func ensure(_ task: Task, argv: [String], env: [String: String] = [:]) throws -> (name: String, created: Bool) {
        let name = sessionName(task.id)
        if try isAlive(name) { return (name, false) }

        var args = ["new-session", "-d", "-s", name, "-n", "agent", "-c", task.cwd,
                    "-e", "ORCHESTRA_TASK_ID=\(task.id.uuidString.lowercased())",
                    "-e", "ORCHESTRA_SOCK=\(sockEnvPath)"]
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { args += ["-e", "\(k)=\(v)"] }
        args.append("--")
        args += argv
        let r = try tmux(args)
        if !r.ok {
            throw OrchestraError.io(r.stderr.isEmpty ? "tmux new-session failed" : r.stderr)
        }
        return (name, true)
    }
```

- [ ] **Step 5: Record env in `StubSessions`** — `Stubs.swift`

Add a property + update `ensure`:
```swift
    private(set) var ensureEnv: [String: [String: String]] = [:]
```
```swift
    func ensure(_ task: Task, argv: [String], env: [String: String] = [:]) throws -> (name: String, created: Bool) {
        let name = sessionName(task.id)
        lock.lock(); curConcurrentEnsure += 1; peakConcurrentEnsure = max(peakConcurrentEnsure, curConcurrentEnsure); ensureCount += 1; lock.unlock()
        if ensureSleepMs > 0 { usleep(ensureSleepMs * 1000) }
        lock.lock(); curConcurrentEnsure -= 1; alive.insert(name); ensureArgv[name] = argv; ensureEnv[name] = env; lock.unlock()
        return (name, true)
    }
```

- [ ] **Step 6: Pass `adapter.env` at the agent-launch call sites**

`OrchestraService.swift:159`:
```swift
        try sessions.ensure(created, argv: adapter.start(ctx), env: adapter.env)
```

`OrchestraService+Recovery.swift` — resume (~line 74-79):
```swift
        try? adapter.prepareToLaunch(ctx)
        let env = adapter.env
        do {
            try await offActor { [sessions] in
                _ = try sessions.kill(sessions.sessionName(id))
                _ = try sessions.ensure(task, argv: argv, env: env)
            }
        } catch {
```

`OrchestraService+Recovery.swift` — restart (~line 124-128):
```swift
        try? adapter.prepareToLaunch(ctx)
        let env = adapter.env
        try await offActor { [sessions] in
            _ = try sessions.kill(sessions.sessionName(id))
            _ = try sessions.ensure(launchTask, argv: adapter.start(ctx), env: env)
        }
```

(The two keep-alive `sessions.ensure(t, argv: ["/bin/sh"])` calls at `OrchestraService.swift:277,298` stay on the 2-arg convenience — no env.)

- [ ] **Step 7: Run to verify it passes**

Run: `./scripts/test.sh --filter CodexSpawnWiringTests`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/OrchestraCore/Protocols.swift Sources/OrchestraCore/SessionManager.swift Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/OrchestraService+Recovery.swift Tests/OrchestraCoreTests/Stubs.swift Tests/OrchestraCoreTests/CodexAdapterTests.swift
git commit -m "feat(codex): wire Adapter.env (CODEX_HOME) into tmux launch (B1)"
```

---

## Task 5: Full green + typecheck + e2e

- [ ] **Step 1: Full unit suite (unsandboxed shell)**

Run: `./scripts/test.sh`
Expected: PASS. If `RecoveryTests "resume success: confirmed within grace"` is the ONLY failure, re-run `./scripts/test.sh --filter RecoveryTests` (known parallel-load flake) — green in isolation = treat green.

- [ ] **Step 2: App typecheck**

Run: `./scripts/typecheck-app.sh`
Expected: PASS.

- [ ] **Step 3: Advisory UX e2e**

Run: `./scripts/orch-ux-e2e.sh --run-id b1codex`
Expected: advisory. Screenshot step may fail on a headless/locked window server (environmental, not a defect). Unit tests + typecheck are the gate.

- [ ] **Step 4: Record as-built back into the docs (Definition of Done)**

Update `notes/designs/agent-provider-interface/02-contract.md` `CodexAdapter` rows + resolve the B1 D-rows in the SSOT `notes/designs/agent-provider-interface.md` with the real symbol names (`CodexAdapter`, `AgentCapabilities.codex`, `CodexTrust`, `SessionManaging.ensure(env:)`). `docs/` auto-syncs on merge to main (verified post-merge by the orchestrator).

- [ ] **Step 5: Move to `review`, STOP.** Report `DONE: codex/01-adapter-launch — tests green` + one-line summary. Do NOT merge, do NOT archive.

---

## Self-Review

**Spec coverage (B1 row: "rollout session-id discovery; read-only-first; trust_level mirrors ctx.trustCwd; trust+isolation order"):**
- rollout session-id discovery → Task 2 ✓
- read-only-first (`-s read-only -a never`, always) → Task 1 (`startReadOnlyFirst`) ✓
- trust_level mirrors ctx.trustCwd → Task 3 (`appliesCtxTrust`, `untrustedNoWrite`) ✓
- trust+isolation order (home created before trust write) → Task 3 (`appliesCtxTrust` asserts home exists) + `prepareToLaunch` orders createDirectory → CodexTrust ✓
- register agentId="codex" → Task 1 (`registryResolvesCodex`) ✓
- CODEX_HOME isolation actually applied → Task 4 (env wired to launch) ✓
- Approvals deferred / no tailer / no send-keys → not built (out of scope) ✓

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `ensure(_:argv:env:)` used consistently across protocol, `SessionManager`, `StubSessions`, and all call sites; `CodexAdapter(binOverride:codexHome:)`, `AgentCapabilities.codex`, `CodexTrust.apply(trusted:cwd:codexHome:)` names match between defs and tests.
</content>
</invoke>
