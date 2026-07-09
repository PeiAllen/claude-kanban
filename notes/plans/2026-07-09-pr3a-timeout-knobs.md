# PR3a — Timeout Knobs + Bounded WorktreeManager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three additive-optional wall-clock timeout knobs to `Config`, then bound **every** `git` invocation in `WorktreeManager` with them so no unbounded `Proc.run` can hang the daemon.

**Architecture:** Pure additive bounding — no behavior change on the happy path. `Config` gains `worktreeAddTimeout`/`sessionLaunchTimeout`/`controlTimeout` (Int seconds, defaulted) decoded via a small custom `init(from:)` so a pre-upgrade `config.json` lacking the keys still decodes. `WorktreeManager` routes its `Proc.run` calls through a tiny injectable `run` seam (default = `Proc.run`) so the timeout argument is deterministically assertable in a unit test; `git worktree add` (a checkout) gets the generous `worktreeAddTimeout`, every other git op gets `controlTimeout`. `Proc.run`'s existing wall-clock `timeout:` is the enforcement primitive — **`Proc` is not touched**.

**Tech Stack:** Swift (swift-testing / `swift test`), `Duration`, git worktrees, `Proc.run`.

**Companion spec + vault:** `notes/plans/2026-07-08-card-lifecycle-convergence.md` (Stage 3, Tasks 3.1–3.2) and `notes/designs/lifecycle-convergence/` (01-design … 05-pr-tree). This is **PR3a**; the `WorktreeRegistry` actor, markers, release policy, and persisted borrows are **PR3b (3.3–3.6)** and are explicitly out of scope.

## Global Constraints

- **Scope is 3.1–3.2 ONLY.** Do **not** build `WorktreeRegistry`, markers, release policy, persisted borrows, or Task-3.6 docs. Those are PR3b.
- **Agent-agnostic.** No `if agentId == …` anywhere (this stage is agent-neutral regardless).
- **Additive-optional Config.** An existing `config.json` lacking the three new keys MUST still decode, keeping the defaults (`test_configForwardCompat` gates this).
- **No `Proc` changes.** `Proc.run`'s `timeout: Duration?` is the enforcement primitive.
- **No unbounded `Proc.run` may remain in `WorktreeManager.swift`** after Task 3.2.
- **`swift test` green after every task**, both runners (`OrchestraCoreTests` unit + `IntegrationTests`).
- **Fold any deviation into the vault** ("Decisions made" tables) and mention it in the merge-request.
- **Exact defaults:** `worktreeAddTimeout` = **600s**, `sessionLaunchTimeout` = **30s**, `controlTimeout` = **15s**.
- **Exact test names:** `test_configTimeoutDefaults`, `test_configForwardCompat`, `test_worktreeAddIsBounded`, `test_pruneIsBounded`, `test_worktreeAddTimesOut`.

## Deviations from the plan's stated anchors (verified in this worktree, fold into vault)

1. **`Config.swift` lives in `Sources/OrchestraKit/`, not `Sources/OrchestraCore/`** (the Stage-3 file table and the Task-3.1 header say `Sources/OrchestraCore/Config.swift`; the actual file is `Sources/OrchestraKit/Config.swift`). `OrchestraCore` already imports `OrchestraKit`, so `WorktreeManager` sees `config.worktreeAddTimeout` with no new import.
2. **The `git worktree add` invocations at "`:39`/`:41`" both funnel into a single `Proc.run(argv)`** at `WorktreeManager.swift:65` (`:39`/`:41` only *build* the argv). There is a **second** `git worktree add` in `borrow()` at `:102`. Both adds get `worktreeAddTimeout` (both are checkouts). The fallback prune is at `:146`.
3. **Timeout assignment (fail-safe reading of "add invocations vs borrow ops"):** *every* `git worktree add` (ensure `:65` **and** borrow `:102`) gets `worktreeAddTimeout` — a borrow's `worktree add` is a full checkout, so bounding it at `controlTimeout` (15s) would risk a false timeout on a large repo; the generous 600s is correct. `controlTimeout` covers the non-checkout ops: `worktree list` (`:124`), `worktree remove` (`:143`), the fallback `worktree prune` (`:146`), and the `rev-parse`/`status --porcelain` query helpers (`:154`/`:160`/`:167`). `sessionLaunchTimeout` is **not consumed in this file** — it is additive config for the Stage-4 session/stepper layer.
4. **Test file names:** config tests in `Tests/OrchestraCoreTests/ConfigTimeoutTests.swift` (the parent plan header said `ProcTimeoutTests.swift`, but the content tests `Config`, not `Proc` — both reviewers flagged the "Proc" name as misleading, so this file is renamed for clarity); bounded-git tests in `Tests/OrchestraCoreTests/WorktreeTests.swift`. Both are unit tests — the runner seam makes them deterministic with no real git.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/OrchestraKit/Config.swift` | Add 3 Int-seconds timeout knobs + custom `init(from:)` for additive-optional decode | 3.1 |
| `Tests/OrchestraCoreTests/ConfigTimeoutTests.swift` (new) | `test_configTimeoutDefaults`, `test_configForwardCompat` | 3.1 |
| `Sources/OrchestraCore/WorktreeManager.swift` | Injectable `run` seam; pass timeouts to all 8 `Proc.run` sites | 3.2 |
| `Tests/OrchestraCoreTests/WorktreeTests.swift` (new) | `test_worktreeAddIsBounded`, `test_pruneIsBounded`, `test_worktreeAddTimesOut` | 3.2 |

---

## Task 3.1: Timeout Config knobs (additive-optional)

**Files:**
- Modify: `Sources/OrchestraKit/Config.swift` (struct fields `:16-24`, memberwise `init` `:26-46`)
- Test: `Tests/OrchestraCoreTests/ConfigTimeoutTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `Config.worktreeAddTimeout: Int` (600), `Config.sessionLaunchTimeout: Int` (30), `Config.controlTimeout: Int` (15) — Int **seconds**, matching the existing `revivalGraceSeconds: Int` convention; JSON-friendly (a hand-edited `config.json` can set a bare number, which `Duration`'s Codable could not accept). Task 3.2 consumes `worktreeAddTimeout` + `controlTimeout`.

> **Why a custom `init(from:)` is required:** Swift's *synthesized* `Codable` calls `container.decode(_:forKey:)` (not `decodeIfPresent`) for every **non-optional** stored property, which **throws `keyNotFound`** when the key is absent. A pre-upgrade `config.json` has none of the three new keys, so synthesized decode would fail — breaking Allen's live board on upgrade. The fix is a hand-written `init(from:)` that `decodeIfPresent(...) ?? default` for the three new keys (existing keys keep their current required-decode semantics). `encode(to:)` stays synthesized (Swift synthesizes the half you don't provide, using the declared `CodingKeys`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/ConfigTimeoutTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraKit

@Suite("Config — timeout knobs (3.1)")
struct ConfigTimeoutTests {

    @Test("timeout knobs default to 600/30/15 and are overridable")
    func test_configTimeoutDefaults() throws {
        let d = Config()
        #expect(d.worktreeAddTimeout == 600)
        #expect(d.sessionLaunchTimeout == 30)
        #expect(d.controlTimeout == 15)

        let custom = Config(worktreeAddTimeout: 5, sessionLaunchTimeout: 6, controlTimeout: 7)
        #expect(custom.worktreeAddTimeout == 5)
        #expect(custom.sessionLaunchTimeout == 6)
        #expect(custom.controlTimeout == 7)

        // round-trips through Codable
        let data = try JSONEncoder().encode(custom)
        let back = try JSONDecoder().decode(Config.self, from: data)
        #expect(back == custom)
    }

    @Test("a config.json without the new keys still decodes, keeping defaults")
    func test_configForwardCompat() throws {
        // A pre-upgrade config.json with NONE of the three new keys.
        let legacy = """
        {
          "reposRoot": "/r",
          "worktreesRoot": "/w",
          "defaultAgentId": "claude-code",
          "allowlist": [],
          "maxConcurrentRevivals": 4,
          "revivalGraceSeconds": 15,
          "statusLineMode": "passthroughGlobal"
        }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(Config.self, from: legacy)
        #expect(c.worktreeAddTimeout == 600)
        #expect(c.sessionLaunchTimeout == 30)
        #expect(c.controlTimeout == 15)
        // existing fields survived
        #expect(c.reposRoot == "/r")
        #expect(c.worktreesRoot == "/w")

        // and a config.json that DOES set one new key keeps that override
        let withOne = """
        {
          "reposRoot": "/r", "worktreesRoot": "/w", "defaultAgentId": "claude-code",
          "allowlist": [], "maxConcurrentRevivals": 4, "revivalGraceSeconds": 15,
          "statusLineMode": "passthroughGlobal", "controlTimeout": 3
        }
        """.data(using: .utf8)!
        let c2 = try JSONDecoder().decode(Config.self, from: withOne)
        #expect(c2.controlTimeout == 3)
        #expect(c2.worktreeAddTimeout == 600)   // the unset ones still default
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ConfigTimeoutTests`
Expected: FAIL to **compile** (`Config` has no `worktreeAddTimeout` member / no such init parameter). A compile-fail is a valid red.

- [ ] **Step 3: Implement the knobs + custom decode**

In `Sources/OrchestraKit/Config.swift`, add the three stored properties after `customStatusLine` (`:24`):

```swift
    public var customStatusLine: String?

    /// Wall-clock bound (seconds) for a `git worktree add` checkout — generous because a cold
    /// large-repo checkout can take several seconds (worst known ≈9s). Enforced via `Proc.run(timeout:)`.
    public var worktreeAddTimeout: Int
    /// Wall-clock bound (seconds) for launching an agent session. Consumed by the Stage-4 session layer.
    public var sessionLaunchTimeout: Int
    /// Wall-clock bound (seconds) for fast control ops — tmux control verbs + fast git queries
    /// (`worktree list/remove/prune`, `rev-parse`, `status --porcelain`).
    public var controlTimeout: Int
```

Add the three defaulted parameters to the memberwise `init` (`:26-46`) — append after `customStatusLine`:

```swift
        statusLineMode: StatusLineMode = .passthroughGlobal,
        customStatusLine: String? = nil,
        worktreeAddTimeout: Int = 600,
        sessionLaunchTimeout: Int = 30,
        controlTimeout: Int = 15
    ) {
        self.reposRoot = reposRoot
        self.worktreesRoot = worktreesRoot
        self.defaultModel = defaultModel
        self.defaultAgentId = defaultAgentId
        self.allowlist = allowlist
        self.maxConcurrentRevivals = maxConcurrentRevivals
        self.revivalGraceSeconds = revivalGraceSeconds
        self.statusLineMode = statusLineMode
        self.customStatusLine = customStatusLine
        self.worktreeAddTimeout = worktreeAddTimeout
        self.sessionLaunchTimeout = sessionLaunchTimeout
        self.controlTimeout = controlTimeout
    }
```

Add an explicit `CodingKeys` + custom `init(from:)` immediately after the memberwise `init` (before `// MARK: Defaults`). Existing keys keep required-decode semantics (optionals use `decodeIfPresent`, exactly as synthesized); the three new keys default when absent:

```swift
    private enum CodingKeys: String, CodingKey {
        case reposRoot, worktreesRoot, defaultModel, defaultAgentId, allowlist,
             maxConcurrentRevivals, revivalGraceSeconds, statusLineMode, customStatusLine,
             worktreeAddTimeout, sessionLaunchTimeout, controlTimeout
    }

    /// Custom decode so a pre-upgrade `config.json` lacking the new timeout keys still decodes,
    /// falling back to the defaults (the three knobs are additive-optional). `encode(to:)` stays
    /// synthesized. Existing keys keep their current required-decode semantics.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reposRoot = try c.decode(String.self, forKey: .reposRoot)
        worktreesRoot = try c.decode(String.self, forKey: .worktreesRoot)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        defaultAgentId = try c.decode(String.self, forKey: .defaultAgentId)
        allowlist = try c.decode([String].self, forKey: .allowlist)
        maxConcurrentRevivals = try c.decode(Int.self, forKey: .maxConcurrentRevivals)
        revivalGraceSeconds = try c.decode(Int.self, forKey: .revivalGraceSeconds)
        statusLineMode = try c.decode(StatusLineMode.self, forKey: .statusLineMode)
        customStatusLine = try c.decodeIfPresent(String.self, forKey: .customStatusLine)
        worktreeAddTimeout = try c.decodeIfPresent(Int.self, forKey: .worktreeAddTimeout) ?? 600
        sessionLaunchTimeout = try c.decodeIfPresent(Int.self, forKey: .sessionLaunchTimeout) ?? 30
        controlTimeout = try c.decodeIfPresent(Int.self, forKey: .controlTimeout) ?? 15
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ConfigTimeoutTests`
Expected: PASS (both tests).

- [ ] **Step 5: Full suite green**

Run: `swift test`
Expected: green (no existing test constructs `Config` positionally past `customStatusLine`, so the appended defaulted params are source-compatible; the custom `init(from:)` preserves existing decode behavior for all existing keys).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraKit/Config.swift Tests/OrchestraCoreTests/ConfigTimeoutTests.swift
git commit -m "feat(config): launch/checkout/control timeout knobs (additive-optional)"
```

---

## Task 3.2: Bound every `WorktreeManager` git invocation

**Files:**
- Modify: `Sources/OrchestraCore/WorktreeManager.swift` (init `:9-12`; the 8 `Proc.run` sites at `:65,:102,:124,:143,:146,:154,:160,:167`)
- Test: `Tests/OrchestraCoreTests/WorktreeTests.swift` (create)

**Interfaces:**
- Consumes: `Config.worktreeAddTimeout`, `Config.controlTimeout` (Task 3.1).
- Produces: `WorktreeManager` gains an internal injectable runner:
  `let run: @Sendable (_ argv: [String], _ timeout: Duration) throws -> ProcResult` (default = `{ try Proc.run($0, timeout: $1) }`), settable via an internal `init(config:resolver:run:)` for tests. Public API (`ensure`/`borrow`/`remove`/`path`/…) is unchanged.

> **Why the runner seam:** the mandated tests assert that the add/prune are *invoked with a timeout* (a bounded successful add is behaviorally identical to an unbounded one, so this can't be observed without intercepting the call). A tiny injectable closure — defaulting to `Proc.run` — lets a unit test record `(argv, timeout)` deterministically with no real git and no `Proc` change. `WorktreeManager` never passes `cwd`/`env` to `Proc.run` (all git ops use `-C`), so a 2-arg seam suffices.
>
> **The `timeout` is non-optional `Duration` (not `Duration?`).** `Proc.run`'s param is `Duration?`, but after PR3a there is *no* legitimate unbounded call in this file, so the seam takes a required `Duration` — an unbounded git op becomes a **type error**, hardening the "no unbounded `Proc.run`" invariant beyond what a test can check. The default closure forwards the non-optional `Duration` into `Proc.run(timeout:)` (implicit optional promotion). `Proc` is untouched.

- [ ] **Step 1: Write the failing tests**

Create `Tests/OrchestraCoreTests/WorktreeTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

@Suite("WorktreeManager — bounded git (3.2)")
struct WorktreeBoundedTests {

    /// Records every (argv, timeout) the manager runs, and returns a canned result per argv.
    /// `timeout` is a non-optional `Duration` (the seam forbids unbounded git by type).
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(argv: [String], timeout: Duration)] = []
        var respond: @Sendable (_ argv: [String]) -> ProcResult
        init(respond: @escaping @Sendable (_ argv: [String]) -> ProcResult) { self.respond = respond }
        func run(_ argv: [String], _ timeout: Duration) throws -> ProcResult {
            lock.lock(); _calls.append((argv, timeout)); lock.unlock()
            return respond(argv)
        }
        var calls: [(argv: [String], timeout: Duration)] { lock.lock(); defer { lock.unlock() }; return _calls }
        func first(where pred: ([String]) -> Bool) -> (argv: [String], timeout: Duration)? {
            calls.first { pred($0.argv) }
        }
    }

    // `static` so they can be referenced from `@Sendable` respond closures without capturing `self`.
    static func ok(_ stdout: String = "") -> ProcResult { ProcResult(stdout: stdout, stderr: "", exitCode: 0) }
    static func fail(_ stderr: String) -> ProcResult { ProcResult(stdout: "", stderr: stderr, exitCode: 1) }
    static func isAdd(_ argv: [String]) -> Bool { argv.contains("worktree") && argv.contains("add") }
    static func isRemove(_ argv: [String]) -> Bool { argv.contains("worktree") && argv.contains("remove") }
    static func isPrune(_ argv: [String]) -> Bool { argv.contains("worktree") && argv.contains("prune") }

    /// A unique base under the temp dir + its allowlisted roots. Caller passes `cleanup` to a
    /// `defer` so the unit tests don't leak dirs (mirrors IntegrationSupport.tempDir hygiene).
    private func config() -> (cfg: Config, cleanup: () -> Void) {
        let base = NSTemporaryDirectory() + "wt-bound-\(UUID().uuidString)"
        let cfg = Config(reposRoot: base, worktreesRoot: base + "/wt",
                         allowlist: [base, base + "/wt"],
                         worktreeAddTimeout: 600, controlTimeout: 15)
        return (cfg, { try? FileManager.default.removeItem(atPath: base) })
    }

    /// Drive one code path with `branchExists` controlling the `rev-parse` probe, then assert its
    /// recorded `worktree add` carried `worktreeAddTimeout`. (Wrapping `rec.run` in a closure literal
    /// makes it reliably inferred `@Sendable`.)
    private func assertAddBounded(branchExists: Bool,
                                  _ drive: (WorktreeManager, Config) throws -> Void) throws {
        let (cfg, cleanup) = config(); defer { cleanup() }
        let rec = Recorder { argv in
            if argv.contains("rev-parse") { return branchExists ? Self.ok() : Self.fail("no branch") }
            return Self.ok()   // everything else (incl. the add) succeeds
        }
        let wm = WorktreeManager(config: cfg, resolver: nil, run: { try rec.run($0, $1) })
        try drive(wm, cfg)
        let add = try #require(rec.first(where: Self.isAdd))
        #expect(add.timeout == .seconds(cfg.worktreeAddTimeout))   // 600s
    }

    @Test("every `git worktree add` — ensure(new), ensure(existing), borrow — is bounded by worktreeAddTimeout")
    func test_worktreeAddIsBounded() throws {
        // ensure, NEW branch: rev-parse fails → `-b` add (WorktreeManager.swift:41→65)
        try assertAddBounded(branchExists: false) { wm, cfg in
            _ = try wm.ensure(repo: cfg.reposRoot, branch: "feat-new")
        }
        // ensure, EXISTING branch: rev-parse ok → existing-branch add (WorktreeManager.swift:39→65)
        try assertAddBounded(branchExists: true) { wm, cfg in
            _ = try wm.ensure(repo: cfg.reposRoot, branch: "feat-existing")
        }
        // borrow: branch must exist → borrow add (WorktreeManager.swift:102)
        try assertAddBounded(branchExists: true) { wm, cfg in
            _ = try wm.borrow(repo: cfg.reposRoot, branch: "feat-borrow")
        }
    }

    @Test("the `worktree remove` and its fallback `worktree prune` are bounded by controlTimeout")
    func test_pruneIsBounded() throws {
        let (cfg, cleanup) = config(); defer { cleanup() }
        // Make a real dir so remove() passes its fileExists guard, then have the stub delete it
        // when it sees `worktree remove` and return non-ok → the fallback prune fires; the dir is
        // then gone so remove() returns without throwing.
        let wt = cfg.worktreesRoot + "/repo/victim"
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        let rec = Recorder { argv in
            if Self.isRemove(argv) {
                try? FileManager.default.removeItem(atPath: wt)   // dir gone after the remove attempt
                return Self.fail("remove failed")
            }
            return Self.ok()
        }
        let wm = WorktreeManager(config: cfg, resolver: nil, run: { try rec.run($0, $1) })
        try wm.remove(worktree: wt, force: true)   // force skips the isDirty status query

        let removeCall = try #require(rec.first(where: Self.isRemove))
        #expect(removeCall.timeout == .seconds(cfg.controlTimeout))   // the `worktree remove` itself, 15s
        let prune = try #require(rec.first(where: Self.isPrune))
        #expect(prune.timeout == .seconds(cfg.controlTimeout))        // the fallback prune, 15s
    }

    // Real wall-clock enforcement lives in `Proc.run(timeout:)` (covered by Proc's own tests) and
    // `Proc` is untouched here (constraint). So this proves the two things WorktreeManager is
    // responsible for: (1) the add is invoked WITH `worktreeAddTimeout`, and (2) a timeout-shaped
    // failure — the non-ok result `Proc.run` returns after it SIGTERMs a process that blew the wall
    // clock — is surfaced as a thrown error instead of a hang. Not just generic error propagation:
    // it asserts the bound was actually passed on the timing-out call.
    @Test("a bounded add whose bound trips surfaces as a throw (not a hang), and the add was bounded")
    func test_worktreeAddTimesOut() throws {
        let (cfg, cleanup) = config(); defer { cleanup() }
        let rec = Recorder { argv in
            if argv.contains("rev-parse") { return Self.fail("no branch") }
            if Self.isAdd(argv) { return ProcResult(stdout: "", stderr: "terminated: timed out", exitCode: 15) }
            return Self.ok()
        }
        let wm = WorktreeManager(config: cfg, resolver: nil, run: { try rec.run($0, $1) })
        #expect(throws: OrchestraError.self) {
            try wm.ensure(repo: cfg.reposRoot, branch: "slow")
        }
        let add = try #require(rec.first(where: Self.isAdd))
        #expect(add.timeout == .seconds(cfg.worktreeAddTimeout))   // the timing-out add WAS bounded
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WorktreeBoundedTests`
Expected: FAIL to **compile** (no `init(config:resolver:run:)`; no `run` seam). Valid red.

- [ ] **Step 3: Implement the seam + pass timeouts**

In `Sources/OrchestraCore/WorktreeManager.swift`, add the stored seam + two inits — replace the existing `let config` / `let resolver` declarations (`:6-7`) and the single `public init` (`:9-12`) with this block:

```swift
    let config: Config
    let resolver: PathResolver
    /// Runs git via `Proc.run` by default; injectable so tests can assert the timeout argument
    /// deterministically. `timeout` is a REQUIRED `Duration` — there is no legitimate unbounded git
    /// op in this file, so an unbounded call is a compile error. WorktreeManager never needs cwd/env
    /// (all git ops use `-C`).
    let run: @Sendable (_ argv: [String], _ timeout: Duration) throws -> ProcResult

    public init(config: Config, resolver: PathResolver? = nil) {
        self.init(config: config, resolver: resolver, run: { try Proc.run($0, timeout: $1) })
    }

    init(config: Config, resolver: PathResolver?,
         run: @escaping @Sendable (_ argv: [String], _ timeout: Duration) throws -> ProcResult) {
        self.config = config
        self.resolver = resolver ?? PathResolver(config: config)
        self.run = run
    }
```

Then replace all 8 `Proc.run(...)` call sites with `run(...)` + the right timeout:

| Site | Before | After |
|---|---|---|
| `:65` ensure add | `try Proc.run(argv)` | `try run(argv, .seconds(config.worktreeAddTimeout))` |
| `:102` borrow add | `try Proc.run(["git","-C",realRepo,"worktree","add",wt,branch])` | `try run(["git","-C",realRepo,"worktree","add",wt,branch], .seconds(config.worktreeAddTimeout))` |
| `:124` borrow-sweep `worktree list --porcelain` | `try? Proc.run(["git","-C",realRepo,"worktree","list","--porcelain"])` | `try? run(["git","-C",realRepo,"worktree","list","--porcelain"], .seconds(config.controlTimeout))` |
| `:143` remove | `try Proc.run(argv)` | `try run(argv, .seconds(config.controlTimeout))` |
| `:146` fallback prune | `try? Proc.run(["git","-C",worktree,"worktree","prune"])` | `try? run(["git","-C",worktree,"worktree","prune"], .seconds(config.controlTimeout))` |
| `:154` branchExists | `try? Proc.run(["git","-C",repo,"rev-parse","--verify","--quiet","refs/heads/\(branch)"])` | `try? run(["git","-C",repo,"rev-parse","--verify","--quiet","refs/heads/\(branch)"], .seconds(config.controlTimeout))` |
| `:160` refExists | `try? Proc.run(["git","-C",repo,"rev-parse","--verify","--quiet",ref])` | `try? run(["git","-C",repo,"rev-parse","--verify","--quiet",ref], .seconds(config.controlTimeout))` |
| `:167` isDirty | `try? Proc.run(["git","-C",worktree,"status","--porcelain"])` | `try? run(["git","-C",worktree,"status","--porcelain"], .seconds(config.controlTimeout))` |

After editing, verify the ONLY `Proc.run` **call** left is the bounded default seam (every production git call now goes through `run(...)`). Match the call *expression* `Proc.run(`, not the bare token — the seam's doc comment mentions `Proc.run` in prose and must not count:

```bash
grep -nF "Proc.run(" Sources/OrchestraCore/WorktreeManager.swift
```
Expected: **exactly one** line — the default seam inside `public init`, `run: { try Proc.run($0, timeout: $1) }` — and it forwards the `timeout:`. Any *other* `Proc.run(` line means a production call site was missed. (The seam's `timeout` being a non-optional `Duration` additionally makes an unbounded `run(...)` call a compile error, so the eight call sites are bound-checked by the type system too.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter WorktreeBoundedTests`
Expected: PASS (all three).

- [ ] **Step 5: Full suite green**

Run: `swift test`
Expected: green — including the existing real-git `Tests/IntegrationTests/WorktreeManagerTests.swift` (the default `run` seam delegates to `Proc.run` with a 600s/15s bound, so real checkouts/removes behave exactly as before).

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/WorktreeManager.swift Tests/OrchestraCoreTests/WorktreeTests.swift
git commit -m "feat(worktree): bound all git invocations with the Config knobs"
```

---

## Self-review checklist (run before Phase B)

1. **Spec coverage:** 3.1 knobs (names/defaults/additive-optional) ✓; 3.2 every git op bounded, no unbounded `Proc.run` ✓; all five mandated test names present ✓; `sessionLaunchTimeout` added but intentionally unconsumed here ✓.
2. **Placeholder scan:** no TBD/TODO; every code step shows complete code ✓.
3. **Type consistency:** seam signature `(_ argv: [String], _ timeout: Duration) throws -> ProcResult` (non-optional) identical in the property, the internal init, and the test `Recorder.run` ✓; `Config` knob names/types identical across 3.1 and 3.2 ✓; `.seconds(Int)` matches `Duration.seconds(some BinaryInteger)` ✓.
4. **Deviations** (Config path, borrow-add timeout, non-optional seam, renamed test file) documented above and to be folded into the vault "Decisions made" tables + merge-request.

## Review log

**Round 1 — Opus (SHIP) + GPT-5.5 (REVISE), both addressed:**
- *[both] `grep "Proc.run"` "no output" check was impossible* — the default seam legitimately contains `Proc.run`. → Verification now expects **exactly one** line (the bounded default seam) and relies on the non-optional `Duration` type to reject unbounded calls at compile time.
- *[GPT major] `test_worktreeAddIsBounded` only covered the new-branch add* — now drives **all three** add sites (ensure-new, ensure-existing, borrow) via `assertAddBounded`, asserting each carries `worktreeAddTimeout`.
- *[both] `test_worktreeAddTimesOut` was tautological* — now also asserts the timing-out add **carried the bound**, so it proves the value was passed, not just generic error propagation.
- *[GPT minor] seam `Duration?` weakened the invariant* — changed to non-optional `Duration`; an unbounded git op is now a **compile error**.
- *[GPT minor] `test_pruneIsBounded` didn't assert `worktree remove`'s own bound* — now asserts both `remove` and the fallback `prune` used `controlTimeout`.
- *[both] misleading `ProcTimeoutTests.swift` filename + `:124` "prune list" label* — renamed to `ConfigTimeoutTests.swift`; label corrected to `worktree list --porcelain`.
- *[Opus minor] `run: rec.run` may not infer `@Sendable`* — all injections wrap it as `{ try rec.run($0, $1) }`.
- *[Opus nit] unit tests leaked temp dirs* — `config()` returns a `cleanup` run in `defer`.
- **Confirmed correct by both** (no change): the Codable claim + custom `init(from:)`; the runner seam is not scope creep and keeps `Sendable`; exactly 8 `Proc.run` sites; timeout mapping (both adds → `worktreeAddTimeout`); legacy-JSON fixture matches the real required keys; clean scope (no PR3b leakage).

**Round 2 — Opus (SHIP) + GPT-5.5 (REVISE, one MINOR), addressed:**
- Opus re-review: **SHIP** — traced all three add paths, the non-optional-`Duration` promotion, the prune/remove disambiguation, and the strengthened timeout test; "no new problems introduced."
- *[GPT minor] the revised `grep -n "Proc.run"` still over-matches* — the seam's doc comment contains the bare token `Proc.run`, so the token grep would match two lines and falsely fail. → Verification changed to the structural, fixed-string call-expression match `grep -nF "Proc.run("` (the backticked prose mention has no `(`), expecting exactly one line (the seam call). This was GPT's own prescribed remedy; all other R2 checks passed. Both reviewers' substance is now clean.
