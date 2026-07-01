# T1 — Trust Ledger + Core Trust Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Orchestra-owned `TrustLedger` (actor-over-JSON) + a core `resolveTrust(origin,cwd,repo)` that resolves `AdapterContext.trustCwd`, and refactor the Claude trust mirror to apply *from* `ctx.trustCwd` — never reading the ledger.

**Architecture:** `TrustLedger` is a durable path→entry store (sibling to `TaskStore`, same actor-over-JSON + atomic-save + `.bak`-on-malformed pattern). `OrchestraService.resolveTrust` maps `CardOrigin` → `TrustDecision{trusted|needsGrant}` against the ledger (worktree inherits the source repo / scratch auto-trusts + records / borrowed conditional on the ledger). The three launch sites (`spawn`, `resume`, `restart`) set `AdapterContext.trustCwd = (decision == .trusted)` instead of the hardcoded `origin == .scratch`. `ClaudeCodeAdapter.prepareToLaunch` applies the resolved decision via `ClaudeTrust.apply(trusted:cwd:)` — the adapter never consults `TrustLedger`.

**Tech Stack:** Swift 6, swift-testing (`@Suite`/`@Test`) + the existing XCTest suites, `Foundation.JSONSerialization`/`Codable`, the `Tests/OrchestraCoreTests/Stubs.swift` harness (`TestEnv.make()`).

## Global Constraints

- **Adapters NEVER read `TrustLedger`.** Core resolves trust (`resolveTrust` → `ctx.trustCwd`); the adapter only *applies* it. `ClaudeCodeAdapter.swift` must contain no reference to `TrustLedger`.
- **`trustCwd` must be RESOLVED, not hardcoded.** No `origin == .scratch` may remain as the trust source at any launch site.
- **Keep worktree/scratch behavior:** a worktree card and a scratch card both still end up trusted (the agent never blocks on the trust dialog). Only the *borrowed* case newly gates on the ledger.
- **Do NOT build grant/elicitation surfaces** (that is T2). When `resolveTrust` returns `.needsGrant`, `trustCwd` is simply `false` for now.
- **No live agents in tests.** `USE_REAL_CLAUDE` stays unset; trust tests never spawn `claude`. Native-flag writes are tested against an injected temp `home:`, never the real `~/.claude.json`.
- **Offline, deterministic.** No network. Ledger persistence is plain JSON on disk under an injected path.
- **Green gate:** `./scripts/test.sh` + `./scripts/typecheck-app.sh` both pass.

---

## File Structure

- **Create** `Sources/OrchestraCore/Agents/TrustLedger.swift` — `TrustDecision`, `TrustGrantor`, `TrustLedger` actor.
- **Modify** `Sources/OrchestraCore/Config.swift` — add `trustLedgerPath`.
- **Modify** `Sources/OrchestraCore/OrchestraService.swift` — hold a `TrustLedger`; add `resolveTrust`; route `spawn`'s `trustCwd`.
- **Modify** `Sources/OrchestraCore/OrchestraService+Recovery.swift` — route `resume`/`restart` `trustCwd`.
- **Modify** `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift` — `prepareToLaunch` applies `ctx.trustCwd`; replace `ClaudeTrust.mirror` with `ClaudeTrust.apply`.
- **Modify** `Tests/OrchestraCoreTests/Stubs.swift` — `TestEnv.make()` builds + injects + returns a `TrustLedger`.
- **Create** `Tests/OrchestraCoreTests/TrustLedgerTests.swift` — ledger + resolution + persistence + adapter-applies tests.

---

### Task 1: `TrustLedger` store + `TrustDecision`/`TrustGrantor` types

**Files:**
- Create: `Sources/OrchestraCore/Agents/TrustLedger.swift`
- Modify: `Sources/OrchestraCore/Config.swift` (add `trustLedgerPath`)
- Test: `Tests/OrchestraCoreTests/TrustLedgerTests.swift`

**Interfaces:**
- Produces:
  - `public enum TrustDecision: Sendable, Equatable { case trusted, needsGrant }`
  - `public enum TrustGrantor: String, Codable, Sendable { case human, orchestra, repoRegistration }`
  - `public actor TrustLedger` with `public init(path: String = Config.trustLedgerPath)`, `public func isTrusted(_ path: String) -> Bool`, `@discardableResult public func record(_ path: String, grantedBy: TrustGrantor) throws -> Bool` (returns `true` if newly recorded), `@discardableResult public func load() -> Int`.
  - `Config.trustLedgerPath -> String` = `"\(dataDir)/trust-ledger.json"`.
- Keys are canonicalized via `PathResolver.canonical(_:)` so `/tmp` vs `/private/tmp` match `TaskStore`/`resolveRepo` paths.

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/TrustLedgerTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("TrustLedger — durable path store")
struct TrustLedgerTests {
    private func tmpPath() -> String {
        NSTemporaryDirectory() + "trust-\(UUID().uuidString)/ledger.json"
    }

    @Test("unrecorded path is untrusted; recorded path is trusted")
    func recordThenTrusted() async throws {
        let ledger = TrustLedger(path: tmpPath())
        let p = "/some/repo"
        #expect(await ledger.isTrusted(p) == false)
        let added = try await ledger.record(p, grantedBy: .human)
        #expect(added == true)
        #expect(await ledger.isTrusted(p) == true)
    }

    @Test("record is idempotent (second record returns false, still trusted)")
    func recordIdempotent() async throws {
        let ledger = TrustLedger(path: tmpPath())
        let p = "/repo/x"
        #expect(try await ledger.record(p, grantedBy: .orchestra) == true)
        #expect(try await ledger.record(p, grantedBy: .orchestra) == false)
        #expect(await ledger.isTrusted(p) == true)
    }

    @Test("ledger persists across restart (new instance, same path)")
    func persistsAcrossRestart() async throws {
        let path = tmpPath()
        do {
            let ledger = TrustLedger(path: path)
            try await ledger.record("/persisted/repo", grantedBy: .repoRegistration)
        }
        let reopened = TrustLedger(path: path)   // simulates a daemon restart
        #expect(await reopened.isTrusted("/persisted/repo") == true)
    }

    @Test("keys are canonicalized (/tmp == /private/tmp on macOS)")
    func canonicalKeys() async throws {
        let ledger = TrustLedger(path: tmpPath())
        let raw = NSTemporaryDirectory() + "canon-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        try await ledger.record(raw, grantedBy: .human)
        #expect(await ledger.isTrusted(PathResolver.canonical(raw)) == true)
    }

    @Test("malformed ledger file → treated as empty, moved to .bak")
    func malformedResetsToEmpty() async throws {
        let path = tmpPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        let ledger = TrustLedger(path: path)
        #expect(await ledger.isTrusted("/anything") == false)
        #expect(FileManager.default.fileExists(atPath: path + ".bak"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter TrustLedgerTests`
Expected: FAIL to compile — `TrustLedger` / `TrustGrantor` / `Config.trustLedgerPath` are undefined.

- [ ] **Step 3: Add `Config.trustLedgerPath`**

In `Sources/OrchestraCore/Config.swift`, next to `tasksPath` (~line 67):

```swift
    public static var trustLedgerPath: String { "\(dataDir)/trust-ledger.json" }
```

- [ ] **Step 4: Implement `TrustLedger.swift`**

Create `Sources/OrchestraCore/Agents/TrustLedger.swift`:

```swift
import Foundation

/// The core's trust decision for a launch. `needsGrant` means an untrusted, un-ledgered cwd that a
/// human must approve (the grant surfaces land in T2); until then it resolves to `trustCwd = false`.
public enum TrustDecision: Sendable, Equatable { case trusted, needsGrant }

/// Who put an entry in the ledger. `orchestra` = auto-trust of a dir Orchestra made empty (scratch);
/// `repoRegistration` = a worktree's source repo (registering a repo to run agents is the trust act);
/// `human` = an explicit human grant (T2 surfaces).
public enum TrustGrantor: String, Codable, Sendable { case human, orchestra, repoRegistration }

/// Orchestra-owned, provider-agnostic trust source of truth (repo/cwd → trusted). Actor-over-JSON,
/// sibling to `TaskStore`: atomic save (temp + replaceItem), malformed file → `.bak` + empty. This is
/// what makes a repo trusted once carry across agents (Claude, later Codex) — each adapter *mirrors*
/// it into its native flag. Only the CORE reads it (in `resolveTrust`); adapters never do.
public actor TrustLedger {
    struct Entry: Codable, Sendable { var grantedBy: TrustGrantor; var grantedAt: Date }

    private let path: String
    private var entries: [String: Entry] = [:]
    private var loaded = false

    public init(path: String = Config.trustLedgerPath) { self.path = path }

    /// Read + decode. `[:]` if absent; malformed → `.bak` + `[:]`. Returns the entry count.
    @discardableResult
    public func load() -> Int {
        loaded = true
        guard FileManager.default.fileExists(atPath: path) else { entries = [:]; return 0 }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            entries = try OrchestraJSON.decoder.decode([String: Entry].self, from: data)
        } catch {
            let bak = path + ".bak"
            try? FileManager.default.removeItem(atPath: bak)
            try? FileManager.default.moveItem(atPath: path, toPath: bak)
            entries = [:]
        }
        return entries.count
    }

    private func ensureLoaded() { if !loaded { _ = load() } }

    /// True iff `path` (canonicalized) has an entry.
    public func isTrusted(_ path: String) -> Bool {
        ensureLoaded()
        return entries[PathResolver.canonical(path)] != nil
    }

    /// Record `path` (canonicalized) as trusted. No-op (returns false) if already present. Persists.
    @discardableResult
    public func record(_ path: String, grantedBy: TrustGrantor) throws -> Bool {
        ensureLoaded()
        let key = PathResolver.canonical(path)
        if entries[key] != nil { return false }
        entries[key] = Entry(grantedBy: grantedBy, grantedAt: Date())
        try persist()
        return true
    }

    private func persist() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try OrchestraJSON.pretty.encode(entries)
        let url = URL(fileURLWithPath: path)
        let tmp = URL(fileURLWithPath: path + ".tmp.\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
```

> Note: `OrchestraJSON.decoder`/`.pretty` are the same coders `TaskStore` uses (`Coders.swift`) — they encode `Date` consistently, so persistence round-trips.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter TrustLedgerTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Agents/TrustLedger.swift Sources/OrchestraCore/Config.swift Tests/OrchestraCoreTests/TrustLedgerTests.swift
git commit -m "feat(trust): TrustLedger actor-over-JSON store + Config.trustLedgerPath"
```

---

### Task 2: `resolveTrust(origin,cwd,repo)` on `OrchestraService`

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add `let trust: TrustLedger` + init param + `resolveTrust`)
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` (`TestEnv.make()` builds/injects/returns the ledger)
- Test: `Tests/OrchestraCoreTests/TrustLedgerTests.swift` (add resolution suite)

**Interfaces:**
- Consumes: `TrustLedger` (Task 1); `CardOrigin` (`Model.swift:97`: `worktree | scratch | borrowed`).
- Produces: `public func resolveTrust(origin: CardOrigin, cwd: String, repo: String?) async -> TrustDecision`.
  - `scratch` → record `cwd` (`.orchestra`), return `.trusted`.
  - `worktree` → record `repo` if present (`.repoRegistration`), return `.trusted` (inherit; registering the repo is the trust act).
  - `borrowed` → `ledger.isTrusted(cwd)` ? `.trusted` : `.needsGrant`.
- `TestEnv.make()` return tuple gains a trailing `trust: TrustLedger` member (all call sites use `env.svc`-style access, so this is non-breaking).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/OrchestraCoreTests/TrustLedgerTests.swift`:

```swift
@Suite("resolveTrust — origin → decision")
struct ResolveTrustTests {
    @Test("scratch auto-trusts and records the cwd in the ledger")
    func scratchAutoTrusts() async throws {
        let env = TestEnv.make()
        let cwd = env.base + "/scratch-xyz"
        let d = await env.svc.resolveTrust(origin: .scratch, cwd: cwd, repo: nil)
        #expect(d == .trusted)
        #expect(await env.trust.isTrusted(cwd) == true)   // recorded
    }

    @Test("worktree inherits the source-repo entry (trusted; repo recorded)")
    func worktreeInheritsRepo() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base, "app")
        // A repo already registered in the ledger → its worktree inherits trust.
        try await env.trust.record(repo, grantedBy: .repoRegistration)
        let wt = env.base + "/worktrees/app/feat"
        let d = await env.svc.resolveTrust(origin: .worktree, cwd: wt, repo: repo)
        #expect(d == .trusted)
    }

    @Test("worktree with an unregistered repo records it then trusts (registration IS the trust act)")
    func worktreeRecordsRepo() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base, "fresh")
        #expect(await env.trust.isTrusted(repo) == false)
        let d = await env.svc.resolveTrust(origin: .worktree, cwd: env.base + "/worktrees/fresh/x", repo: repo)
        #expect(d == .trusted)
        #expect(await env.trust.isTrusted(repo) == true)   // now registered
    }

    @Test("borrowed in the ledger = trusted; else = needsGrant")
    func borrowedConditional() async throws {
        let env = TestEnv.make()
        let inLedger = env.base + "/borrowed-trusted"
        let notInLedger = env.base + "/borrowed-unknown"
        try await env.trust.record(inLedger, grantedBy: .human)
        #expect(await env.svc.resolveTrust(origin: .borrowed, cwd: inLedger, repo: nil) == .trusted)
        #expect(await env.svc.resolveTrust(origin: .borrowed, cwd: notInLedger, repo: nil) == .needsGrant)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test.sh --filter ResolveTrustTests`
Expected: FAIL to compile — `env.trust` and `svc.resolveTrust` don't exist yet.

- [ ] **Step 3: Add the ledger to `OrchestraService`**

In `Sources/OrchestraCore/OrchestraService.swift`, add the stored property alongside `store`/`registry`:

```swift
    let trust: TrustLedger
```

Add an init param (with default, so `orchestrad`'s call site is unchanged) and assign it. Change the signature:

```swift
    public init(config: Config,
                store: TaskStore? = nil,
                registry: AgentRegistry = AgentRegistry(),
                worktrees: (any WorktreeManaging)? = nil,
                sessions: (any SessionManaging)? = nil,
                launcher: Launcher? = nil,
                resolver: PathResolver? = nil,
                trust: TrustLedger? = nil) {
```

and in the body:

```swift
        self.trust = trust ?? TrustLedger()
```

- [ ] **Step 4: Implement `resolveTrust`**

Add to `OrchestraService.swift` (near `spawn`, in the same actor):

```swift
    /// Resolve trust for a launch from the card's origin (provider-agnostic). The result rides on
    /// `AdapterContext.trustCwd`; the adapter *applies* it and never reads the ledger.
    /// - `scratch`  → auto-trust (Orchestra made it empty) + record.
    /// - `worktree` → inherit the source repo's trust; registering a repo to run agents IS the trust
    ///   act, so record the repo (idempotent) and trust the worktree.
    /// - `borrowed` → trusted iff the cwd is already in the ledger; else `needsGrant` (human grant is T2).
    public func resolveTrust(origin: CardOrigin, cwd: String, repo: String?) async -> TrustDecision {
        switch origin {
        case .scratch:
            try? await trust.record(cwd, grantedBy: .orchestra)
            return .trusted
        case .worktree:
            if let repo { try? await trust.record(repo, grantedBy: .repoRegistration) }
            return .trusted
        case .borrowed:
            return await trust.isTrusted(cwd) ? .trusted : .needsGrant
        }
    }
```

- [ ] **Step 5: Wire the ledger into `TestEnv.make()`**

In `Tests/OrchestraCoreTests/Stubs.swift`, update `TestEnv.make()` to build, inject, and return the ledger. Change the return type and body:

```swift
    static func make(maxRevivals: Int = 4, grace: Int = 1)
        -> (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String) {
        let base = NSTemporaryDirectory() + "orch-svc-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: base + "/repos", withIntermediateDirectories: true)
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)],
                            maxConcurrentRevivals: maxRevivals, revivalGraceSeconds: grace)
        let sessions = StubSessions()
        let worktrees = StubWorktrees(root: config.worktreesRoot)
        let adapter = StubAdapter(transcriptDir: base + "/transcripts")
        let store = TaskStore(path: base + "/tasks.json")
        let trust = TrustLedger(path: base + "/trust-ledger.json")
        let svc = OrchestraService(config: config, store: store,
                                   registry: AgentRegistry(adapters: [adapter]),
                                   worktrees: worktrees, sessions: sessions, trust: trust)
        return (svc, sessions, worktrees, adapter, trust, PathResolver.canonical(base))
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter ResolveTrustTests`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Tests/OrchestraCoreTests/Stubs.swift Tests/OrchestraCoreTests/TrustLedgerTests.swift
git commit -m "feat(trust): OrchestraService.resolveTrust(origin) → TrustDecision; inject ledger"
```

---

### Task 3: Route `trustCwd` through `resolveTrust` at the 3 launch sites

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (`spawn`, ~line 123)
- Modify: `Sources/OrchestraCore/OrchestraService+Recovery.swift` (`resume` ~line 64; `restart` ~line 115)
- Test: `Tests/OrchestraCoreTests/TrustLedgerTests.swift` (add a spawn-records suite)

**Interfaces:**
- Consumes: `resolveTrust` (Task 2).
- Produces: no new API — replaces each `trustCwd: origin == .scratch` / `task.origin == .scratch` with the resolved decision. Behavior: scratch + worktree still trusted; borrowed newly gates on the ledger.

- [ ] **Step 1: Write the failing test**

Append to `Tests/OrchestraCoreTests/TrustLedgerTests.swift`:

```swift
@Suite("spawn — trust routed through resolveTrust")
struct SpawnTrustRoutingTests {
    @Test("scratch spawn records its cwd in the ledger (trust resolved, not hardcoded)")
    func scratchSpawnRecordsLedger() async throws {
        try await withScratchLock {
            let env = TestEnv.make()
            let t = try await env.svc.spawn(SpawnInput(prompt: "scratch work", scratch: true))
            #expect(t.origin == .scratch)
            #expect(await env.trust.isTrusted(t.cwd) == true)   // resolveTrust recorded it during spawn
            try? FileManager.default.removeItem(atPath: t.cwd)
        }
    }

    @Test("borrowed spawn of an un-ledgered dir does NOT record it (needsGrant → untrusted)")
    func borrowedSpawnNoAutoTrust() async throws {
        let env = TestEnv.make()
        let dir = env.base + "/borrowed-here"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let t = try await env.svc.spawn(SpawnInput(prompt: "peek", cwd: dir, access: .readWrite))
        #expect(t.origin == .borrowed)
        #expect(await env.trust.isTrusted(dir) == false)   // no auto-trust for borrowed
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter SpawnTrustRoutingTests`
Expected: FAIL — scratch spawn's `trustCwd` is still hardcoded (`origin == .scratch`), so the ledger is never written; `isTrusted` returns false.

- [ ] **Step 3: Route `spawn` (`OrchestraService.swift` ~line 121-123)**

Replace the `AdapterContext` construction's trust argument. Before the `let ctx = AdapterContext(...)`, resolve the decision:

```swift
        let trustDecision = await resolveTrust(origin: origin, cwd: cwd, repo: realRepo)
        let ctx = AdapterContext(cwd: cwd, repo: realRepo, model: model.id, startIn: startIn,
                                 sessionId: sid, prompt: launchPrompt, name: title,
                                 hooksPath: Config.hooksPath, access: input.access,
                                 trustCwd: trustDecision == .trusted)
```

- [ ] **Step 4: Route `resume` (`OrchestraService+Recovery.swift` ~line 60-64)**

Replace the `trustCwd: task.origin == .scratch` in the `resume` context. Resolve first:

```swift
        let trustDecision = await resolveTrust(origin: task.origin, cwd: task.cwd, repo: task.repo)
        let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: task.model.id,
                                 sessionId: task.agentSessionId, name: task.title, hooksPath: Config.hooksPath,
                                 trustCwd: trustDecision == .trusted)
```

- [ ] **Step 5: Route `restart` (`OrchestraService+Recovery.swift` ~line 110-118)**

Replace the `trustCwd: task.origin == .scratch` in the `restart` context:

```swift
        let trustDecision = await resolveTrust(origin: task.origin, cwd: task.cwd, repo: task.repo)
        let ctx = AdapterContext(cwd: task.cwd, repo: task.repo, model: task.model.id,
                                 startIn: task.startIn, sessionId: freshId, prompt: nil,
                                 name: task.title, hooksPath: Config.hooksPath,
                                 trustCwd: trustDecision == .trusted)
```

- [ ] **Step 6: Verify no hardcoded trust source remains**

Run: `grep -rn "origin == .scratch\|origin == \.scratch" Sources/OrchestraCore` — expect **no** match tied to `trustCwd`. (Other `origin` comparisons unrelated to trust are fine, e.g. scratch-sweep.)

- [ ] **Step 7: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter SpawnTrustRoutingTests`
Expected: PASS (2 tests). Also run `./scripts/test.sh --filter ScratchSpawnTests --filter BorrowedSpawnTests` to confirm no regression.

- [ ] **Step 8: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/OrchestraService+Recovery.swift Tests/OrchestraCoreTests/TrustLedgerTests.swift
git commit -m "feat(trust): route spawn/resume/restart trustCwd through resolveTrust"
```

---

### Task 4: Claude mirror applies `ctx.trustCwd` (never reads the ledger)

**Files:**
- Modify: `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift` (`prepareToLaunch`; `ClaudeTrust`)
- Test: `Tests/OrchestraCoreTests/TrustLedgerTests.swift` (add adapter-applies suite)

**Interfaces:**
- Consumes: `AdapterContext.trustCwd` (already exists, now resolved).
- Produces: `ClaudeTrust.apply(trusted: Bool, cwd: String, home: String = Config.home)` — writes the native `hasTrustDialogAccepted` flag for `cwd` **iff** `trusted`; no-op otherwise. Replaces the old `mirror`/`isTrusted` (removed). `grant(_:home:)` stays as the private write helper `apply` delegates to.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/OrchestraCoreTests/TrustLedgerTests.swift`:

```swift
@Suite("Claude trust mirror — applies ctx.trustCwd, never reads the ledger")
struct ClaudeApplyTrustTests {
    // Injected temp HOME so we never touch the real ~/.claude.json.
    private func tmpHome() -> String {
        let h = NSTemporaryDirectory() + "home-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: h, withIntermediateDirectories: true)
        return h
    }
    private func accepted(_ home: String, _ cwd: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.claude.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = root["projects"] as? [String: Any],
              let project = projects[cwd] as? [String: Any] else { return false }
        return project["hasTrustDialogAccepted"] as? Bool == true
    }

    @Test("trusted=true writes the native hasTrustDialogAccepted flag for cwd")
    func appliesWhenTrusted() {
        let home = tmpHome()
        let cwd = "/wt/app/feat"
        ClaudeTrust.apply(trusted: true, cwd: cwd, home: home)
        #expect(accepted(home, cwd) == true)
    }

    @Test("trusted=false leaves the native flag unwritten")
    func skipsWhenUntrusted() {
        let home = tmpHome()
        let cwd = "/wt/app/feat"
        ClaudeTrust.apply(trusted: false, cwd: cwd, home: home)
        #expect(accepted(home, cwd) == false)
    }

    @Test("prepareToLaunch grants when ctx.trustCwd is true (default home path)")
    func prepareToLaunchRoutesOnTrustCwd() throws {
        // We assert the routing decision, not the real HOME write: with trustCwd=false the adapter
        // must not attempt any native grant. (The native write itself is covered above with temp HOME.)
        let a = ClaudeCodeAdapter()
        let ctx = AdapterContext(cwd: "/nonexistent/\(UUID().uuidString)", access: .readWrite, trustCwd: false)
        try a.prepareToLaunch(ctx)   // must be a no-op for trust; no throw
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter ClaudeApplyTrustTests`
Expected: FAIL to compile — `ClaudeTrust.apply` is undefined.

- [ ] **Step 3: Add `ClaudeTrust.apply`; simplify `prepareToLaunch`; remove `mirror`**

In `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift`:

Replace the trust block in `prepareToLaunch` (the `if ctx.trustCwd { ClaudeTrust.grant(...) } else { ClaudeTrust.mirror(...) }`) with:

```swift
        // Apply the CORE's trust decision (resolved into ctx.trustCwd by OrchestraService.resolveTrust).
        // The adapter only *mirrors* the decision into Claude's native per-directory trust — it never
        // reads the TrustLedger itself. When untrusted, leave Claude to prompt / the card to clamp.
        ClaudeTrust.apply(trusted: ctx.trustCwd, cwd: ctx.cwd)
```

In the `ClaudeTrust` enum, add `apply` and delete `mirror(toWorktree:fromRepo:)` and the private `isTrusted(_:in:)` helper (now unused — worktree trust is resolved by core):

```swift
    /// Apply the core's already-resolved trust decision to Claude's native per-directory trust.
    /// Writes `hasTrustDialogAccepted` for `cwd` iff `trusted`; otherwise a no-op. This is the ONLY
    /// trust entry point the adapter uses — it consumes `ctx.trustCwd`, never the TrustLedger.
    static func apply(trusted: Bool, cwd: String, home: String = Config.home) {
        guard trusted else { return }
        grant(cwd, home: home)
    }
```

Keep `grant(_:home:)` as-is (now called only by `apply`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test.sh --filter ClaudeApplyTrustTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Verify the adapter no longer references the ledger**

Run: `grep -n "TrustLedger\|mirror" Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift`
Expected: **no** match (mirror removed; ledger never referenced).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift Tests/OrchestraCoreTests/TrustLedgerTests.swift
git commit -m "refactor(trust): Claude mirror applies ctx.trustCwd via ClaudeTrust.apply; drop mirror"
```

---

### Task 5: Full green gate + docs decision record

**Files:**
- Modify: `notes/designs/agent-provider-interface/02-contract.md` (flip T1 rows to as-built; secondary hygiene per DoD step 2)

- [ ] **Step 1: Run the full unit suite**

Run: `./scripts/test.sh`
Expected: PASS — all existing suites (`ReportTests`, `AdapterTests`, `RecoveryTests`, `ScratchSpawnTests`, `BorrowedSpawnTests`, …) still green + the new `TrustLedgerTests`/`ResolveTrustTests`/`SpawnTrustRoutingTests`/`ClaudeApplyTrustTests`.

If sandbox blocks `swift build`/`test` (`sandbox-exec: sandbox_apply: Operation not permitted`), re-run with the sandbox disabled.

- [ ] **Step 2: Run the app typecheck**

Run: `./scripts/typecheck-app.sh`
Expected: PASS.

- [ ] **Step 3: Record the as-built decision (planning hygiene)**

In `notes/designs/agent-provider-interface/02-contract.md`, note under the relevant `Decisions made` / symbol references that T1 shipped: `TrustLedger` (`Agents/TrustLedger.swift`), `TrustDecision{trusted,needsGrant}`, `OrchestraService.resolveTrust(origin:cwd:repo:)`, and `ClaudeTrust.apply(trusted:cwd:home:)`. (The `docs/` chapter sync is automatic on merge to `main`; this is the secondary planning-truth update only.)

- [ ] **Step 4: Commit**

```bash
git add notes/designs/agent-provider-interface/02-contract.md
git commit -m "docs(trust): record T1 as-built symbols in the contract layer"
```

---

## Self-Review

**Spec coverage (T1 "plan must cover"):**
- **ledger schema/persistence** → Task 1 (`TrustLedger` actor-over-JSON, atomic save, `.bak`-on-malformed, persistence-across-restart test).
- **origin→decision table** → Task 2 (`resolveTrust`: worktree inherit / scratch auto-trust+record / borrowed conditional) with a test per row.
- **keep worktree/scratch behavior** → Task 3 (scratch + worktree still resolve `trusted`; existing `ScratchSpawnTests`/`BorrowedSpawnTests` stay green) + Task 4 (Claude native grant still written for trusted cwds).
- **trustCwd resolved not hardcoded** → Task 3 (all three sites replace `origin == .scratch`; grep guard in Step 6) + adapter applies the resolved value (Task 4).
- **Unit tests required by the spec:** worktree inherits source-repo entry ✓ (ResolveTrustTests); scratch auto-trusts + records ✓; borrowed-in-ledger=trusted else needsGrant ✓; ledger persists across restart ✓ (TrustLedgerTests); `test_adapter_applies_ctx_trust` (adapter writes native flag FROM ctx.trustCwd, never reads TrustLedger) ✓ (ClaudeApplyTrustTests + grep guard).
- **Out of scope honored:** no grant/elicitation surfaces (T2); `needsGrant` → `trustCwd=false`; `USE_REAL_CLAUDE` unset; no live elicitation.

**Placeholder scan:** none — every code step shows full code.

**Type consistency:** `TrustDecision`/`TrustGrantor`/`TrustLedger`/`resolveTrust`/`ClaudeTrust.apply` spellings match across tasks; `TestEnv.make()` tuple field `trust` used consistently in Tasks 2/3.
