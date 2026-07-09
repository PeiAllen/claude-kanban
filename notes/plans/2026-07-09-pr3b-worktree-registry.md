# PR3b — WorktreeRegistry (Stage 3, Tasks 3.3–3.6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Strict TDD: write the failing test → run red → implement → run green → commit.

**Goal:** Introduce a single `WorktreeRegistry` actor that owns the entire worktree + borrow lifecycle — race-free `ensure` gated by a materialized marker, on-demand sibling counts, one fail-safe `release()` removal policy, persisted borrow registrations — and route every teardown path through it, making the concrete `WorktreeManager` a compile-time-private implementation detail of the registry.

**Architecture:** `WorktreeRegistry` is a Swift actor whose mailbox serializes all worktree git operations. It wraps a `WorktreeManaging` (production: the real `WorktreeManager`; tests: `StubWorktrees`). A **materialized marker** — a sentinel file in a registry-owned metadata dir *outside* the worktree — is written only after a complete checkout and is the sole adoption/"created" signal (replaces the bare `fileExists` at `WorktreeManager.swift:40`). Sibling reference counts are computed on demand from the caller-passed `[Task]` (a non-`archived` card holds its reference). Borrow registrations (`[borrowerCardId: path]`) persist as atomic JSON beside the inbox. `release()` removes a tree only when `siblings==0 && (!dirty || force) && created && pathUnderOwnedRoots`; on any ambiguity it keeps everything.

**Tech Stack:** Swift 6 actors, Foundation `FileManager` + atomic `replaceItemAt` JSON (the proven in-repo Inbox pattern), `swift-testing`/XCTest via `swift test`. No new dependencies.

## Global Constraints

- **Agent-agnostic.** No `if agentId == "claude"` anywhere in shared code. Worktree lifecycle is agent-neutral by construction; keep it that way.
- **Fail-safe pledge (the heart of this PR).** NEVER remove a dirty tree without explicit `force`; NEVER remove a tree a non-`archived` sibling references; NEVER remove a marker-less **dirty** dir (throw a classified error instead); NEVER remove any path outside the owned roots (worktrees root, incl. `orch-borrow-*`). On any ambiguity, keep the card and the tree. `release()` never throws in a way that escalates to data loss.
- **Compile-time guarantee.** After Task 3.5, the concrete `WorktreeManager` is `fileprivate` inside `WorktreeRegistry.swift` — nothing outside the registry's file *can* call git worktree ops.
- **Break the wire freely.** No cross-version interop needed. Reuse the PR3a Config timeout knobs (`worktreeAddTimeout`/`controlTimeout`) already in `Sources/OrchestraKit/Config.swift` — do not re-add them.
- **Single service actor.** Keep the one `OrchestraService` actor. Worktree/git IO lives on the `WorktreeRegistry` actor (off the service actor by construction).
- **Test doctrine.** Race/crash coverage comes from **deterministic stub seams** in `Tests/OrchestraCoreTests/Stubs.swift` (blockable `ensure` via `ensureSleepMs`, `removed`/`ensured`/`ensureArgv` recorders, controllable `isDirty`), NOT from E2E. E2E is smoke, not proof.
- **`swift test` stays green after every task** (~680 tests). Never leave a stage red.
- **Anchors** verified @ `f1aa568`. If a `file:line` has drifted, search the symbol.

---

## File structure (this PR)

| File | Responsibility | Task |
|---|---|---|
| `Sources/OrchestraCore/WorktreeRegistry.swift` (new) | The `WorktreeRegistry` actor: serialized `ensure`, marker arms, on-demand siblings, `release()`, persisted borrow lifecycle, path safety. In 3.5 the `WorktreeManager` struct moves *into* this file as `fileprivate`. | 3.3–3.5 |
| `Sources/OrchestraCore/WorktreeManager.swift` | (3.3) stays public + separate while the registry is built and unit-tested against it. (3.5) contents move into `WorktreeRegistry.swift`; this file is deleted. | 3.3, 3.5 |
| `Sources/OrchestraCore/Protocols.swift:6-29` | Extend `WorktreeManaging` with `isDirty(worktree:)` + `orphanBorrowPaths(repo:)` (both with safe protocol defaults). | 3.3 |
| `Sources/OrchestraKit/Config.swift:127-133` | Add `borrowsPath` + `worktreeMarkersDir` statics (siblings of `inboxPath`). | 3.3 |
| `Sources/OrchestraKit/Model.swift` | Add the `Worktree` return struct. | 3.3 |
| `Sources/OrchestraKit/Errors.swift:12` | Add `case worktreeNeedsManualCleanup(String)`. | 3.3 |
| `Sources/OrchestraCore/OrchestraService.swift` | (3.5) hold a `WorktreeRegistry`; route spawn rollback (`:390`) + archive (`:708`,`:739-746`) through it; delete `borrowedWorktrees` (`:60`). | 3.5 |
| `Sources/OrchestraCore/OrchestraService+Borrow.swift` | (3.5) delegate `borrow`/`release`/`sweepOrphanBorrows` to the registry. | 3.5 |
| `Sources/OrchestraCore/OrchestraService+Recovery.swift:248` | (3.5) reopen re-materialize via the registry; boot `stampMarkers`. | 3.5 |
| `Sources/orchestrad/main.swift:48-49` | (3.5) boot sweep routes through the registry. | 3.5 |
| `Tests/OrchestraCoreTests/Stubs.swift` | Extend `StubWorktrees` (real `remove`, controllable `isDirty`, `ensureSleepMs`, `orphanBorrowPaths`); wire registry + markers/borrows paths into `TestEnv`. | 3.3, 3.5 |
| `Tests/OrchestraCoreTests/WorktreeRegistryTests.swift` (new) | All `ensure`/`release`/`borrow`/path-safety unit tests. | 3.3, 3.4 |
| `Tests/OrchestraCoreTests/TaskStoreTests.swift` | Extend PR2's migration fixture: `test_migrationStampsMarkers` + dirty pre-upgrade tree survives byte-intact. | 3.3 |
| `Tests/OrchestraCoreTests/DaemonLifecycleTests.swift` | `test_archiveWithSiblingKeepsTree`, `test_spawnRollbackNeverForceRemovesSharedTree`. | 3.5 |
| **Test migration (privatization fallout):** `WorktreeTests.swift`, `IntegrationTests/WorktreeManagerTests.swift`, `RemoteSpawnTests.swift`, `SpawnBaseTests.swift`, `SpawnBaseValidationTests.swift`, `BorrowLifecycleTests.swift`, `E2EBinaryTests.swift`, `Stubs.swift` (`makeReal`) | Retarget every `WorktreeManager(...)` construction to `WorktreeRegistry` (run-seam init for the bounded-git timeout tests). | 3.5 |
| `docs/04-cards-worktrees-sessions.md`, `docs/09-design-decisions.md` | SSOT updates. | 3.6 |

## Key design decisions (locked; reviewers will probe these)

1. **The marker lives OUTSIDE the worktree**, in a registry-owned metadata dir (`Config.worktreeMarkersDir`, default `<dataDir>/worktree-markers/`), one empty sentinel file per canonical worktree path. Filename = the canonical path with `%`→`%25` then `/`→`%2F` (injective, reversible, filesystem-safe, no crypto — Linux/musl has no CryptoKit). **Why outside:** a marker inside the tree would (a) be reported by `git status --porcelain` as untracked → every tree reads "dirty", breaking the dirty arms, and (b) mutate a dirty pre-upgrade tree, violating the "survives byte-intact" contract.
2. **`created` ≡ marker present.** The registry only writes a marker after a complete checkout (`ensure`) or when stamping a migrated tree (`stampMarkers`). So "was this tree created/materialized by the registry?" is exactly "does its marker exist?" — this is what `release`'s `created` guard checks. A marker-less tree is never removed by `release` (fail-safe: honors `test_releaseHonorsCreatedFlag`).
3. **Serialization is the actor mailbox alone.** `ensure` performs NO `await` between the marker check and the checkout (the injected `run` closure and `WorktreeManager.ensure` are synchronous; `FileManager`/marker ops are synchronous). Two concurrent same-branch `ensure` calls therefore run one-at-a-time: the first cuts the tree + writes the marker, the second sees the marker and adopts. `git worktree add` runs once with no explicit per-branch lock. This globally serializes worktree ops (a conservative superset of "per branch") — acceptable for a single-user tool and matching the L2 contract ("actor mailbox = the serialization"); Stage 5 handles actor hygiene elsewhere.
4. **Owned roots = under `config.worktreesRoot`.** `orch-borrow-*` dirs live under `worktreesRoot/<repo>/` so the single prefix check covers both. `release` refuses to remove anything not under `worktreesRoot`.
5. **On-demand siblings, `!archived` holds the reference.** No stored refcount map. `release`/archive compute siblings from the passed `[Task]` at decision time: `cards.filter { $0.id != cardId && !$0.archived && $0.origin == .worktree && $0.cwd == path }`. A `dead` card still counts (its tree must survive for `restart`); only `archived` releases.
6. **Borrow registrations persist as `[String: String]`** (borrower `uuidString` → canonical path) — a clean JSON object (Swift encodes `[UUID: String]` as a flat array, which we avoid). In-memory the registry keys on `UUID`.

---

## Task 3.3: `WorktreeRegistry` actor — ensure + materialized marker + persisted borrows

**Files:**
- Create: `Sources/OrchestraCore/WorktreeRegistry.swift`
- Modify: `Sources/OrchestraKit/Config.swift:127-133` (add statics), `Sources/OrchestraKit/Model.swift` (add `Worktree`), `Sources/OrchestraKit/Errors.swift:12` (add case), `Sources/OrchestraCore/Protocols.swift:6-29` (extend `WorktreeManaging`), `Tests/OrchestraCoreTests/Stubs.swift` (extend `StubWorktrees`), `Tests/OrchestraCoreTests/TaskStoreTests.swift` (migration marker test)
- Test: `Tests/OrchestraCoreTests/WorktreeRegistryTests.swift` (new)

**Interfaces produced:**
```swift
public struct Worktree: Sendable, Equatable {
    public let path: String
    public let created: Bool          // true = this call cut a fresh checkout; false = adopted a marked tree
    public let branchExisted: Bool
}

public actor WorktreeRegistry {
    public init(config: Config, resolver: PathResolver? = nil,
                manager: (any WorktreeManaging)? = nil,
                borrowsPath: String = Config.borrowsPath,
                markersDir: String = Config.worktreeMarkersDir)

    public func ensure(repo: String, branch: String, cardId: UUID, base: String? = nil) async throws -> Worktree
    public func ensureBorrow(repo: String, parentBranch: String, borrowerCardId: UUID) async throws -> Worktree
    public func releaseBorrow(borrowerCardId: UUID) async throws
    public func sweepOrphanBorrows(cards: [Task]) async
    public func stampMarkers(forMigratedPaths paths: [String]) async
    public func release(cardId: UUID, cards: [Task], force: Bool) async throws   // BODY added in Task 3.4
    // pure helpers usable without hopping the actor:
    public nonisolated func path(repo: String, branch: String) -> String
    public nonisolated func borrowPath(repo: String, branch: String) -> String
}
```
> **Interface-split note (vs L2 `02-contract.md:91-116`):** the L2 "exact interface for plan Task 3.3" lists all seven methods including `release`. PR3b splits that exact interface across two commits — `ensure`/`ensureBorrow`/`releaseBorrow`/`sweepOrphanBorrows`/`stampMarkers` land in Task 3.3; `release`'s body lands in Task 3.4. The final PR3b interface matches L2 exactly, with zero drift.
- **Consumes (from PR3a):** `Config.worktreeAddTimeout`/`.controlTimeout`; `WorktreeManager` with its injectable timed `run` seam; `WorktreeManaging` protocol; `PathResolver.assertAllowed`/`.canonical`/`resolveRepo`.
- **Produces (for 3.4/3.5):** the actor + `Worktree` type + the persisted-borrows/markers seams.

### Step 1: Config statics + `Worktree` type + error case (scaffolding for the failing tests)

- [ ] **Add `Config` statics** after `inboxPath` (`Sources/OrchestraKit/Config.swift:133`):

```swift
/// Persisted borrow registrations (`[borrowerCardId: path]`), sibling to `inboxPath`.
public static var borrowsPath: String { "\(dataDir)/borrows.json" }
/// Registry-owned worktree "materialized" markers (one sentinel file per worktree path), sibling to `inboxPath`.
public static var worktreeMarkersDir: String { "\(dataDir)/worktree-markers" }
```

- [ ] **Add the `Worktree` struct** to `Sources/OrchestraKit/Model.swift` (near `SpawnInput`):

```swift
/// The result of `WorktreeRegistry.ensure`/`ensureBorrow`: the materialized worktree path plus the two
/// signals spawn/recovery still need (`created` = a fresh checkout was cut this call; `branchExisted` =
/// the branch pre-existed so lineage config may carry).
public struct Worktree: Sendable, Equatable {
    public let path: String
    public let created: Bool
    public let branchExisted: Bool
    public init(path: String, created: Bool, branchExisted: Bool) {
        self.path = path; self.created = created; self.branchExisted = branchExisted
    }
}
```

- [ ] **Add the error case** to `Sources/OrchestraKit/Errors.swift` (after `worktreeDirty`, line 12). `OrchestraError` has **THREE** exhaustive switches (no `default`): the case list, `var description`, and `var code: Int` (`Errors.swift:56-74`). You MUST add an arm to ALL THREE or the build fails:

```swift
// 1. the case list (after `worktreeDirty`):
case worktreeNeedsManualCleanup(String)   // marker-less DIRTY dir at the ensure path — never auto-removed
```
```swift
// 2. var description:
case .worktreeNeedsManualCleanup(let p):
    return "worktree dir at \(p) has uncommitted changes but no completion marker — manual cleanup needed "
         + "(a prior checkout was interrupted); move your work out, delete the dir, then retry"
```
```swift
// 3. var code (highest existing id is 1014):
case .worktreeNeedsManualCleanup: return 1015
```

- [ ] **Extend `WorktreeManaging`** (`Sources/OrchestraCore/Protocols.swift`) with two methods + safe defaults:

```swift
public protocol WorktreeManaging: Sendable {
    // ...existing...
    /// True if the worktree has uncommitted changes. FAILS SAFE (unqueryable ⇒ dirty).
    func isDirty(worktree: String) -> Bool
    /// Canonical `orch-borrow-*` dir paths currently present under `repo` (LIST only, no removal).
    func orphanBorrowPaths(repo: String) -> [String]
}
public extension WorktreeManaging {
    func isDirty(worktree: String) -> Bool { true }          // conservative default
    func orphanBorrowPaths(repo: String) -> [String] { [] }
}
```

- [ ] **Make `WorktreeManager` satisfy them.** `isDirty` already exists (`WorktreeManager.swift:177`) — change `func isDirty` to `public func isDirty` so it fulfils the protocol. Add `orphanBorrowPaths` by refactoring `pruneOrphanBorrows` into a list + (the registry does removal):

```swift
public func orphanBorrowPaths(repo: String) -> [String] {
    guard let realRepo = try? resolver.resolveRepo(repo),
          let r = try? run(["git", "-C", realRepo, "worktree", "list", "--porcelain"],
                           .seconds(config.controlTimeout)), r.ok else { return [] }
    var out: [String] = []
    for line in r.stdout.split(separator: "\n") where line.hasPrefix("worktree ") {
        let p = String(line.dropFirst("worktree ".count)).trimmingCharacters(in: .whitespaces)
        if (p as NSString).lastPathComponent.hasPrefix("orch-borrow-") { out.append(p) }
    }
    return out
}
```
Keep `pruneOrphanBorrows` for now (3.5 removes its last caller).

- [ ] **Run:** `swift build` → PASS (no behavior change yet; protocol defaults keep conformers compiling).

### Step 2: Write the failing tests (`WorktreeRegistryTests.swift`)

- [ ] Create `Tests/OrchestraCoreTests/WorktreeRegistryTests.swift`. Use a helper that builds a registry over a `StubWorktrees` + temp markers/borrows dirs:

```swift
import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit

private func makeRegistry() -> (reg: WorktreeRegistry, stub: StubWorktrees, base: String) {
    let base = PathResolver.canonical(NSTemporaryDirectory() + "orch-reg-\(UUID().uuidString)")
    let config = Config(reposRoot: base + "/repos", worktreesRoot: base + "/worktrees", allowlist: [base])
    try? FileManager.default.createDirectory(atPath: config.worktreesRoot, withIntermediateDirectories: true)
    let stub = StubWorktrees(root: config.worktreesRoot)
    let reg = WorktreeRegistry(config: config, resolver: PathResolver(config: config), manager: stub,
                               borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
    return (reg, stub, base)
}

// Defined ONCE here (shared by the sweep tests below and Task 3.4's release tests) — do NOT redefine
// it in 3.4 or the duplicate symbol breaks the build.
private func card(_ id: UUID, cwd: String, archived: Bool = false, origin: CardOrigin = .worktree) -> Task {
    Task(id: id, title: "t", repo: "app", branch: "b-\(id.uuidString.prefix(4))", cwd: cwd,
         origin: origin, model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0,
         phase: .live(.running), initialPrompt: "", archived: archived)
}
```

- [ ] **`test_concurrentSameBranchEnsureJoins`** — two concurrent same-branch `ensure` calls yield the same path and `git worktree add` runs exactly once:

```swift
@Test func test_concurrentSameBranchEnsureJoins() async throws {
    let (reg, stub, _) = makeRegistry()
    stub.ensureSleepMs = 40   // widen the window: a regression that inserted an `await` mid-critical-section
                              // would let the 2nd call cut a 2nd tree (ensured.count==2). Serialization is
                              // structural (no await), so on correct code the count stays 1 regardless.
    // DISTINCT card ids on the SAME branch — proves joining is keyed on branch/PATH, not on card id
    // (a registry that deduped by cardId would wrongly pass with equal ids).
    async let a = reg.ensure(repo: "app", branch: "feat/x", cardId: UUID())
    async let b = reg.ensure(repo: "app", branch: "feat/x", cardId: UUID())
    let (wa, wb) = try await (a, b)
    #expect(wa.path == wb.path)
    #expect(stub.ensured.count == 1)          // exactly ONE git worktree add
    #expect((wa.created ? 1 : 0) + (wb.created ? 1 : 0) == 1)   // one created, one adopted
}
```

- [ ] **`test_markerlessCleanDirRecreated`** — a *clean* marker-less dir is pruned + re-created:

```swift
@Test func test_markerlessCleanDirRecreated() async throws {
    let (reg, stub, _) = makeRegistry()
    let wt = stub.path(repo: "app", branch: "feat/x")
    try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)  // marker-less dir
    stub.setDirty(wt, false)
    let w = try await reg.ensure(repo: "app", branch: "feat/x", cardId: UUID())
    #expect(stub.removed.contains(wt))        // pruned
    #expect(stub.ensured.count == 1)          // re-created
    #expect(w.created)
}
```

- [ ] **`test_markerlessDirtyDirNeverRemoved`** — a *dirty* marker-less dir is left byte-intact; `ensure` throws the classified error:

```swift
@Test func test_markerlessDirtyDirNeverRemoved() async throws {
    let (reg, stub, _) = makeRegistry()
    let wt = stub.path(repo: "app", branch: "feat/x")
    try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
    try "work".write(toFile: wt + "/scratch.txt", atomically: true, encoding: .utf8)
    stub.setDirty(wt, true)
    await #expect(throws: OrchestraError.worktreeNeedsManualCleanup(wt)) {
        _ = try await reg.ensure(repo: "app", branch: "feat/x", cardId: UUID())
    }
    #expect(!stub.removed.contains(wt))                                        // never removed
    #expect(FileManager.default.fileExists(atPath: wt + "/scratch.txt"))       // byte-intact
    #expect(stub.ensured.isEmpty)                                             // no add attempted
}
```

- [ ] **`test_ensureReMaterializesMissingTree`** — a marked card whose tree was deleted is re-created from the branch:

```swift
@Test func test_ensureReMaterializesMissingTree() async throws {
    let (reg, stub, _) = makeRegistry()
    let id = UUID()
    let w1 = try await reg.ensure(repo: "app", branch: "feat/x", cardId: id)      // materialize + marker
    try FileManager.default.removeItem(atPath: w1.path)                            // tree vanishes (marker stays)
    stub.markBranchExists("feat/x")                                               // branch still exists
    let w2 = try await reg.ensure(repo: "app", branch: "feat/x", cardId: id)      // re-materialize
    #expect(w2.path == w1.path)
    #expect(w2.created)
    #expect(stub.ensured.count == 2)
}
```

- [ ] **`test_ensureRejectsPathEscape`** — a branch whose computed path escapes the worktrees root throws, cuts nothing:

```swift
@Test func test_ensureRejectsPathEscape() async throws {
    let (reg, stub, _) = makeRegistry()
    await #expect(throws: (any Error).self) {
        _ = try await reg.ensure(repo: "app", branch: "../../../../etc/evil", cardId: UUID())
    }
    #expect(stub.ensured.isEmpty)
}
```

- [ ] **`test_exactlyOneBorrower`** — a second `ensureBorrow` on the same parent throws, naming the parent:

```swift
@Test func test_exactlyOneBorrower() async throws {
    let (reg, _, _) = makeRegistry()
    _ = try await reg.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: UUID())
    await #expect(throws: OrchestraError.parentAlreadyBorrowed("main")) {
        _ = try await reg.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: UUID())
    }
}
```

- [ ] **`test_borrowRegistrationSurvivesRestart`** — a fresh registry over the same persisted file still knows the borrower (so a stray-dir sweep won't yank a live borrow):

```swift
@Test func test_borrowRegistrationSurvivesRestart() async throws {
    let (reg, stub, base) = makeRegistry()
    let borrower = UUID()
    let w = try await reg.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: borrower)
    // Fresh registry instance reading the SAME borrows.json (simulates daemon restart).
    let config = Config(reposRoot: base + "/repos", worktreesRoot: base + "/worktrees", allowlist: [base])
    let reg2 = WorktreeRegistry(config: config, resolver: PathResolver(config: config), manager: stub,
                                borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
    // A different child cannot re-borrow the still-registered parent.
    await #expect(throws: OrchestraError.parentAlreadyBorrowed("main")) {
        _ = try await reg2.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: UUID())
    }
    // The original borrower's re-borrow is idempotent (same path).
    let again = try await reg2.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: borrower)
    #expect(again.path == w.path)
}
```

- [ ] **`test_sweepKeepsLiveBorrowerTree`** — the liveness-guarded sweep never removes a live borrower's dir (guards MAJOR-2's data-loss class); a terminated borrower's dir IS reclaimed:

```swift
@Test func test_sweepKeepsLiveBorrowerTree() async throws {
    let (reg, stub, _) = makeRegistry()
    let live = UUID(), gone = UUID()
    let wLive = try await reg.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: live)
    let wGone = try await reg.ensureBorrow(repo: "app", parentBranch: "other", borrowerCardId: gone)
    let liveCard = card(live, cwd: "/anywhere")          // present + non-archived ⇒ kept
    var goneCard = card(gone, cwd: "/anywhere"); goneCard.archived = true   // present + archived ⇒ reclaimed
    await reg.sweepOrphanBorrows(cards: [liveCard, goneCard])
    #expect(!stub.removed.contains(wLive.path))           // live borrower kept
    #expect(stub.removed.contains(wGone.path))            // terminated borrower reclaimed
}

@Test func test_sweepKeepsBorrowWhenCardsAmbiguous() async throws {
    let (reg, stub, _) = makeRegistry()
    let b = UUID()
    let w = try await reg.ensureBorrow(repo: "app", parentBranch: "main", borrowerCardId: b)
    await reg.sweepOrphanBorrows(cards: [])              // empty/partial load ⇒ ambiguity ⇒ keep everything
    #expect(!stub.removed.contains(w.path))
    // A borrower merely ABSENT (present-but-unknown) is also ambiguous ⇒ kept.
    await reg.sweepOrphanBorrows(cards: [card(UUID(), cwd: "/x")])
    #expect(!stub.removed.contains(w.path))
}
```
(`card(_:cwd:)` is the helper defined once above in this file. The path canonicalization added to `sweepOrphanBorrows` is what makes this hold when `worktreesRoot` is non-canonical; the stub uses one root string so this test proves the liveness guard, and the canonicalization is asserted by review of the `PathResolver.canonical` calls.)

### Step 3: Extend `StubWorktrees` (deterministic seams)

- [ ] In `Tests/OrchestraCoreTests/Stubs.swift`, extend `StubWorktrees`:
  - add `var ensureSleepMs: UInt32 = 0` and, inside `ensure`, `if ensureSleepMs > 0 { usleep(ensureSleepMs * 1000) }` (between recording and returning) so concurrent calls genuinely contend on the actor;
  - make `remove` actually delete the dir (so the registry's `fileExists` reflects reality), keep the `removed: [String]` recorder, AND record the `force` flag (the rollback-routing test discriminates old `force:true` from new `force:false`):
    ```swift
    private(set) var removedForce: [(path: String, force: Bool)] = []
    func remove(worktree: String, force: Bool) throws {
        lock.lock(); removed.append(worktree); removedForce.append((worktree, force)); lock.unlock()
        try? FileManager.default.removeItem(atPath: worktree)
    }
    ```
    > **Audit before running the full suite:** existing archive/reopen/spawn tests call through `worktrees.remove` and today the stub leaves the dir intact. Grep tests for assertions that read a removed dir's filesystem state (`fileExists` on a removed cwd) and fix any that assumed survival. Most assert on the `removed` recorder, which is unaffected.
  - add a controllable dirty set:
    ```swift
    private var dirtyPaths: Set<String> = []
    func setDirty(_ path: String, _ v: Bool) { lock.lock(); if v { dirtyPaths.insert(path) } else { dirtyPaths.remove(path) }; lock.unlock() }
    func isDirty(worktree: String) -> Bool { lock.lock(); defer { lock.unlock() }; return dirtyPaths.contains(worktree) }
    ```
  - implement `orphanBorrowPaths` by scanning the stub root for `orch-borrow-*` dirs:
    ```swift
    func orphanBorrowPaths(repo: String) -> [String] {
        let dir = "\(root)/\((repo as NSString).lastPathComponent)"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return entries.filter { $0.hasPrefix("orch-borrow-") }.map { "\(dir)/\($0)" }
    }
    ```

### Step 4: Run the new tests → RED

- [ ] Run: `swift test --filter WorktreeRegistryTests`
- [ ] Expected: FAIL — `WorktreeRegistry` does not exist yet.

### Step 5: Implement `WorktreeRegistry` (ensure + markers + borrows)

- [ ] Create `Sources/OrchestraCore/WorktreeRegistry.swift`:

```swift
import Foundation
import OrchestraKit

public actor WorktreeRegistry {
    private let config: Config
    private let resolver: PathResolver
    private let manager: any WorktreeManaging
    private let borrowsPath: String
    private let markersDir: String

    /// borrower cardId -> canonical borrow path. Persisted (survives a daemon-only crash).
    private var borrows: [UUID: String] = [:]
    private var borrowsLoaded = false

    /// canonical worktree path -> cardIds that called `ensure` for it and have not yet `release`d.
    /// Closes the concurrent-spawn rollback race: spawn A creates a tree, spawn B for the same branch
    /// interleaves at the service actor's `await registry.ensure` suspension and ADOPTS A's tree, but B
    /// is not yet in the store; if A then fails lineage recording, A's rollback `release` would (from a
    /// store-only sibling scan) see no sibling and remove the tree out from under the in-flight B. An
    /// in-flight holder IS a reference — `release` keeps a tree any OTHER in-flight holder still holds.
    /// Cleaned on the normal paths (rollback now / archive later each call `release`, whose `defer` drops
    /// the id). Residual: if `store.create` — or anything between `ensure` success and persistence —
    /// throws, the card is never persisted and never `release`d, so its entry lingers until restart and
    /// pins the tree from removal. That is fail-safe (keeps a tree, never data loss) and restart-healed
    /// (in-memory ⇒ a fresh daemon recomputes references from `store.all()`); it matches the pre-existing
    /// "a store.create failure strands the worktree" tradeoff. NOT a data-loss path.
    private var inflight: [String: Set<UUID>] = [:]

    public init(config: Config, resolver: PathResolver? = nil,
                manager: (any WorktreeManaging)? = nil,
                borrowsPath: String = Config.borrowsPath,
                markersDir: String = Config.worktreeMarkersDir) {
        self.config = config
        self.resolver = resolver ?? PathResolver(config: config)
        self.manager = manager ?? WorktreeManager(config: config, resolver: resolver)
        self.borrowsPath = borrowsPath
        self.markersDir = markersDir
    }

    // MARK: pure helpers (no actor state)
    public nonisolated func path(repo: String, branch: String) -> String { manager.path(repo: repo, branch: branch) }
    public nonisolated func borrowPath(repo: String, branch: String) -> String { manager.borrowPath(repo: repo, branch: branch) }

    // MARK: - ensure
    /// Serialized by the actor mailbox. NO `await` between the marker check and the checkout, so two
    /// concurrent same-branch calls run one-at-a-time and `git worktree add` fires once.
    public func ensure(repo: String, branch: String, cardId: UUID, base: String? = nil) async throws -> Worktree {
        let realRepo = try resolver.resolveRepo(repo)
        let wt = manager.path(repo: realRepo, branch: branch)
        try assertUnderWorktreesRoot(wt)                      // path-escape guard

        let dirExists = FileManager.default.fileExists(atPath: wt)
        let marked = markerExists(wt)
        if dirExists && marked {                              // adopt a materialized tree
            inflight[PathResolver.canonical(wt), default: []].insert(cardId)   // record the in-flight adopter
            return Worktree(path: wt, created: false, branchExisted: true)
        }
        if dirExists && !marked {                            // half-created / pre-upgrade tree
            if manager.isDirty(worktree: wt) {
                throw OrchestraError.worktreeNeedsManualCleanup(wt)   // NEVER auto-removed
            }
            try? manager.remove(worktree: wt, force: true)           // clean ⇒ prune
            if FileManager.default.fileExists(atPath: wt) {          // stray non-worktree dir
                try FileManager.default.removeItem(atPath: wt)
            }
        }
        // dir absent (fresh OR just pruned OR re-materialize-missing) ⇒ cut a checkout, THEN mark.
        let ensured = try manager.ensure(repo: realRepo, branch: branch, base: base)
        writeMarker(ensured.worktree)
        inflight[PathResolver.canonical(ensured.worktree), default: []].insert(cardId)   // record the in-flight creator
        return Worktree(path: ensured.worktree, created: ensured.created, branchExisted: ensured.branchExisted)
    }

    // MARK: - borrow lifecycle
    public func ensureBorrow(repo: String, parentBranch: String, borrowerCardId: UUID) async throws -> Worktree {
        loadBorrows()
        let realRepo = try resolver.resolveRepo(repo)
        let path = manager.borrowPath(repo: realRepo, branch: parentBranch)
        if let holder = borrows.first(where: { $0.value == path })?.key, holder != borrowerCardId {
            throw OrchestraError.parentAlreadyBorrowed(parentBranch)
        }
        if borrows.first(where: { $0.value == path }) == nil && FileManager.default.fileExists(atPath: path) {
            throw OrchestraError.parentAlreadyBorrowed(parentBranch)   // stray/crashed borrow dir
        }
        let created = try manager.borrow(repo: realRepo, branch: parentBranch)
        borrows[borrowerCardId] = created
        persistBorrows()
        return Worktree(path: created, created: true, branchExisted: true)
    }

    public func releaseBorrow(borrowerCardId: UUID) async throws {
        loadBorrows()
        guard let path = borrows[borrowerCardId] else { return }   // idempotent
        borrows[borrowerCardId] = nil
        persistBorrows()
        if !borrows.values.contains(path) {                        // no other holder ⇒ throwaway, force-remove
            try? manager.remove(worktree: path, force: true)
        }
    }

    /// Liveness-guarded. Keeps any dir whose registered borrower is still non-`archived`; removes
    /// terminated-borrower registrations + stray unregistered `orch-borrow-*` dirs.
    public func sweepOrphanBorrows(cards: [Task]) async {
        loadBorrows()
        // FAIL-SAFE ambiguity guard: an empty `cards` alongside non-empty registrations means the caller
        // handed us no evidence (partial/failed store load). "On ambiguity keep everything" — do nothing.
        guard !(cards.isEmpty && !borrows.isEmpty) else { return }
        // POSITIVE terminal evidence only: reclaim a registered borrow ONLY when its borrower card is
        // PRESENT in `cards` AND archived. A borrower that is merely ABSENT is ambiguous ⇒ keep (the truly
        // crashed/unregistered dirs are handled by the stray loop below, which never touches a live borrow).
        func terminated(_ id: UUID) -> Bool { cards.first(where: { $0.id == id }).map { $0.archived } ?? false }
        // CANONICALIZE both sides: `borrows.values` come from `borrowPath` = "\(worktreesRoot)/…"
        // (worktreesRoot stored verbatim, maybe non-canonical); `orphanBorrowPaths` returns git's
        // realpath-CANONICAL paths. A bare string compare could see a LIVE borrower's dir as "stray" and
        // force-remove it (bug #1).
        let keptPaths = Set(borrows.compactMap { terminated($0.key) ? nil : PathResolver.canonical($0.value) })
        for (id, p) in borrows where terminated(id) {
            if !keptPaths.contains(PathResolver.canonical(p)) { try? manager.remove(worktree: p, force: true) }
            borrows[id] = nil
        }
        persistBorrows()
        for repo in Set(cards.filter { $0.origin == .worktree }.map(\.repo)) {
            for stray in manager.orphanBorrowPaths(repo: repo) where !keptPaths.contains(PathResolver.canonical(stray)) {
                try? manager.remove(worktree: stray, force: true)
            }
        }
    }

    // MARK: - migration
    /// One-time: pre-upgrade trees are marker-less. Stamp a marker (OUTSIDE the tree) so they become
    /// adoptable. Does NOT touch tree contents ⇒ a dirty pre-upgrade tree survives byte-intact.
    public func stampMarkers(forMigratedPaths paths: [String]) async {
        for p in paths where FileManager.default.fileExists(atPath: p) { writeMarker(p) }
    }

    // MARK: - markers (registry-owned, OUTSIDE the worktree)
    private func markerFile(_ wt: String) -> String {
        let canon = PathResolver.canonical(wt)
        let enc = canon.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
        return "\(markersDir)/\(enc)"
    }
    private func markerExists(_ wt: String) -> Bool { FileManager.default.fileExists(atPath: markerFile(wt)) }
    private func writeMarker(_ wt: String) {
        try? FileManager.default.createDirectory(atPath: markersDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: markerFile(wt), contents: Data())
    }
    private func removeMarker(_ wt: String) { try? FileManager.default.removeItem(atPath: markerFile(wt)) }

    // MARK: - path safety
    private func assertUnderWorktreesRoot(_ p: String) throws {
        guard isUnderOwnedRoots(p) else { throw OrchestraError.pathNotAllowed(p) }
        try resolver.assertAllowed(p)   // defense-in-depth (component-wise `..` collapse)
    }
    /// Owned roots for removal/creation = under `worktreesRoot` (covers `orch-borrow-*`).
    private func isUnderOwnedRoots(_ p: String) -> Bool {
        let root = PathResolver.canonical(config.worktreesRoot)
        let real = PathResolver.canonical(p)
        return real == root || real.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: - borrow persistence (atomic JSON, [String:String] on disk)
    private func loadBorrows() {
        guard !borrowsLoaded else { return }
        borrowsLoaded = true
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: borrowsPath)),
              let raw = try? OrchestraJSON.decoder.decode([String: String].self, from: data) else { return }
        borrows = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    }
    private func persistBorrows() {
        let raw = Dictionary(uniqueKeysWithValues: borrows.map { ($0.key.uuidString, $0.value) })
        guard let data = try? OrchestraJSON.pretty.encode(raw) else { return }
        let dir = (borrowsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: borrowsPath)
        let tmp = URL(fileURLWithPath: borrowsPath + ".tmp.\(UUID().uuidString)")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        if FileManager.default.fileExists(atPath: borrowsPath) { _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp) }
        else { try? FileManager.default.moveItem(at: tmp, to: url) }
    }
}
```

> **Note on `isUnderOwnedRoots` vs `assertAllowed`:** `assertAllowed` accepts `reposRoot` too, so it alone would let a branch escape *into* `reposRoot`. `assertUnderWorktreesRoot` is stricter (worktrees root only) and runs first, satisfying `test_ensureRejectsPathEscape`.

- [ ] **Run:** `swift test --filter WorktreeRegistryTests` → PASS.

### Step 6: Migration marker test (extend PR2's fixture)

- [ ] In `Tests/OrchestraCoreTests/TaskStoreTests.swift`, alongside PR2's `test_migratesLegacyTasksJson`, add `test_migrationStampsMarkers`: build a registry over a temp base, create two pre-upgrade worktree dirs (one **clean**, one **dirty** with an untracked file), call `stampMarkers(forMigratedPaths:)`, then assert **both become adoptable** (`ensure` returns `created == false`, no removal) AND the dirty tree's file is byte-intact:

```swift
@Test func test_migrationStampsMarkers() async throws {
    let (reg, stub, _) = makeRegistry()                 // reuse the WorktreeRegistryTests helper (make it internal)
    let clean = stub.path(repo: "app", branch: "old/clean")
    let dirty = stub.path(repo: "app", branch: "old/dirty")
    for p in [clean, dirty] { try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
    try "keep".write(toFile: dirty + "/uncommitted.txt", atomically: true, encoding: .utf8)
    stub.setDirty(dirty, true)

    await reg.stampMarkers(forMigratedPaths: [clean, dirty])

    let a = try await reg.ensure(repo: "app", branch: "old/clean", cardId: UUID())
    let b = try await reg.ensure(repo: "app", branch: "old/dirty", cardId: UUID())
    #expect(!a.created && !b.created)                             // adopted, not recreated
    #expect(stub.removed.isEmpty)                                // nothing removed
    #expect(FileManager.default.fileExists(atPath: dirty + "/uncommitted.txt"))   // byte-intact
    #expect(try String(contentsOfFile: dirty + "/uncommitted.txt", encoding: .utf8) == "keep")
}
```
(Move `makeRegistry`/the `StubWorktrees` extensions to `internal` visibility so both test files share them.)

- [ ] **Run:** `swift test` (full) → green.

### Step 7: Commit

```bash
git add Sources/OrchestraCore/WorktreeRegistry.swift Sources/OrchestraCore/WorktreeManager.swift \
        Sources/OrchestraCore/Protocols.swift Sources/OrchestraKit/Config.swift \
        Sources/OrchestraKit/Model.swift Sources/OrchestraKit/Errors.swift \
        Tests/OrchestraCoreTests/WorktreeRegistryTests.swift Tests/OrchestraCoreTests/Stubs.swift \
        Tests/OrchestraCoreTests/TaskStoreTests.swift
git commit -m "feat(worktree): WorktreeRegistry — marker arms, on-demand siblings, persisted borrows"
```

---

## Task 3.4: One removal policy via `release()`

**Files:**
- Modify: `Sources/OrchestraCore/WorktreeRegistry.swift`
- Test: `Tests/OrchestraCoreTests/WorktreeRegistryTests.swift`

**Interfaces produced:**
```swift
extension WorktreeRegistry {
    /// The SINGLE removal policy every teardown routes through. Removes the card's tree only when
    /// siblings==0 && (!dirty || force) && created(marker present) && pathUnderOwnedRoots. A missing
    /// tree is a no-op success. Never throws in a way that escalates to data loss.
    public func release(cardId: UUID, cards: [Task], force: Bool) async throws
}
```
- **Consumes:** `Worktree`/markers/`isUnderOwnedRoots` from 3.3; the passed `[Task]` for on-demand siblings.

### Step 1: Write the failing tests

- [ ] Add to `WorktreeRegistryTests.swift`. Reuse the `card(_:cwd:archived:origin:)` helper already defined once in Task 3.3 (do NOT redefine it here — duplicate symbol). It builds a `.worktree` `Task` at a given cwd; the release tests materialize each tree's marker first via `ensure`.

- [ ] **`test_releaseNeverRemovesWhileReferenced`** (incl. a `dead` holder):

```swift
@Test func test_releaseNeverRemovesWhileReferenced() async throws {
    let (reg, stub, _) = makeRegistry()
    let a = UUID(), b = UUID()
    let w = try await reg.ensure(repo: "app", branch: "shared", cardId: a)   // materialized (marker present)
    var deadSibling = card(b, cwd: w.path); deadSibling.phase = .dead(.completed)   // dead still holds
    try await reg.release(cardId: a, cards: [card(a, cwd: w.path), deadSibling], force: false)
    #expect(!stub.removed.contains(w.path))   // kept — a dead sibling references it
}
```

- [ ] **`test_releaseNeverRemovesDirtyWithoutForce`**:

```swift
@Test func test_releaseNeverRemovesDirtyWithoutForce() async throws {
    let (reg, stub, _) = makeRegistry()
    let a = UUID()
    let w = try await reg.ensure(repo: "app", branch: "d", cardId: a)
    stub.setDirty(w.path, true)
    try await reg.release(cardId: a, cards: [card(a, cwd: w.path)], force: false)   // no throw
    #expect(!stub.removed.contains(w.path))   // dirty + !force ⇒ kept
    try await reg.release(cardId: a, cards: [card(a, cwd: w.path)], force: true)
    #expect(stub.removed.contains(w.path))    // force ⇒ removed
}
```

- [ ] **`test_releaseHonorsCreatedFlag`** — a marker-less (never-materialized) tree is not deleted:

```swift
@Test func test_releaseHonorsCreatedFlag() async throws {
    let (reg, stub, _) = makeRegistry()
    let a = UUID()
    let wt = stub.path(repo: "app", branch: "adopted")
    try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)  // NO marker
    stub.setDirty(wt, false)
    try await reg.release(cardId: a, cards: [card(a, cwd: wt)], force: false)
    #expect(!stub.removed.contains(wt))   // no marker ⇒ not "created by us" ⇒ kept
}
```

- [ ] **`test_releaseIdempotentToMissingTree`** — releasing an already-gone tree is a no-op success:

```swift
@Test func test_releaseIdempotentToMissingTree() async throws {
    let (reg, stub, _) = makeRegistry()
    let a = UUID()
    let w = try await reg.ensure(repo: "app", branch: "g", cardId: a)
    try FileManager.default.removeItem(atPath: w.path)   // tree already gone
    try await reg.release(cardId: a, cards: [card(a, cwd: w.path)], force: false)   // no throw
    #expect(!stub.removed.contains(w.path))   // nothing to remove
}
```

- [ ] **`test_releaseKeepsTreeWithInflightAdopter`** — the concurrent-spawn rollback race (GPT round-2 BLOCKER): a second card adopted the tree via `ensure` but is not yet in the store; the first card's rollback `release` must KEEP it:

```swift
@Test func test_releaseKeepsTreeWithInflightAdopter() async throws {
    let (reg, stub, _) = makeRegistry()
    let a = UUID(), b = UUID()
    let w = try await reg.ensure(repo: "app", branch: "nb", cardId: a)   // A creates + marks; inflight {a}
    _ = try await reg.ensure(repo: "app", branch: "nb", cardId: b)       // B ADOPTS; inflight {a,b}
    // A's rollback: A is present (as a synthetic), B is NOT in the store yet.
    try await reg.release(cardId: a, cards: [card(a, cwd: w.path)], force: false)
    #expect(!stub.removed.contains(w.path))   // kept — B is an in-flight holder
    // Now B settles (archive/teardown) with no other holder ⇒ removable.
    try await reg.release(cardId: b, cards: [card(b, cwd: w.path)], force: false)
    #expect(stub.removed.contains(w.path))    // last holder gone ⇒ removed
}
```
> This deterministic registry unit test IS the regression guard for the concurrent-spawn race (test doctrine: stubs over E2E). It proves `release` honors an in-flight adopter that a store-only sibling scan would miss.

- [ ] **`test_releaseNeverRemovesOutsideOwnedRoots`** — a cwd outside the worktrees root is never removed, force or not:

```swift
@Test func test_releaseNeverRemovesOutsideOwnedRoots() async throws {
    let (reg, stub, base) = makeRegistry()
    let a = UUID()
    let outside = base + "/repos/app"   // under reposRoot, NOT worktreesRoot
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    await reg.stampMarkers(forMigratedPaths: [outside])   // satisfy the `created`(marker) guard so ONLY
                                                          // the owned-roots guard can prevent removal
    try await reg.release(cardId: a, cards: [card(a, cwd: outside)], force: true)
    #expect(!stub.removed.contains(outside))              // kept SOLELY because it's outside worktreesRoot
}
```

### Step 2: Run → RED

- [ ] Run: `swift test --filter WorktreeRegistryTests` → FAIL (`release` undefined).

### Step 3: Implement `release`

- [ ] Add to `WorktreeRegistry.swift`:

```swift
/// Seam for Stage-4 conservative mode (post-corrupt-recovery): when true, release removes nothing until
/// ownership is positively re-established. PR4b/Task 4.4 sets it; here it just gates the policy.
private var conservativeMode = false
public func setConservativeMode(_ on: Bool) { conservativeMode = on }

public func release(cardId: UUID, cards: [Task], force: Bool) async throws {
    guard let card = cards.first(where: { $0.id == cardId }) else { return }   // unknown ⇒ no-op
    let wt = card.cwd
    let canon = PathResolver.canonical(wt)
    defer { inflight[canon]?.remove(cardId); if inflight[canon]?.isEmpty == true { inflight[canon] = nil } }
    if conservativeMode { return }                                            // Stage-4 seam
    guard isUnderOwnedRoots(wt) else { return }                              // never outside owned roots
    guard markerExists(wt) else { return }                                    // created(≡marker) guard
    guard FileManager.default.fileExists(atPath: wt) else { removeMarker(wt); return }  // idempotent-to-missing
    let storeSibling = cards.contains { $0.id != cardId && !$0.archived && $0.origin == .worktree && $0.cwd == wt }
    let inflightSibling = !(inflight[canon]?.subtracting([cardId]).isEmpty ?? true)   // another in-flight holder?
    guard !storeSibling && !inflightSibling else { return }                 // referenced (stored OR in-flight) ⇒ keep
    if manager.isDirty(worktree: wt) && !force { return }                    // dirty + !force ⇒ keep
    try? manager.remove(worktree: wt, force: force)                          // never throw to data loss
    if !FileManager.default.fileExists(atPath: wt) { removeMarker(wt) }
}
```

> **Conservative-mode seam:** the `if conservativeMode { return }` line + `setConservativeMode` are the Stage-4 gate the plan asks us to *leave* — PR4b wires the flag on corrupt-recovery boot; here it stays `false` and unwired, so behavior is unchanged and no test depends on it.

### Step 4: Run → GREEN

- [ ] Run: `swift test --filter WorktreeRegistryTests` → PASS. Then `swift test` (full) → green.

### Step 5: Commit

```bash
git add Sources/OrchestraCore/WorktreeRegistry.swift Tests/OrchestraCoreTests/WorktreeRegistryTests.swift
git commit -m "feat(worktree): single removal policy in release()"
```

---

## Task 3.5: Route all teardown through `release()` + make `WorktreeManager` private

**Files:**
- Modify: `Sources/OrchestraCore/WorktreeRegistry.swift` (absorb `WorktreeManager`), delete `Sources/OrchestraCore/WorktreeManager.swift`, `Sources/OrchestraCore/Protocols.swift:67` (move the conformance), `Sources/OrchestraCore/OrchestraService.swift` (`:14`,`:60`,`:128`,`:147`,`:356`,`:390`,`:708-710`,`:739-746`,`:1023`), `Sources/OrchestraCore/OrchestraService+Borrow.swift`, `Sources/OrchestraCore/OrchestraService+Recovery.swift:248`, `Sources/orchestrad/main.swift:48-49`, `Tests/OrchestraCoreTests/Stubs.swift` (`TestEnv` wiring)
- Test: `Tests/OrchestraCoreTests/DaemonLifecycleTests.swift`; **migrate** every test naming the concrete `WorktreeManager` (see Step 3 list) — required for `swift test` to compile after privatization.

**Interfaces produced:** `OrchestraService` now holds a `WorktreeRegistry` (field named `worktrees`); the concrete `WorktreeManager` is unreachable outside `WorktreeRegistry.swift`.

### Step 1: Write the failing tests

- [ ] **`test_archiveWithSiblingKeepsTree`** in `DaemonLifecycleTests.swift` — two `.worktree` cards share a cwd; archiving one keeps the tree (routes through the registry's computed sibling check):

```swift
@Test func test_archiveWithSiblingKeepsTree() async throws {
    let (svc, _, worktrees, _, _, base) = TestEnv.make()
    _ = TestEnv.repo(base)
    let a = try await svc.spawn(SpawnInput(prompt: "", repo: "app", branch: "shared"))
    // A second DISTINCT card on the same branch (spawn only warns, then proceeds — OrchestraService.swift:325).
    // Its ensure adopts a's marked tree, so both cards share one cwd (a deliberate co-tenant).
    let b = try await svc.spawn(SpawnInput(prompt: "", repo: "app", branch: "shared"))
    #expect(a.id != b.id && a.cwd == b.cwd)
    try await svc.archive(a.id)
    #expect(!worktrees.removed.contains(a.cwd))   // non-archived sibling b still references it ⇒ kept
}
```

- [ ] **`test_spawnRollbackNeverForceRemovesSharedTree`** — the rollback removes via the safe `release(force:false)` policy, NEVER a blind `remove(force:true)`. **Design note:** the *sequential* single-spawn rollback removes a clean unshared tree, so the discriminating property here is the **force flag**: old code force-removes; new code routes through `release(force:false)`, whose guards then apply. The genuinely dangerous case — a *concurrent* second spawn that adopted this tree while it was in flight — is handled by the registry's in-flight holder set and proven deterministically by `test_releaseKeepsTreeWithInflightAdopter` (Task 3.4); a store-only sibling scan would miss that adopter, which is exactly why `release` also consults `inflight`. The deterministic trigger for THIS test: `TestEnv.make`'s repo dir is **not a git repo**, so `recordSpawnBase`'s `git config` write throws AFTER the stub `ensure` cut the tree — exactly the rollback catch at `OrchestraService.swift:389`.

```swift
@Test func test_spawnRollbackNeverForceRemovesSharedTree() async throws {
    let (svc, _, worktrees, _, _, base) = TestEnv.make()
    _ = TestEnv.repo(base)   // plain dir, NOT a git repo ⇒ recordSpawnBase throws post-ensure
    let nbPath = worktrees.path(repo: "app", branch: "nb")   // the returned stub computes the same path the registry does
    await #expect(throws: (any Error).self) {
        _ = try await svc.spawn(SpawnInput(prompt: "", repo: "app", branch: "nb", base: "main"))
    }
    // The fresh tree WAS reclaimed (clean, unshared) — but through release(force:FALSE), not remove(force:true).
    #expect(worktrees.removedForce.contains { $0.path == nbPath && $0.force == false })
    #expect(!worktrees.removedForce.contains { $0.path == nbPath && $0.force == true })
}
```
**Discrimination:** on OLD code the rollback calls `worktrees.remove(worktree: ensured.worktree, force: true)` → `removedForce` records `(nbPath, true)` → the second `#expect` fails → RED. After routing through `release(force:false)`, the removal records `(nbPath, false)` → GREEN. Combined with Task 3.4's `test_releaseNeverRemovesWhileReferenced`/`…DirtyWithoutForce`, this proves the rollback can never destroy a referenced or dirty tree.

### Step 2: Run → RED

- [ ] Run: `swift test --filter DaemonLifecycleTests` → FAIL (still the old ad-hoc `worktrees.remove(force:true)` rollback / sibling scan).

### Step 3: Make `WorktreeManager` private to the registry file (+ migrate every test that names it)

Making `WorktreeManager` `fileprivate` breaks **every** test that names the concrete type — `@testable import` cannot see a `fileprivate` symbol. `swift test` must stay green, so migrate ALL of them in this step BEFORE `git rm`. Verified callers (grep `Tests` for `WorktreeManager`):
`WorktreeTests.swift` (run-seam timeout, PR3a), `IntegrationTests/WorktreeManagerTests.swift` (real-git ensure/remove/borrow/isDirty), `IntegrationTests/E2EBinaryTests.swift:42`, `RemoteSpawnTests.swift:16,31`, `SpawnBaseTests.swift`, `SpawnBaseValidationTests.swift`, `BorrowLifecycleTests.swift`, `Stubs.swift:388` (`makeReal`).

- [ ] **Move** the `WorktreeManager` struct body from `WorktreeManager.swift` into `WorktreeRegistry.swift` as `fileprivate struct WorktreeManager: Sendable { ... }`; move `extension WorktreeManager: WorktreeManaging {}` there too (delete from `Protocols.swift:67`). Delete `Sources/OrchestraCore/WorktreeManager.swift`.
- [ ] **Add an internal run-seam initializer to `WorktreeRegistry`** so the timeout assertions can inject a recorder without naming the concrete type (keeps `WorktreeManager` unnameable outside the file):

```swift
/// Test seam: inject the timed `run` closure into the (fileprivate) manager. Lets `WorktreeTests`'
/// bounded-git assertions survive privatization without exposing `WorktreeManager`.
internal init(config: Config, resolver: PathResolver? = nil,
              run: @escaping @Sendable (_ argv: [String], _ timeout: Duration) throws -> ProcResult,
              borrowsPath: String = Config.borrowsPath, markersDir: String = Config.worktreeMarkersDir) {
    let r = resolver ?? PathResolver(config: config)
    self.config = config; self.resolver = r
    self.manager = WorktreeManager(config: config, resolver: r, run: run)
    self.borrowsPath = borrowsPath; self.markersDir = markersDir
}
```
- [ ] **Migrate the tests:**
  - `WorktreeTests.swift` (bounded-git run-seam): rewrite `WorktreeManager(config:resolver:nil,run:{rec.run})` → `WorktreeRegistry(config:cfg, run:{try rec.run($0,$1)})` and drive through the registry. **All three PR3a coverage points must survive** (do not drop them):
    - `test_worktreeAddIsBounded`: drive `reg.ensure(...)`/`reg.ensureBorrow(...)`, assert the recorded `add` used `.seconds(worktreeAddTimeout)`.
    - `test_worktreeAddTimesOut`: an absurd `worktreeAddTimeout` makes `reg.ensure` throw.
    - **`test_pruneIsBounded`** (the `remove` + fallback `prune` `controlTimeout` guard): drive it through `reg.release(cardId:cards:force:true)`. **Critical:** the run-seam `ensure` records `git worktree add` but does NOT physically create the dir, and `release`'s `guard fileExists(wt)` short-circuits before `manager.remove` — so, exactly like the original `WorktreeTests` at `:82`, you must **`mkdir` the `wt` dir** (and stamp its marker — call `ensure`'s marker path, or use the public `stampMarkers([wt])`) after `ensure` so `release` reaches `manager.remove`. Have the recorder return non-ok on `worktree remove` (and delete the dir) so the fallback `prune` fires; assert **both** the `remove` and the `prune` used `.seconds(controlTimeout)`. (Release routes to `manager.remove`, which contains the bounded remove+prune — this is where that coverage now lives.)
  - `IntegrationTests/WorktreeManagerTests.swift`: retarget each `WorktreeManager(config:)` → `WorktreeRegistry(config:)` and call the registry API (`ensure`/`release`/`ensureBorrow`/`isDirty` via the stub isn't real-git — for real-git dirty/remove behaviors, drive `ensure` then inspect the filesystem). Rename the file to `WorktreeRegistryIntegrationTests.swift`.
  - `RemoteSpawnTests.swift`, `SpawnBaseTests.swift`, `SpawnBaseValidationTests.swift`, `BorrowLifecycleTests.swift`, `E2EBinaryTests.swift:42`, `Stubs.swift:388` (`makeReal`): replace `WorktreeManager(config:…)` with `WorktreeRegistry(config:…, resolver:…)` (real manager inside). Where these construct a full `svc`, pass the registry as `worktrees:`. `makeReal` returns the same tuple; the registry is injected into the service.
  - **Direct-`svc`-with-stub constructions** (they build `OrchestraService(config:…, worktrees: StubWorktrees(...))` WITHOUT `TestEnv`): `ReadinessSignalTests.swift:70-72`, `CodexAdapterTests.swift:265-268`, `CodexRolloutTests.swift:223-226` and `:268-271`. After the init type change (`worktrees: WorktreeRegistry?`), a bare `StubWorktrees` no longer satisfies the parameter. Add a tiny `TestEnv` helper and use it at each site:
    ```swift
    /// Wrap a stub worktree manager in a registry with test-local (base-relative) borrows/markers paths.
    static func registry(_ stub: StubWorktrees, base: String, config: Config) -> WorktreeRegistry {
        WorktreeRegistry(config: config, manager: stub,
                         borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")
    }
    ```
    Then each site: `let stub = StubWorktrees(root: config.worktreesRoot); … worktrees: TestEnv.registry(stub, base: base, config: config)`. (Grep `Tests` for `OrchestraService(config:` + `worktrees:` to be sure none are missed.)
- [ ] **Cleanup:** `pruneOrphanBorrows` (its only caller was the old `sweepOrphanBorrows`, now the registry's guarded loop via `orphanBorrowPaths`) is dead — remove it from the `WorktreeManaging` protocol, `WorktreeManager`, and `StubWorktrees`.
- [ ] **Grep BOTH trees** to prove privatization: `grep -rn "WorktreeManager\b" Sources Tests | grep -v "WorktreeRegistry.swift"` returns nothing (the `\b` word-boundary excludes `WorktreeManaging`; the only remaining `WorktreeManager` matches live inside `WorktreeRegistry.swift`). That is the compile-time guarantee, machine-checked.

### Step 4: Switch `OrchestraService` to the registry

- [ ] `OrchestraService.swift:14`: change the field to `var worktrees: WorktreeRegistry`. It MUST stay `var` — `setConfig` (`:1023`) reassigns it.
- [ ] `:60`: delete `var borrowedWorktrees: [UUID: String] = [:]` (absorbed into the registry).
- [ ] `:128`/`:147`: change the init param to `worktrees: WorktreeRegistry? = nil` and default to `WorktreeRegistry(config: config, resolver: r)`.
- [ ] `:1023` (the `setConfig` rebuild): `worktrees = WorktreeManager(...)` → `worktrees = WorktreeRegistry(config: config, resolver: resolver)`. (This rebuild uses the production `Config.borrowsPath`/`worktreeMarkersDir` defaults; no current test calls `setConfig` after injecting custom registry paths — acceptable.)
- [ ] `:356` spawn ensure: `let ensured = try worktrees.ensure(repo: realRepo, branch: input.branch, base: ensureBase)` → `let ensured = try await worktrees.ensure(repo: realRepo, branch: input.branch, cardId: id, base: ensureBase)`. (`id` is the local minted before this point.) `ensured.worktree` → `ensured.path` at the use sites.
- [ ] `:390` spawn rollback: replace `try? worktrees.remove(worktree: ensured.worktree, force: true)` with a routed release. Build a synthetic card for the not-yet-persisted spawn (only `id`/`cwd`/`origin`/`archived` are read by `release`):

```swift
} catch {
    let synthetic = Task(id: id, title: input.branch, repo: realRepo, branch: input.branch,
                         cwd: ensured.path, origin: .worktree, access: input.access,
                         model: AgentModel(id: input.model ?? ""), startIn: input.startIn ?? .plan,
                         column: (input.startIn ?? .plan).column, order: 0,
                         phase: .creatingWorktree, initialPrompt: "")
    _ = try? await worktrees.release(cardId: id, cards: (await store.all()) + [synthetic], force: false)
    if !ensured.branchExisted {
        _ = try? Proc.run(["git", "-C", realRepo, "branch", "-D", input.branch])
    }
    throw OrchestraError.io("spawn rolled back (worktree/branch removed): \(error)")
}
```
> The branch `-D` stays a direct `Proc.run` — branch deletion is not a worktree op and is out of the registry's scope. The tree removal (the data-loss risk) now goes through `release(force:false)`, so a shared tree is never force-dropped.

- [ ] `:708-710` archive borrow sweep: replace the `borrowedWorktrees[id]` block with `try? await worktrees.releaseBorrow(borrowerCardId: id)`.
- [ ] `:733-760` archive worktree removal: replace the `.worktree` arm's ad-hoc sibling scan + `worktrees.remove(...)` with `try? await worktrees.release(cardId: id, cards: await store.all(), force: false)`. Keep the `.scratch`/`.borrowed` arms unchanged (scratch rm-rf and borrow no-op are not worktree ops). Delete the `let siblings = ...` scan (`:739-741`).

- [ ] `OrchestraService+Borrow.swift`:
  - `borrow(ref:)`: keep the lineage/remote/live-card guards; replace the `borrowedWorktrees` ownership check + `worktrees.borrow` + registration with `let w = try await worktrees.ensureBorrow(repo: child.repo, parentBranch: link.parent, borrowerCardId: child.id)` and use `w.path` in the activity message. (The registry now enforces exactly-one-borrower + persistence.)
  - `release(ref:)`: replace the body with `try await worktrees.releaseBorrow(borrowerCardId: child.id)` + the activity emit.
  - `sweepOrphanBorrows()`: replace with `await worktrees.sweepOrphanBorrows(cards: await store.all())`. Remove the `borrowedWorktrees.removeAll()`.
- [ ] `OrchestraService+Recovery.swift:248` reopen: `_ = try worktrees.ensure(repo: t.repo, branch: t.branch)` → `_ = try await worktrees.ensure(repo: t.repo, branch: t.branch, cardId: t.id)`.
- [ ] **Boot marker stamping + sweep** (`orchestrad/main.swift:48-49`): after load, stamp markers for pre-upgrade worktree trees so a migrated board is adoptable, then sweep:

```swift
await service.sweepOrphanScratch()
await service.stampMigratedWorktreeMarkersOnce()  // ONE-TIME (sentinel-gated) marker migration
await service.sweepOrphanBorrows()                // now delegates to registry.sweepOrphanBorrows(cards:)
```
`stampMarkers` must be **one-time**, not every-boot: stamping on every boot would, once Stage 4's non-blocking spawn lands, mark a half-created (`.relaunching`/mid-materialization) dir adoptable (bug #12). Gate it on a persisted sentinel inside the registry so it runs exactly once — at the first boot after upgrade, when the daemon was fully down and every persisted tree is at-rest/complete. Change `stampMarkers` to self-gate:

```swift
// in WorktreeRegistry:
private var markersMigrationSentinel: String { "\(markersDir)/.migrated" }
/// ONE-TIME. Stamps markers for the given existing trees, then drops a sentinel so later boots no-op.
/// Runs only at the first post-upgrade boot, when the daemon was down and every persisted tree is
/// at-rest/complete — so it can never mark an in-flight (Stage-4 non-blocking) half-checkout adoptable.
public func stampMarkers(forMigratedPaths paths: [String]) async {
    guard !FileManager.default.fileExists(atPath: markersMigrationSentinel) else { return }
    for p in paths where FileManager.default.fileExists(atPath: p) { writeMarker(p) }
    try? FileManager.default.createDirectory(atPath: markersDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: markersMigrationSentinel, contents: Data())
}
```
Add the boot wrapper to `OrchestraService`. It MUST be `public` — `orchestrad` is a separate executable target (`Package.swift`) and calls it from `main.swift`; the existing boot calls (`sweepOrphanScratch`, `sweepOrphanBorrows`, `recoverSessions`) are all `public`:

```swift
/// Boot: one-time marker migration for pre-upgrade (marker-less) worktree trees. Non-archived worktree
/// cards only; being-born phases excluded as defense-in-depth (they can't exist at the first post-upgrade
/// boot anyway — those phases are new). The registry's sentinel makes this a genuine no-op on every later boot.
public func stampMigratedWorktreeMarkersOnce() async {
    let paths = await store.all()
        .filter { !$0.archived && $0.origin == .worktree
                  && $0.phase.kind != .creatingWorktree && $0.phase.kind != .launching && $0.phase.kind != .relaunching }
        .map(\.cwd)
    await worktrees.stampMarkers(forMigratedPaths: paths)
}
```
> **Test:** in `WorktreeRegistryTests`, extend `test_migrationStampsMarkers` to assert idempotency — a SECOND `stampMarkers` call (e.g. after creating a new marker-less dir) does NOT stamp the new dir (sentinel gate): `#expect(try await reg.ensure(...).created)` for a dir added post-migration (i.e. it is pruned/recreated, not adopted).
> **Note (Stage 4 hand-off):** the sentinel gate means non-blocking spawn never re-triggers stamping; no per-boot half-checkout hazard remains. Keep the sentinel.

### Step 5: Update `TestEnv` (Stubs.swift)

- [ ] In `TestEnv.make`/`remake`/`makeReal`, construct a `WorktreeRegistry` with **base-relative** borrows/markers paths (all three MUST use `base + "/…"`, else a `make()`-spawned tree's marker under `base` is invisible to a `remake()` registry pointed at the real `Config.worktreeMarkersDir`, and `release` would keep a tree the test expects removed) and pass it as `worktrees:`:
  - `make`: `let registry = WorktreeRegistry(config: config, manager: worktrees, borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")` then `OrchestraService(..., worktrees: registry, ...)`. Keep returning the underlying `StubWorktrees` (tests still assert on `.removed`/`.ensured`/`.removedForce`).
  - `remake`: identical wiring — `WorktreeRegistry(config: config, manager: worktrees, borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")` — so a restart reads the SAME markers/borrows the original `make()` wrote (this is what makes `test_borrowRegistrationSurvivesRestart`-style service tests and marker adoption survive the remake).
  - `makeReal`: `let registry = WorktreeRegistry(config: config, resolver: resolver, borrowsPath: base + "/borrows.json", markersDir: base + "/worktree-markers")` (real manager inside) then inject.
- [ ] Fix any test that called `svc`'s worktree paths synchronously to `await` the registry helpers (`worktrees.path`/`borrowPath` are `nonisolated`, so most need no change).

### Step 6: Run → GREEN

- [ ] Run: `swift test` (full). Expected: PASS. Fix fallout (async call sites, `ensured.worktree`→`.path`, deleted `borrowedWorktrees` readers).
- [ ] **Compile-time guarantee is now enforced by the build itself:** grep to prove no code outside the registry file references the concrete type: `grep -rn "WorktreeManager" Sources | grep -v WorktreeRegistry.swift` should return nothing (only `WorktreeManaging` the protocol, and `WorktreeRegistry`, remain elsewhere).

### Step 7: Commit

```bash
git rm Sources/OrchestraCore/WorktreeManager.swift
git add -A
git commit -m "refactor(worktree): route all teardown through WorktreeRegistry.release"
```

---

## Task 3.6: Docs

**Files:** `docs/04-cards-worktrees-sessions.md`, `docs/09-design-decisions.md`

- [ ] Update `docs/04-cards-worktrees-sessions.md#worktrees`: describe the `WorktreeRegistry` as the sole owner of worktree + borrow lifecycle — serialized `ensure`, the materialized marker (a sentinel *outside* the tree gating adoption), on-demand sibling counts (a `dead` card holds its reference; only `archived` releases), the one `release()` removal policy and its fail-safe guards, and persisted borrow registrations.
- [ ] Add to `docs/09-design-decisions.md`: (1) marker lives outside the tree + why (git-status/byte-intact); (2) `created ≡ marker present`; (3) actor-mailbox serialization (no per-branch lock); (4) owned-roots = worktrees root; (5) persisted borrows survive a daemon-only crash; (6) conservative-mode seam left for Stage 4.
- [ ] Also fold the as-built deviations into the vault (`notes/designs/lifecycle-convergence/02-contract.md` + `03-implementation.md` Decisions tables) — see "Decisions to fold back" below.
- [ ] **Run:** `swift test` (docs-only, still green). Commit:

```bash
git add docs/ notes/designs/lifecycle-convergence/
git commit -m "docs(worktree): WorktreeRegistry — marker arms, on-demand siblings, persisted borrows"
```

---

## Decisions to fold back into the vault (mention in the merge-request)

| Decision (as built) | Why |
|---|---|
| **Marker lives OUTSIDE the worktree** (registry-owned metadata dir, path-encoded filename) | An in-tree sentinel would show as untracked in `git status` (every tree reads "dirty") and would mutate a dirty pre-upgrade tree, violating "survives byte-intact". |
| **`created` flag ≡ materialized marker present** | The registry writes a marker only after a complete checkout or an explicit migration stamp, so the marker is exactly the "we own/created this tree" signal `release`'s `created` guard needs — no separate stored bit. |
| **Serialization = the actor mailbox alone** (no per-branch keyed lock); `ensure` is `await`-free between marker-check and checkout | Simpler than a lock map; globally serializes worktree git ops (a conservative superset of "per branch"), acceptable for a single-user tool and matching the L2 contract's "actor mailbox = the serialization". |
| **Owned roots = under `config.worktreesRoot`** (covers `orch-borrow-*`); a stricter `assertUnderWorktreesRoot` gate precedes `assertAllowed` | `assertAllowed` also admits `reposRoot`, so path-escape rejection needs the stricter worktrees-root check. |
| **Borrows persisted as `[String:String]`** (uuidString→path) | Swift encodes `[UUID:String]` as a flat array; the string-keyed form is a clean JSON object. In-memory keeps `UUID` keys. |
| **`orphanBorrowPaths` (list) replaces `pruneOrphanBorrows` (list+remove)**; removal is the registry's liveness-guarded loop | The old boot-only prune force-removed EVERY `orch-borrow-*` dir; the liveness-guarded registry sweep must never yank a live borrower's tree, so listing and guarded removal are separated. |
| **`WorktreeManager.swift` deleted**; the struct is `fileprivate` inside `WorktreeRegistry.swift` | The compile-time "nothing outside the registry touches git worktree ops" requires same-file `fileprivate` (Swift has no cross-file module-private-to-one-type). |
| **Reuses PR3a Config knobs in OrchestraKit** | PR3a already added `worktreeAddTimeout`/`controlTimeout` there; the registry reuses them via the injected `WorktreeManager`. |
| **Accepted trade-off: a crash between checkout and marker-write leaks a dir** | `created ≡ marker` means a tree cut but not-yet-marked is never removed by `release` (it heals only if a later `ensure` prunes+recreates it). This is the fail-safe direction — leak a dir, never lose data — and is preferable to the alternative (a `created` bit that could authorize removal of an unverified tree). |
| **`sweepOrphanBorrows` requires POSITIVE terminal evidence** (present + archived) to reclaim a registered borrow; empty/partial `cards` ⇒ no-op | Fail-safe pledge: an absent borrower is ambiguous (partial store load), not proof-of-death — keep the tree. Truly-orphaned unregistered dirs are still reclaimed by the stray loop. |
| **Marker stamping is ONE-TIME (persisted sentinel), not every-boot** | Every-boot stamping would, under Stage 4 non-blocking spawn, mark a half-created (`.relaunching`/mid-materialization) dir adoptable (bug #12). The sentinel makes it run once at upgrade, when all trees are at-rest/complete. |
| **`WorktreeRegistry` gains an internal `run:` seam** so the PR3a bounded-git timeout tests survive privatization | Keeps `WorktreeManager` `fileprivate` (compile-time guarantee) while letting `@testable` tests inject a `run` recorder through the registry — no coverage lost. |
| **Every test naming `WorktreeManager` migrates to `WorktreeRegistry` in Task 3.5** | `@testable import` can't see a `fileprivate` type; the suite must compile after `git rm WorktreeManager.swift`. |
| **In-flight holder set in the registry** (`inflight: [path: Set<UUID>]`) so `release` keeps a tree a concurrent, not-yet-persisted spawn adopted | Once `ensure` is awaited, the service actor can interleave two same-branch spawns; a store-only sibling scan misses the in-flight adopter, so the first spawn's rollback could remove the tree out from under the second. The in-flight set is the reference that a store snapshot lacks; cleaned by the normal rollback/archive `release` paths. A `store.create`-failure window strands an entry until restart — fail-safe (keeps a tree) and restart-healed, not data-loss. Stage 4's persist-before-ensure makes it belt-and-suspenders. |
| **`stampMigratedWorktreeMarkersOnce()` is `public`** | `orchestrad` is a separate target and calls it from `main.swift`; internal methods aren't visible there. |

## Self-review checklist (run before requesting plan review)

1. **Spec coverage** — every named test maps to a task: ensure/marker/borrow (3.3), release battery (3.4), teardown routing + compile-time privacy (3.5), migration marker + dirty-byte-intact (3.3 Step 6), docs (3.6). ✔
2. **Placeholder scan** — every code step shows real code; the two `DaemonLifecycleTests` cases reference concrete assertions + the failure-injection pattern to mine. ✔
3. **Type consistency** — `Worktree{path,created,branchExisted}`, `ensure(repo:branch:cardId:base:)`, `release(cardId:cards:force:)`, `ensureBorrow(repo:parentBranch:borrowerCardId:)`, `releaseBorrow(borrowerCardId:)`, `sweepOrphanBorrows(cards:)`, `stampMarkers(forMigratedPaths:)` used identically across tasks. `ensured.path` (not `.worktree`) everywhere after 3.5. ✔
4. **Fail-safe arms** — dirty-never-removed (ensure throw + release keep), path-escape reject, marker-less-clean prune, on-demand siblings incl. dead holder, outside-owned-roots keep, persisted borrows survive restart — each has a named test. ✔
