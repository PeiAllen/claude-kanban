# T2 — Trust Grant Surfaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the human-in-the-loop trust **grant surfaces** on top of T1's ledger + `resolveTrust`: a `trust` Command (MCP + CLI), the `orchestra trust` CLI verb (interactive-only), the MCP `requestElicitation` grant path, and the untrusted-spawn actionable-context behavior — so a `needsGrant` decision can be filled by a **human**, never by the agent.

**Architecture:** T1 already resolves `{trusted | needsGrant}` from a card's origin and rides the result on `AdapterContext.trustCwd`. T2 fills the `needsGrant` gap. Core gains a small **grant seam** — `TrustGrantResolver` (protocol) on `OrchestraService`, consulted by a new `grantTrust(path:source:)` method that backs the `trust` Command. The **surfaces** perform the human gate before the record ever happens: the MCP bridge calls `Server.requestElicitation` to the agent's own client (a human answers), and the CLI gates on `isatty` and refuses non-interactively. The production resolver approves only for interactive surfaces (`.cli`/`.mcp`/`.app`) and **denies for `.agent`/`.daemon`** — that one rule is the autonomy-exemption and the "agent can't self-grant" guarantee. Automated tests use a **stub grant resolver** only (approve / deny fixtures); the real dialog is manual and out of scope (rule O7).

**Tech Stack:** Swift 6, swift-testing (`@Suite`/`@Test`/`#expect`), the MCP swift-sdk (`Server.requestElicitation`), actor-over-JSON stores (`TrustLedger`).

## Global Constraints

- **No `--trust` flag anywhere** — a human grants via the interactive `orchestra trust` verb or the MCP elicitation dialog; there is no non-interactive "just trust it" switch.
- **The agent only triggers; a human answers.** Core never self-grants. `SurfaceGrantResolver` denies `.agent`/`.daemon` sources (the autonomy-exemption).
- **Adapters never read the ledger.** T2 does not touch adapters — trust still rides `ctx.trustCwd` (resolved by core in T1). T2 only changes when/whether the ledger gets a `human` entry.
- **Registry ↔ MCP parity is a tripwire.** Adding the `trust` Command REQUIRES adding `"trust"` to the `expected` array in `Tests/OrchestraCoreTests/CommandsTests.swift` (else `fullSet` goes red) AND a `CLIRunner` verb case (CLI is not auto-derived). MCP `tools/list` parity is automatic (generated from the registry).
- **Tests use the stub grant resolver only.** `USE_REAL_CLAUDE` stays unset; no live MCP client; no live `requestElicitation`/`SpawnSheet` drive (O7). The `SpawnSheet` UI is D3's job — **T2 adds NO UI surface**, so `orch-ux-e2e.sh` is not required.
- **Build/test in an UNSANDBOXED shell.** `./scripts/test.sh` + `./scripts/typecheck-app.sh`. Stale build → only `rm -rf .build` in this worktree.

---

## File Structure

**Core (`Sources/OrchestraCore/`):**
- `Agents/TrustGrant.swift` **(NEW)** — the grant seam: `TrustGrantOutcome`, `TrustGrantResolver` (protocol), `SurfaceGrantResolver` (production default), `TrustGrantResult` (Codable return), and the pure CLI-prompt helpers `TrustPrompt.isAffirmative` / `TrustPrompt.nonInteractiveHelp`.
- `OrchestraService.swift` — add the injected `grantResolver`; add `grantTrust(path:source:)`; demote a foreign-code scratch dir in `resolveTrust`; emit an actionable activity when `spawn` resolves `needsGrant`.
- `Commands.swift` — add the `trust` Command (auto-appears in MCP `tools/list`).
- `Errors.swift` — add `.trustDenied(String)` (code 1011).

**CLI (`Sources/orchestra/`):**
- `CLIRunner.swift` — add the `trust` verb (isatty gate + confirm prompt → daemon `trust`).
- `CLIHelp.swift` — one help line for `trust`.

**MCP (`Sources/orchestra-mcp/`):**
- `main.swift` — special-case the `trust` tool: `requestElicitation` to the client, relay to the daemon only on `.accept`.

**Tests (`Tests/OrchestraCoreTests/`):**
- `Stubs.swift` — add `StubGrantResolver`.
- `CommandsTests.swift` — add `"trust"` to `expected`.
- `TrustGrantTests.swift` **(NEW)** — the grant behavior suite.

---

## Task 1: Grant seam types (`TrustGrant.swift`)

**Files:**
- Create: `Sources/OrchestraCore/Agents/TrustGrant.swift`
- Test: `Tests/OrchestraCoreTests/TrustGrantTests.swift` (created here, grown in later tasks)

**Interfaces:**
- Produces:
  - `enum TrustGrantOutcome: Sendable, Equatable { case approved, denied }`
  - `protocol TrustGrantResolver: Sendable { func requestGrant(path: String, reason: String, source: ActivitySource) async -> TrustGrantOutcome }`
  - `struct SurfaceGrantResolver: TrustGrantResolver` — approves `.cli`/`.mcp`/`.app`, denies `.agent`/`.daemon`
  - `struct TrustGrantResult: Codable, Sendable, Equatable { let path: String; let granted: Bool; let alreadyTrusted: Bool }`
  - `enum TrustPrompt { static func isAffirmative(_ line: String?) -> Bool; static func nonInteractiveHelp(_ path: String) -> String }`

- [ ] **Step 1: Write the failing test**

Create `Tests/OrchestraCoreTests/TrustGrantTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Trust grant seam — types")
struct TrustGrantSeamTests {
    @Test("SurfaceGrantResolver approves interactive surfaces, denies agent/daemon (autonomy-exempt)")
    func surfaceResolverGating() async {
        let r = SurfaceGrantResolver()
        for s in [ActivitySource.cli, .mcp, .app] {
            #expect(await r.requestGrant(path: "/p", reason: "x", source: s) == .approved)
        }
        for s in [ActivitySource.agent, .daemon] {
            #expect(await r.requestGrant(path: "/p", reason: "x", source: s) == .denied)
        }
    }

    @Test("TrustPrompt.isAffirmative accepts y/yes (any case), rejects everything else incl. nil/empty")
    func affirmative() {
        for yes in ["y", "Y", "yes", "YES", " yes "] { #expect(TrustPrompt.isAffirmative(yes)) }
        for no in [nil, "", "n", "no", "q", "sure"] { #expect(!TrustPrompt.isAffirmative(no)) }
    }

    @Test("nonInteractiveHelp names the path and mentions no --trust, read-only, and the interactive verb")
    func help() {
        let m = TrustPrompt.nonInteractiveHelp("/some/dir")
        #expect(m.contains("/some/dir"))
        #expect(m.contains("orchestra trust"))
        #expect(m.contains("read-only"))
        #expect(!m.contains("--trust"))   // there is NO --trust flag
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter TrustGrantSeamTests`
Expected: FAIL — `SurfaceGrantResolver`, `TrustPrompt` not defined (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OrchestraCore/Agents/TrustGrant.swift`:

```swift
import Foundation

/// The outcome of asking a human to approve trusting a path. There is no third "timeout" case: a
/// timeout / no-human / declined all collapse to `.denied` (fail closed → the card runs sandboxed).
public enum TrustGrantOutcome: Sendable, Equatable { case approved, denied }

/// The human-grant seam. Core NEVER decides trust on its own — it asks a resolver, and the resolver
/// stands in for a human answering at a surface (MCP elicitation dialog / CLI tty prompt). The agent
/// may only *trigger* a grant; the resolver is what a human *answers* through.
public protocol TrustGrantResolver: Sendable {
    func requestGrant(path: String, reason: String, source: ActivitySource) async -> TrustGrantOutcome
}

/// Production resolver. The human gate lives at the *surface* (the MCP bridge elicits; the CLI checks
/// `isatty` + prompts) BEFORE the daemon `trust` command is ever relayed — so by the time core is
/// asked, an interactive surface means a human already approved. Agent/daemon sources can never reach
/// a human of their own, so they are denied: that single rule is both the **autonomy-exemption**
/// ("autonomy cards exempt trust") and the "an agent can't self-grant" guarantee.
public struct SurfaceGrantResolver: TrustGrantResolver {
    public init() {}
    public func requestGrant(path: String, reason: String, source: ActivitySource) async -> TrustGrantOutcome {
        switch source {
        case .cli, .mcp, .app: return .approved   // surface already gated a human through
        case .agent, .daemon:  return .denied      // no human channel → never self-grant
        }
    }
}

/// Result of a `trust` command, returned to the CLI/MCP caller.
public struct TrustGrantResult: Codable, Sendable, Equatable {
    public let path: String
    public let granted: Bool
    public let alreadyTrusted: Bool
    public init(path: String, granted: Bool, alreadyTrusted: Bool) {
        self.path = path; self.granted = granted; self.alreadyTrusted = alreadyTrusted
    }
}

/// Pure helpers for the interactive CLI grant (kept in core so they are unit-testable; `CLIRunner`
/// supplies the real `isatty` + `readLine`).
public enum TrustPrompt {
    /// A yes-answer to the grant prompt: `y`/`yes` (any case, surrounding space ok). Everything else —
    /// including nil (EOF) and empty (bare Enter) — is a NO. Fail closed.
    public static func isAffirmative(_ line: String?) -> Bool {
        guard let t = line?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return t == "y" || t == "yes"
    }

    /// The actionable message printed when `orchestra trust` is run without a tty (no human to ask).
    /// Deliberately never mentions a `--trust` flag — there isn't one.
    public static func nonInteractiveHelp(_ path: String) -> String {
        """
        orchestra trust: refusing to grant trust for \(path) without an interactive terminal.
        Trust is a human decision — re-run `orchestra trust \(path)` in a real terminal to approve it,
        or spawn the card read-only (agents run sandboxed, no write) if you don't want to grant trust.
        """
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter TrustGrantSeamTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Agents/TrustGrant.swift Tests/OrchestraCoreTests/TrustGrantTests.swift
git commit -m "feat(t2): trust grant seam types (resolver, result, prompt helpers)"
```

---

## Task 2: `OrchestraService.grantTrust` + injected resolver + `.trustDenied` error

**Files:**
- Modify: `Sources/OrchestraCore/Errors.swift` (add `.trustDenied`)
- Modify: `Sources/OrchestraCore/OrchestraService.swift:6-62` (add `grantResolver` field + init param; add `grantTrust`)
- Modify: `Tests/OrchestraCoreTests/Stubs.swift` (add `StubGrantResolver`; let `TestEnv.make` inject it)
- Test: `Tests/OrchestraCoreTests/TrustGrantTests.swift`

**Interfaces:**
- Consumes: `TrustLedger.record`/`isTrusted` (T1), `PathResolver.canonical`, `emitActivity`.
- Produces:
  - `OrchestraService.grantTrust(_ path: String, source: ActivitySource) async throws -> TrustGrantResult`
  - `OrchestraError.trustDenied(String)` (code 1011)
  - `StubGrantResolver(_ outcome: TrustGrantOutcome)` recording its calls
  - `TestEnv.make(... , grantResolver: any TrustGrantResolver = SurfaceGrantResolver())`

- [ ] **Step 1: Write the failing test — add `StubGrantResolver` then the grantTrust suite**

In `Tests/OrchestraCoreTests/Stubs.swift`, add before `enum TestEnv`:

```swift
/// Stub human-grant resolver: returns a fixed outcome and records what it was asked (drives the
/// approve / deny grant tests without a live MCP client or tty — O7).
final class StubGrantResolver: TrustGrantResolver, @unchecked Sendable {
    let outcome: TrustGrantOutcome
    private let lock = NSLock()
    private(set) var asked: [(path: String, source: ActivitySource)] = []
    init(_ outcome: TrustGrantOutcome) { self.outcome = outcome }
    func requestGrant(path: String, reason: String, source: ActivitySource) async -> TrustGrantOutcome {
        lock.lock(); asked.append((path, source)); lock.unlock()
        return outcome
    }
}
```

Change `TestEnv.make`'s signature and construction to thread a resolver in. Update the signature line and the `OrchestraService(...)` call:

```swift
    static func make(maxRevivals: Int = 4, grace: Int = 1, capabilities: AgentCapabilities = .claudeCode,
                     grantResolver: any TrustGrantResolver = SurfaceGrantResolver())
        -> (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String) {
```
```swift
        let svc = OrchestraService(config: config, store: store,
                                   registry: AgentRegistry(adapters: [adapter]),
                                   worktrees: worktrees, sessions: sessions, trust: trust, inbox: inbox,
                                   grantResolver: grantResolver)
```

In `Tests/OrchestraCoreTests/TrustGrantTests.swift`, add a new suite:

```swift
@Suite("grantTrust — the trust Command's service method")
struct GrantTrustTests {
    @Test("approved grant records a human entry and reports granted (not already-trusted)")
    func approvedRecords() async throws {
        let env = TestEnv.make(grantResolver: StubGrantResolver(.approved))
        let dir = env.base + "/borrowed-grant"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        #expect(await env.trust.isTrusted(dir) == false)
        let res = try await env.svc.grantTrust(dir, source: .cli)
        #expect(res.granted && !res.alreadyTrusted)
        #expect(await env.trust.isTrusted(dir) == true)
        // and the grant now flips resolveTrust for a borrowed card in that dir → trusted (mirrors)
        #expect(await env.svc.resolveTrust(origin: .borrowed, cwd: dir, repo: nil) == .trusted)
    }

    @Test("denied grant records NOTHING and throws trustDenied (agent/tool can't self-grant)")
    func deniedThrows() async throws {
        let env = TestEnv.make(grantResolver: StubGrantResolver(.denied))
        let dir = env.base + "/borrowed-deny"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        await #expect(throws: OrchestraError.self) {
            _ = try await env.svc.grantTrust(dir, source: .agent)
        }
        #expect(await env.trust.isTrusted(dir) == false)   // no self-grant
    }

    @Test("granting an already-trusted path is a no-op success (alreadyTrusted, resolver not asked)")
    func idempotent() async throws {
        let resolver = StubGrantResolver(.denied)   // would deny if asked — proves it isn't
        let env = TestEnv.make(grantResolver: resolver)
        let dir = env.base + "/pre-trusted"
        try await env.trust.record(dir, grantedBy: .human)
        let res = try await env.svc.grantTrust(dir, source: .cli)
        #expect(res.granted && res.alreadyTrusted)
        #expect(resolver.asked.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter GrantTrustTests`
Expected: FAIL — `grantTrust` undefined; `OrchestraService` has no `grantResolver:` param.

- [ ] **Step 3: Write minimal implementation**

In `Sources/OrchestraCore/Errors.swift`, add the case (after `.io`):
```swift
    case trustDenied(String)
```
add to `description`:
```swift
        case .trustDenied(let m): return "trust not granted: \(m)"
```
add to `code`:
```swift
        case .trustDenied:      return 1011
```

In `Sources/OrchestraCore/OrchestraService.swift`, add the stored field next to `trust` (after line 21's `inbox`):
```swift
    /// The human-grant resolver (T2). Consulted by `grantTrust`; the production `SurfaceGrantResolver`
    /// only approves interactive surfaces and denies agent/daemon (autonomy-exemption + no self-grant).
    let grantResolver: any TrustGrantResolver
```
Add the init param (after `inbox: Inbox? = nil,`):
```swift
                inbox: Inbox? = nil,
                grantResolver: any TrustGrantResolver = SurfaceGrantResolver()) {
```
and in the body (after `self.inbox = ...`):
```swift
        self.grantResolver = grantResolver
```

Add the method in the `// MARK: - trust` section (after `resolveTrust`, around line 107):
```swift
    /// The `trust` Command's service method (T2). Records a HUMAN grant for `path` into the ledger —
    /// but only after the resolver (standing in for a human at a surface) approves. The agent may only
    /// trigger this; a human answers. Fail-closed: a `.denied` outcome records nothing and throws.
    @discardableResult
    public func grantTrust(_ path: String, source: ActivitySource) async throws -> TrustGrantResult {
        let canon = PathResolver.canonical(path)
        if await trust.isTrusted(canon) {
            return TrustGrantResult(path: canon, granted: true, alreadyTrusted: true)
        }
        let outcome = await grantResolver.requestGrant(
            path: canon, reason: "grant agents write access to \(canon)", source: source)
        guard outcome == .approved else {
            throw OrchestraError.trustDenied(
                "no human approved trust for \(canon) (agents cannot self-grant)")
        }
        _ = try await trust.record(canon, grantedBy: .human)
        emitActivity(.warning, nil, source, "Trusted \(canon) (human grant)")
        return TrustGrantResult(path: canon, granted: true, alreadyTrusted: false)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter GrantTrustTests`
Expected: PASS (3 tests). Also run `--filter TrustLedgerTests --filter ResolveTrustTests` to confirm T1 stayed green.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Errors.swift Sources/OrchestraCore/OrchestraService.swift \
        Tests/OrchestraCoreTests/Stubs.swift Tests/OrchestraCoreTests/TrustGrantTests.swift
git commit -m "feat(t2): OrchestraService.grantTrust + injected grant resolver + trustDenied"
```

---

## Task 3: `trust` Command in the registry (+ parity/expected array)

**Files:**
- Modify: `Sources/OrchestraCore/Commands.swift:196-214` (add the `trust` Command after `batch-spawn`)
- Modify: `Tests/OrchestraCoreTests/CommandsTests.swift:11-13` (add `"trust"` to `expected`)
- Test: `Tests/OrchestraCoreTests/CommandsTests.swift`, `Tests/OrchestraCoreTests/TrustGrantTests.swift`

**Interfaces:**
- Consumes: `OrchestraService.grantTrust`.
- Produces: registry command `"trust"` with param `path` (string, required).

- [ ] **Step 1: Write the failing test**

In `Tests/OrchestraCoreTests/CommandsTests.swift`, extend the `expected` array (line 11-13):
```swift
        let expected = ["list", "spawn", "move", "send", "status", "archive",
                        "restart", "resume", "shell", "inspect", "closeShell", "exec", "sessions", "batch-spawn",
                        "wait", "handoff", "trust"]
```

In `Tests/OrchestraCoreTests/TrustGrantTests.swift`, add a suite exercising the Command:
```swift
@Suite("trust Command — registry dispatch")
struct TrustCommandTests {
    @Test("trust command records via grantTrust when the (surface) source approves")
    func commandGrants() async throws {
        let env = TestEnv.make(grantResolver: StubGrantResolver(.approved))
        let dir = env.base + "/cmd-grant"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cmd = try #require(CommandRegistry().command("trust"))
        let out = try await cmd.run(env.svc, .object(["path": .string(dir)]), .cli)
        #expect(try out.decode(TrustGrantResult.self).granted)
        #expect(await env.trust.isTrusted(dir) == true)
    }

    @Test("trust command surfaces trustDenied when the agent source can't self-grant")
    func commandDenies() async throws {
        let env = TestEnv.make(grantResolver: StubGrantResolver(.denied))
        let dir = env.base + "/cmd-deny"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cmd = try #require(CommandRegistry().command("trust"))
        await #expect(throws: OrchestraError.self) {
            _ = try await cmd.run(env.svc, .object(["path": .string(dir)]), .agent)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter CommandsTests --filter TrustCommandTests`
Expected: FAIL — `fullSet` expects `trust` but the registry lacks it; `command("trust")` is nil.

- [ ] **Step 3: Write minimal implementation**

In `Sources/OrchestraCore/Commands.swift`, add after the `batch-spawn` Command (before the closing `]` of `build()`):
```swift
            Command(name: "trust",
                    summary: "Grant a human's trust for a directory so agents may run there with write "
                        + "access. Requires a human to approve (MCP elicitation / interactive CLI); an "
                        + "agent can only trigger it, never self-grant.",
                    params: schema(["path": strProp("Directory to trust (the card's cwd / repo root)")],
                                   required: ["path"])) { svc, p, src in
                let res = try await svc.grantTrust(try p.string("path"), source: src)
                return try JSONValue(encodable: res)
            },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter CommandsTests --filter TrustCommandTests`
Expected: PASS. `fullSet` now matches; both command tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Commands.swift Tests/OrchestraCoreTests/CommandsTests.swift \
        Tests/OrchestraCoreTests/TrustGrantTests.swift
git commit -m "feat(t2): trust Command in registry (MCP auto; +expected array)"
```

---

## Task 4: Scratch-clones-repo demotes to borrowed (in `resolveTrust`)

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift:96-107` (`resolveTrust` scratch branch + a helper)
- Test: `Tests/OrchestraCoreTests/TrustGrantTests.swift`

**Interfaces:**
- Consumes: `TrustLedger.isTrusted`, `FileManager`.
- Produces: demotion behavior — a `.scratch` origin whose cwd holds a foreign repo (`<cwd>/.git`) is resolved with borrowed semantics (`needsGrant` unless ledgered).

- [ ] **Step 1: Write the failing test**

Add to `Tests/OrchestraCoreTests/TrustGrantTests.swift`:
```swift
@Suite("resolveTrust — scratch external-intake demotion")
struct ScratchDemotionTests {
    @Test("an empty scratch dir still auto-trusts (unchanged)")
    func emptyScratchAutoTrusts() async throws {
        let env = TestEnv.make()
        let cwd = env.base + "/scratch-empty"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        #expect(await env.svc.resolveTrust(origin: .scratch, cwd: cwd, repo: nil) == .trusted)
    }

    @Test("a scratch dir that has become a foreign repo (.git present) demotes to borrowed → needsGrant")
    func clonedScratchDemotes() async throws {
        let env = TestEnv.make()
        let cwd = env.base + "/scratch-cloned"
        try FileManager.default.createDirectory(atPath: cwd + "/.git", withIntermediateDirectories: true)
        #expect(await env.svc.resolveTrust(origin: .scratch, cwd: cwd, repo: nil) == .needsGrant)
        // ...and once a human grants it, it's trusted (re-entered the grant path, didn't auto-trust)
        try await env.trust.record(cwd, grantedBy: .human)
        #expect(await env.svc.resolveTrust(origin: .scratch, cwd: cwd, repo: nil) == .trusted)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter ScratchDemotionTests`
Expected: FAIL — cloned scratch currently auto-trusts (`.trusted`), test wants `.needsGrant`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/OrchestraCore/OrchestraService.swift`, replace the `.scratch` branch of `resolveTrust`:
```swift
        case .scratch:
            // External-intake guard: a scratch dir Orchestra made empty auto-trusts, but if foreign
            // code has since landed in it (a repo cloned in → a `.git`), it is no longer Orchestra's
            // empty dir — demote to BORROWED semantics (re-enter the grant path) rather than auto-
            // trusting someone else's code.
            if Self.scratchHasForeignCode(cwd) {
                return await trust.isTrusted(cwd) ? .trusted : .needsGrant
            }
            _ = try? await trust.record(cwd, grantedBy: .orchestra)
            return .trusted
```
Add a private static helper in the same file (near `resolveTrust`):
```swift
    /// A scratch dir that contains a `.git` holds a cloned/foreign repo — treat it as borrowed.
    static func scratchHasForeignCode(_ cwd: String) -> Bool {
        FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent(".git"))
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter ScratchDemotionTests --filter ResolveTrustTests --filter SpawnTrustRoutingTests`
Expected: PASS — demotion works; T1's `scratchAutoTrusts` / `scratchSpawnRecordsLedger` stay green (their scratch dirs have no `.git`).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Tests/OrchestraCoreTests/TrustGrantTests.swift
git commit -m "feat(t2): scratch-clones-repo demotes to borrowed (re-enter grant path)"
```

---

## Task 5: Untrusted-spawn emits actionable context (needsGrant)

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift:197-214` (spawn: emit an activity when `needsGrant`)
- Test: `Tests/OrchestraCoreTests/TrustGrantTests.swift`

**Interfaces:**
- Consumes: `resolveTrust`, `emitActivity`, `EventCollector`.
- Produces: on a `needsGrant` spawn, a `.warning` activity whose text is actionable (`orchestra trust`, read-only) — the card still spawns (sandboxed, `trustCwd=false`). Autonomy-exempt: never blocks.

- [ ] **Step 1: Write the failing test**

Add to `Tests/OrchestraCoreTests/TrustGrantTests.swift`:
```swift
@Suite("spawn — untrusted (needsGrant) actionable context")
struct UntrustedSpawnTests {
    @Test("borrowed un-ledgered spawn proceeds sandboxed AND emits an actionable needsGrant activity")
    func emitsActionableActivity() async throws {
        let env = TestEnv.make()
        let collector = EventCollector()
        await collector.start(await env.svc.subscribe())
        let dir = env.base + "/borrowed-needsgrant"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let t = try await env.svc.spawn(SpawnInput(prompt: "peek", cwd: dir, access: .readWrite))
        #expect(t.origin == .borrowed)
        #expect(await env.trust.isTrusted(dir) == false)   // still untrusted (no auto-trust, no block)
        // wait a tick for the async event fan-out, then assert an actionable warning was emitted
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        let acts = await collector.activities
        let grant = acts.first { $0.text.contains("orchestra trust") }
        #expect(grant != nil)
        #expect(grant?.text.contains(dir) == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --filter UntrustedSpawnTests`
Expected: FAIL — no activity mentions `orchestra trust` yet.

- [ ] **Step 3: Write minimal implementation**

In `Sources/OrchestraCore/OrchestraService.swift` `spawn`, right after the `emitActivity(.spawned, ...)` line (~line 206), add:
```swift
        // T2: an untrusted cwd (needsGrant) spawns sandboxed (trustCwd=false above) but tells the
        // human how to grant it. Autonomy-exempt: this never blocks the spawn — the card just runs
        // read-only-ish until a human runs `orchestra trust`.
        if trustDecision == .needsGrant {
            emitActivity(.warning, created, source,
                "“\(title)” runs untrusted (sandboxed) in \(cwd). To grant write trust, run "
                + "`orchestra trust \(cwd)` in a terminal, or keep it read-only.")
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --filter UntrustedSpawnTests --filter SpawnTrustRoutingTests`
Expected: PASS — activity emitted; T1 `borrowedSpawnNoAutoTrust` still green (spawn still succeeds untrusted).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Tests/OrchestraCoreTests/TrustGrantTests.swift
git commit -m "feat(t2): untrusted spawn emits actionable needsGrant context"
```

---

## Task 6: CLI `orchestra trust` verb (isatty split)

**Files:**
- Modify: `Sources/orchestra/CLIRunner.swift:16-140` (add the `trust` case)
- Modify: `Sources/orchestra/CLIHelp.swift` (one help line)
- Test: covered by the pure `TrustPrompt` tests (Task 1) + an IntegrationTests smoke (Task 8). No new core test here — the isatty wiring is thin glue.

**Interfaces:**
- Consumes: `TrustPrompt.isAffirmative`, `TrustPrompt.nonInteractiveHelp`, the daemon `trust` command.
- Produces: `orchestra trust <path>` — interactive-only; non-interactive → actionable failure (exit 1), no `--trust` flag.

- [ ] **Step 1: Add the verb (no separate failing unit test — logic lives in Task 1's tested helpers)**

In `Sources/orchestra/CLIRunner.swift`, add a case (e.g. after `"send"`):
```swift
            case "trust":
                // Human-only grant. There is NO --trust flag: trust is a decision a human makes at a
                // tty (or via the MCP elicitation dialog), never a switch an agent can pass.
                let rawPath = flags.positional(0) ?? flags.require("path")
                let path = PathResolver.canonical(rawPath)
                guard isatty(FileHandle.standardInput.fileDescriptor) != 0 else {
                    die(TrustPrompt.nonInteractiveHelp(path))   // exits 1
                }
                FileHandle.standardError.write(Data(
                    "Grant agents write trust for \(path)? [y/N] ".utf8))
                guard TrustPrompt.isAffirmative(readLine()) else {
                    die("trust: declined — \(path) stays untrusted")
                }
                let r = try await client.call("trust", .object(["path": .string(path)]))
                if try r.decode(TrustGrantResult.self).granted { print("trusted \(path)") }
```

Note: `die(_)` writes to stderr and calls `exit(1)` (existing helper). `PathResolver` and `TrustGrantResult` come from `OrchestraCore` (already `import`ed at file top).

- [ ] **Step 2: Add the help line**

In `Sources/orchestra/CLIHelp.swift`, add under COMMANDS (after `send`):
```
      trust <path>                               Grant a human's write-trust for a dir (interactive only)
```

- [ ] **Step 3: Build to verify it compiles**

Run: `./scripts/test.sh --filter CommandsTests` (forces a full build of the `orchestra` target via the test build).
Expected: builds clean; PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/orchestra/CLIRunner.swift Sources/orchestra/CLIHelp.swift
git commit -m "feat(t2): orchestra trust CLI verb (isatty-gated, no --trust flag)"
```

---

## Task 7: MCP `trust` tool → `requestElicitation` grant path

**Files:**
- Modify: `Sources/orchestra-mcp/main.swift:36-53` (special-case the `trust` tool in `CallTool`)
- Test: none automated (O7 — no live MCP client; the real dialog is manual). Build-verified only.

**Interfaces:**
- Consumes: `Server.requestElicitation(message:requestedSchema:)` → `CreateElicitation.Result` with `.action ∈ {accept, decline, cancel}`; `validateClientCapability(\.elicitation, ...)` (thrown by the SDK if the client didn't advertise `elicitation` — no fallback, per design).
- Produces: an elicitation-gated `trust` tool: relay to the daemon only on `.accept`.

- [ ] **Step 1: Special-case `trust` in the CallTool handler**

In `Sources/orchestra-mcp/main.swift`, inside the `CallTool` handler, BEFORE the generic relay (`let result = try await client.call(...)`), insert:
```swift
    // The `trust` tool is the ONE human-gated command: elicit a decision from the agent's own MCP
    // client (a human answers there — the agent can only trigger it) and relay to the daemon only on
    // accept. `requestElicitation` throws if the client never advertised `elicitation`; both v1
    // targets (Claude Code, Codex) do, so there is no fallback here (design §4.1).
    if params.name == "trust" {
        let path = argsToJSON(params.arguments).optString("path") ?? "this directory"
        do {
            let elicit = try await server.requestElicitation(
                message: "An agent is requesting write-trust for \(path). Approve so agents may run "
                    + "there with write access?",
                requestedSchema: .init())
            guard elicit.action == .accept else {
                return CallTool.Result(
                    content: [.text(text: "trust declined by the human", annotations: nil, _meta: nil)],
                    isError: true)
            }
        } catch {
            return CallTool.Result(
                content: [.text(text: "trust elicitation failed: \(error)", annotations: nil, _meta: nil)],
                isError: true)
        }
    }
```
The generic relay below then forwards the `trust` call to the daemon (which records via `grantTrust`; the daemon's `SurfaceGrantResolver` approves `.mcp`). Ordering: the elicitation IS the human gate; the daemon record is the effect of the accept.

- [ ] **Step 2: Build to verify it compiles**

Run (unsandboxed): `swift build` (or `./scripts/typecheck-app.sh` builds the whole graph incl. `orchestra-mcp`).
Expected: compiles. `requestElicitation`, `Elicitation.RequestSchema.init()`, and `.action == .accept` all resolve against the pinned swift-sdk.

- [ ] **Step 3: Commit**

```bash
git add Sources/orchestra-mcp/main.swift
git commit -m "feat(t2): MCP trust tool gated on requestElicitation (no fallback)"
```

---

## Task 8: Integration smoke — non-interactive CLI `trust` fails (no daemon needed)

**Files:**
- Modify: `Tests/IntegrationTests/E2EBinaryTests.swift` (add one smoke test)
- Test: `Tests/IntegrationTests/E2EBinaryTests.swift`

**Interfaces:**
- Consumes: the built `orchestra` binary (via `IntegrationSupport`'s binary-locating helper — mirror an existing test's launch).
- Produces: proof the isatty gate fails closed with actionable text before any daemon call.

- [ ] **Step 1: Read the existing harness to mirror its binary-run pattern**

Run: (open `Tests/IntegrationTests/E2EBinaryTests.swift` + `IntegrationSupport.swift`) — find how a test resolves and runs the `orchestra` binary with a pipe. Reuse that helper verbatim (do not invent a new launcher).

- [ ] **Step 2: Write the failing test**

Add to `E2EBinaryTests.swift` (adapt the run helper name to the file's actual one):
```swift
    @Test("CLI: `orchestra trust <path>` with a non-tty stdin fails closed with actionable text")
    func trustNonInteractiveFails() async throws {
        // stdin is a pipe here (not a tty) → isatty is false → the verb must refuse BEFORE any daemon
        // call, so no daemon is needed. Exit non-zero, message names the path and no `--trust` flag.
        let (status, _, err) = try runOrchestra(["trust", "/tmp/some-untrusted-dir"], stdin: "")
        #expect(status != 0)
        #expect(err.contains("/tmp/some-untrusted-dir"))
        #expect(err.contains("interactive terminal"))
        #expect(!err.contains("--trust"))
    }
```
If the existing harness has no `runOrchestra(_:stdin:)` returning `(status, stdout, stderr)`, use whatever equivalent exists (e.g. a `Proc`/`Process` helper already in `IntegrationSupport.swift`); the assertion content is what matters.

- [ ] **Step 3: Run test to verify it fails, then passes**

Run: `./scripts/test.sh --filter trustNonInteractiveFails`
Expected: after Task 6's verb exists, PASS. (If it fails to find the binary, the harness helper name is wrong — fix the call, not the verb.)

- [ ] **Step 4: Commit**

```bash
git add Tests/IntegrationTests/E2EBinaryTests.swift
git commit -m "test(t2): CLI trust non-interactive fails closed (integration smoke)"
```

> If the IntegrationTests harness makes a clean non-tty binary run awkward (no reusable helper), SKIP this task — the isatty gate's decision logic is already unit-tested via `TrustPrompt` (Task 1), and the verb is thin glue. Note the skip in the final report rather than fighting the harness.

---

## Task 9: Full green + docs record-back

**Files:**
- Modify: `notes/designs/agent-provider-interface/03-implementation.md` (T2 row → as-built), `04-tests.md` (Trust grant row → as-built), `02-contract.md` (`OrchestraService.trust` contract → as-built symbol names)

- [ ] **Step 1: Full suite green**

Run (unsandboxed): `./scripts/test.sh`
Expected: all green. If the ONLY failure is `no SessionStart callback in 2s`, re-run that test in isolation (`--filter`) to confirm it's the known flake, then treat green.

- [ ] **Step 2: App typecheck green**

Run: `./scripts/typecheck-app.sh`
Expected: clean (T2 adds no app/UI code, so this should be unaffected — it's the required gate, not a smoke for new UI).

- [ ] **Step 3: Record as-built into the planning docs (merge-gate hygiene, per DoD)**

Update the T2 row in `03-implementation.md` and the "Trust grant (human-only)" row in `04-tests.md` with the shipped symbol names: `TrustGrantResolver`/`SurfaceGrantResolver`/`TrustGrantOutcome`, `OrchestraService.grantTrust(_:source:)`, `TrustGrantResult`, `TrustPrompt`, `OrchestraError.trustDenied`, the `trust` Command, the CLI `trust` verb, the scratch `.git` demotion, and the MCP `requestElicitation` special-case. (The authoritative `docs/` chapters `05`/`06`/`09` are auto-synced on merge to `main`; this step keeps the sync's INPUT truthful.)

- [ ] **Step 4: Commit**

```bash
git add notes/designs/agent-provider-interface/
git commit -m "docs(t2): record as-built trust grant surfaces in the layer docs"
```

- [ ] **Step 5: Move to review (do NOT merge/archive)**

Move this card to `review` and report `DONE: trust/02-grant-surfaces — tests green` + a one-liner. The orchestrator merges.

---

## Self-Review

**1. Spec coverage** (T2 scope + `04-tests` "Trust grant (human-only)" row):
- `trust` Command (MCP+CLI) → Tasks 3, 6, 7. ✓
- `orchestra trust` CLI, isatty split, non-interactive fail, no `--trust` → Tasks 6, 8; `TrustPrompt` (Task 1). ✓
- Untrusted-spawn human-grant / actionable context → Task 5. ✓
- MCP `requestElicitation` gated on client `elicitation` (no fallback) → Task 7 (SDK's `validateClientCapability` enforces the gate; both v1 targets advertise it). ✓
- autonomy-exemption → `SurfaceGrantResolver` denies `.agent`/`.daemon` (Task 1) + spawn never blocks (Task 5). ✓
- agent/trust-tool can't self-grant (→ deny) → Tasks 2, 3 (deny fixtures). ✓
- interactive grant records + mirrors native flag → Task 2 (`approvedRecords` asserts record + `resolveTrust`→trusted; the native mirror itself is T1-tested in `ClaudeApplyTrustTests`). ✓
- scratch-clones-repo demotes to borrowed → Task 4. ✓
- `expected` array + CLIRunner case (CRITICAL) → Task 3 (expected) + Task 6 (verb). ✓
- Stub grant resolver only; no live MCP/`USE_REAL_CLAUDE` (O7) → all core tests inject `StubGrantResolver`; Task 7 has no automated test. ✓

**2. Placeholder scan:** every code step shows complete code. Task 8 is explicitly optional with a documented skip path (harness-dependent). No TBDs.

**3. Type consistency:** `TrustGrantOutcome{approved,denied}`, `TrustGrantResolver.requestGrant(path:reason:source:)`, `SurfaceGrantResolver`, `TrustGrantResult{path,granted,alreadyTrusted}`, `TrustPrompt.isAffirmative/nonInteractiveHelp`, `OrchestraService.grantTrust(_:source:)`, `OrchestraError.trustDenied` — all spelled identically across tasks. `TestEnv.make(grantResolver:)` and `OrchestraService.init(grantResolver:)` match. The `trust` ledger property (`let trust: TrustLedger`) and the `grantTrust` method do NOT collide (distinct names) — deliberate.

**Ordering / conflict note (O3/O4):** D1 is already merged to `main` (also-needs satisfied). Both D1 and T2 add a `CLIRunner` case + a `Command`; since D1 landed first, T2 appends after it — no concurrent same-construct merge. The registry↔MCP parity test (`E2EBinaryTests`) guards the tool surface automatically.
