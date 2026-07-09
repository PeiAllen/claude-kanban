# BT6 — Remote Tier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:test-driven-development, task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add the read-only remote-parent tier to the branch-tree feature: fetch a remote PR/branch as the parent baseline, watch it for merges, and redirect stacked children when the remote parent lands — behind a `gh` capability probe, with zero network in tests.

**Architecture:** A small value type `RemoteParentRef` canonicalizes the two remote base forms (`origin/<branch>`, `pr#<N>`). A `RemoteParents` actor owns the hardened remote git calls (`fetch`/`lsRemoteTip`) — every call carries `GIT_TERMINAL_PROMPT=0` + `GIT_ASKPASS=/usr/bin/false` + a `Proc` timeout so the daemon never hangs on a credential prompt. A `GhClient` protocol (real `GhProbe`, test `FakeGh`) gates `gh pr view`. The watch loop is a per-card `Task` in a cancellation dict on `OrchestraService` (the `diffStatDebounce` state pattern) running the detection ladder; the redirect reuses the BT5 `shipped` retarget shape. `resolvedParentRef` (the BT3 seam) maps remote forms to their fetched `refs/orch/parents/<name>` so all four diff consumers work unchanged.

**Tech Stack:** Swift 6, swift-testing (`#expect`/`@Test`), `Proc` argv git calls, real `file://` bare-repo fixtures (no network, no gh).

## Global Constraints

- **Design for BOTH Claude and Codex** — no `if agent == "claude"` branches; TreeDocs updates land in both `tree-skill.md` (Claude) and `tree-agents.md` (Codex).
- **No network, ever, in tests.** "Remote" = a local `git init --bare` repo added as `origin` (`file://`), with `refs/pull/N/head` hand-minted via `git update-ref` in the bare repo. `gh` is always faked.
- **Every remote git call** carries env `["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false"]` and a `Proc` timeout. Failures classify (tri-state), never hang, never busy-loop.
- **Read-only v1:** fetch baseline + watch + publish-child-as-stacked-PR. NO direct push-into-remote-parent from the daemon.
- **Canonical remote base syntax (documented in CLI help + catalog):** `origin/<branch>` for a same-repo remote branch; `pr#<N>` for a pull request. These are also the exact strings stored in `Task.parentBranch` / `branch.<child>.orchestra-parent`.
- **Never touch main or `plan/parent-card-branch-linking`.** Commit early and often on `impl/bt6-remote-tier`.
- Base is `plan/parent-card-branch-linking` (BT1–BT5+BT7 already merged). Diff/review against that ref.
- `swift test` must pass; the "SessionManager — real tmux" and E2E-binary suites may be ignored ONLY when they fail with PTY exhaustion ("fork failed: Device not configured").

---

## File Structure

**New files:**
- `Sources/OrchestraCore/RemoteParentRef.swift` — the canonical remote-ref value type (parse / refspec / private ref / canonical string).
- `Sources/OrchestraCore/RemoteParents.swift` — the `RemoteParents` actor: `fetch`, `lsRemoteTip`, hardened remote env.
- `Sources/OrchestraCore/GhProbe.swift` — `GhClient` protocol, `PrState`, real `GhProbe`.
- `Sources/OrchestraCore/OrchestraService+Remote.swift` — watch-loop lifecycle, detection ladder, remote redirect, startup rebuild.
- `Tests/OrchestraCoreTests/RemoteParentRefTests.swift`
- `Tests/OrchestraCoreTests/RemoteParentTests.swift` (fetch/lsRemoteTip over a bare-origin fixture)
- `Tests/OrchestraCoreTests/LadderTests.swift` (detection ladder + redirect with `FakeGh`)
- `Tests/OrchestraCoreTests/RemoteSpawnTests.swift` (remote spawn integration)
- `Tests/OrchestraCoreTests/RemoteWatchLoopTests.swift` (tick/backoff, no busy-loop)

**Modified files:**
- `Sources/OrchestraCore/OrchestraService+ParentRef.swift` — map remote forms → private ref.
- `Sources/OrchestraCore/WorktreeManager.swift` — accept a fully-qualified `refs/…` start-point.
- `Sources/OrchestraCore/OrchestraService.swift` — `remoteParents` actor + `remoteWatch` dict + spawn remote-base threading + `stopRemoteWatch` on archive.
- `Sources/OrchestraCore/OrchestraService+Tree.swift` — `setParent` remote-parent + `watch` handling.
- `Sources/OrchestraKit/CommandCatalog.swift` — `spawn.base` remote forms; `set-parent.watch`.
- `Sources/OrchestraCore/CommandRegistry.swift` — thread `watch` into `set-parent`.
- `Sources/orchestra/CLIRunner.swift` — `--watch` on `set-parent`.
- `Sources/orchestrad/main.swift` — call `rebuildRemoteWatches()` at startup.
- `Sources/OrchestraCore/Resources/tree-skill.md` + `tree-agents.md` — remote ship/restack section.
- `App/Views/SpawnSheet.swift` + `App-iOS/Views/SpawnSheet.swift` — remote base entry (build-verified; manual visual pass).

---

## Task 1: `RemoteParentRef` value type

The pure, side-effect-free heart of the tier: parse a canonical base string into a typed ref, and derive its fetch refspec / private ref / storage string. Everything else keys off this.

**Files:**
- Create: `Sources/OrchestraCore/RemoteParentRef.swift`
- Test: `Tests/OrchestraCoreTests/RemoteParentRefTests.swift`

**Interfaces:**
- Produces: `enum RemoteParentRef { case pullRequest(Int); case branch(String) }` with `static func parse(_:) -> RemoteParentRef?`, `var remoteSrc: String`, `var privateName: String`, `var privateRef: String`, `var canonical: String`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OrchestraCoreTests/RemoteParentRefTests.swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("RemoteParentRef — canonical remote base parsing")
struct RemoteParentRefTests {
    @Test("pr#N parses to a pull-request ref")
    func parsesPR() throws {
        let r = try #require(RemoteParentRef.parse("pr#12"))
        #expect(r == .pullRequest(12))
        #expect(r.remoteSrc == "refs/pull/12/head")
        #expect(r.privateName == "pr-12")
        #expect(r.privateRef == "refs/orch/parents/pr-12")
        #expect(r.canonical == "pr#12")
    }

    @Test("origin/<branch> parses to a remote branch ref (slashes preserved)")
    func parsesBranch() throws {
        let r = try #require(RemoteParentRef.parse("origin/feature/foo"))
        #expect(r == .branch("feature/foo"))
        #expect(r.remoteSrc == "refs/heads/feature/foo")
        #expect(r.privateName == "feature/foo")
        #expect(r.privateRef == "refs/orch/parents/feature/foo")
        #expect(r.canonical == "origin/feature/foo")
    }

    @Test("a plain local name is NOT a remote ref")
    func localIsNil() {
        #expect(RemoteParentRef.parse("feature-a") == nil)
        #expect(RemoteParentRef.parse("") == nil)
        #expect(RemoteParentRef.parse("pr#") == nil)      // no number
        #expect(RemoteParentRef.parse("pr#abc") == nil)   // not a number
        #expect(RemoteParentRef.parse("origin/") == nil)  // empty branch
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RemoteParentRefTests`
Expected: FAIL — `RemoteParentRef` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/OrchestraCore/RemoteParentRef.swift
import Foundation

/// A remote parent in its canonical, storable form. Two shapes only (owner-resolved read-only tier):
/// a pull request (`pr#<N>`, fetched via `refs/pull/N/head`) or a same-repo remote branch
/// (`origin/<name>`, fetched via `refs/heads/<name>`). The canonical string round-trips through
/// `Task.parentBranch` / `branch.<child>.orchestra-parent`; `privateRef` is the local fetch
/// destination all diff consumers baseline against (never stored — always derived).
public enum RemoteParentRef: Equatable, Sendable {
    case pullRequest(Int)
    case branch(String)

    /// Classify a base/parent string. `nil` ⇒ a local branch name (caller keeps today's behavior).
    public static func parse(_ ref: String) -> RemoteParentRef? {
        if ref.hasPrefix("pr#") {
            let n = ref.dropFirst("pr#".count)
            guard let pr = Int(n), pr > 0 else { return nil }
            return .pullRequest(pr)
        }
        if ref.hasPrefix("origin/") {
            let b = String(ref.dropFirst("origin/".count))
            return b.isEmpty ? nil : .branch(b)
        }
        return nil
    }

    /// The LHS of the fetch refspec (the ref on `origin` we copy down).
    public var remoteSrc: String {
        switch self {
        case .pullRequest(let n): return "refs/pull/\(n)/head"
        case .branch(let b):      return "refs/heads/\(b)"
        }
    }

    /// The short name under `refs/orch/parents/` (`pr-N` keeps PRs from colliding with a branch).
    public var privateName: String {
        switch self {
        case .pullRequest(let n): return "pr-\(n)"
        case .branch(let b):      return b
        }
    }

    /// The local private ref the fetch lands in — the diff/tree baseline for a remote parent.
    public var privateRef: String { "refs/orch/parents/\(privateName)" }

    /// The canonical string stored on the card / in git config.
    public var canonical: String {
        switch self {
        case .pullRequest(let n): return "pr#\(n)"
        case .branch(let b):      return "origin/\(b)"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RemoteParentRefTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/RemoteParentRef.swift Tests/OrchestraCoreTests/RemoteParentRefTests.swift
git commit -m "feat(bt6): RemoteParentRef canonical remote base value type"
```

---

## Task 2: `RemoteParents` actor — hardened fetch / lsRemoteTip

The isolated remote git tier. `fetch` copies the remote ref into `refs/orch/parents/<name>` with a force refspec (survives remote history rewrites) and returns the fetched OID. `lsRemoteTip` returns a **tri-state**: OID, definitively-gone (exit 0 + empty), or unavailable (any error) — never conflating a deleted branch with a network/auth failure. Every call is hardened against credential prompts.

**Files:**
- Create: `Sources/OrchestraCore/RemoteParents.swift`
- Test: `Tests/OrchestraCoreTests/RemoteParentTests.swift`

**Interfaces:**
- Consumes: `RemoteParentRef` (Task 1), `Proc`.
- Produces:
  - `static func remoteEnv() -> [String: String]` (== `["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false"]`)
  - `enum RemoteTip: Equatable { case oid(String); case gone; case unavailable }`
  - `actor RemoteParents { func fetch(repo:, _ ref: RemoteParentRef) throws -> String; func lsRemoteTip(repo:, _ ref: RemoteParentRef) -> RemoteTip }`

- [ ] **Step 1: Write the failing test** — fetch a PR ref off a bare `file://` origin, assert it lands in `refs/orch/parents/pr-N`, survives a remote rewrite, and that `remoteEnv` is hardened.

```swift
// Tests/OrchestraCoreTests/RemoteParentTests.swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("RemoteParents — fetch/lsRemoteTip over a bare file:// origin (no network)")
struct RemoteParentTests {

    @discardableResult
    static func git(_ dir: String, _ a: String...) throws -> ProcResult {
        let r = try Proc.run(["git", "-C", dir] + a)
        #expect(r.ok, "git \(a.joined(separator: " ")) failed: \(r.stderr)")
        return r
    }
    static func write(_ dir: String, _ rel: String, _ s: String) throws {
        try s.write(toFile: dir + "/" + rel, atomically: true, encoding: .utf8)
    }
    static func oid(_ dir: String, _ ref: String) throws -> String {
        try Proc.run(["git", "-C", dir, "rev-parse", ref]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A working repo with a bare `origin`, plus a hand-minted `refs/pull/7/head` and a `feature-b`
    /// branch on the bare side. Returns (working repo path, bare path). No network.
    static func makeOriginWithPR() throws -> (repo: String, bare: String) {
        let tmp = NSTemporaryDirectory()
        let repo = tmp + "orch-rem-\(UUID().uuidString)"
        let bare = tmp + "orch-bare-\(UUID().uuidString).git"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "config", "user.email", "t@t"); try git(repo, "config", "user.name", "t")
        try write(repo, "a.txt", "one\n"); try git(repo, "add", "-A"); try git(repo, "commit", "-q", "-m", "base")
        try Proc.run(["git", "init", "--bare", "-q", bare])
        try git(repo, "remote", "add", "origin", "file://" + bare)
        try git(repo, "push", "-q", "origin", "main")
        // A PR head branch pushed under a normal ref, then re-pointed as refs/pull/7/head in the bare repo.
        try git(repo, "checkout", "-q", "-b", "pr-src")
        try write(repo, "p.txt", "pr work\n"); try git(repo, "add", "-A"); try git(repo, "commit", "-q", "-m", "pr work")
        try git(repo, "push", "-q", "origin", "pr-src:refs/heads/feature-b")
        let prTip = try oid(repo, "HEAD")
        try git(bare, "update-ref", "refs/pull/7/head", prTip)   // mint the PR ref on the bare side
        try git(repo, "checkout", "-q", "main")
        return (repo, bare)
    }

    @Test("remoteEnv disables credential prompts")
    func envHardened() {
        let e = RemoteParents.remoteEnv()
        #expect(e["GIT_TERMINAL_PROMPT"] == "0")
        #expect(e["GIT_ASKPASS"] == "/usr/bin/false")
    }

    @Test("fetch(pr#7) lands the PR head in refs/orch/parents/pr-7 and returns its OID")
    func fetchPR() async throws {
        let (repo, bare) = try Self.makeOriginWithPR()
        let prTip = try Proc.run(["git", "-C", bare, "rev-parse", "refs/pull/7/head"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let oid = try await RemoteParents().fetch(repo: repo, .pullRequest(7))
        #expect(oid == prTip)
        #expect(try Self.oid(repo, "refs/orch/parents/pr-7") == prTip)
    }

    @Test("force refspec survives a remote history rewrite")
    func fetchForce() async throws {
        let (repo, bare) = try Self.makeOriginWithPR()
        _ = try await RemoteParents().fetch(repo: repo, .pullRequest(7))
        // Rewrite the PR head to an unrelated commit (non-fast-forward).
        try Self.write(repo, "z.txt", "rewrite\n"); try Self.git(repo, "add", "-A")
        try Self.git(repo, "commit", "-q", "--amend", "-m", "rewritten")
        let newTip = try Self.oid(repo, "HEAD")
        try Self.git(bare, "update-ref", "refs/pull/7/head", newTip)
        let oid2 = try await RemoteParents().fetch(repo: repo, .pullRequest(7))
        #expect(oid2 == newTip)   // + refspec forced past the non-ff rewrite
    }

    @Test("lsRemoteTip returns the tip OID, and .gone for a deleted branch")
    func lsRemote() async throws {
        let (repo, bare) = try Self.makeOriginWithPR()
        let tip = try Self.oid(bare, "refs/heads/feature-b")
        #expect(await RemoteParents().lsRemoteTip(repo: repo, .branch("feature-b")) == .oid(tip))
        try Self.git(bare, "update-ref", "-d", "refs/heads/feature-b")   // delete on the remote
        #expect(await RemoteParents().lsRemoteTip(repo: repo, .branch("feature-b")) == .gone)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RemoteParentTests`
Expected: FAIL — `RemoteParents` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/OrchestraCore/RemoteParents.swift
import Foundation

/// Tri-state remote-tip result — a deleted branch (`gone`, exit 0 + empty) is NEVER conflated with a
/// network/auth failure (`unavailable`, any error). The watch loop treats them differently: `gone`
/// feeds the merge-heuristic ladder; `unavailable` just backs off.
public enum RemoteTip: Equatable, Sendable {
    case oid(String)
    case gone
    case unavailable
}

/// The isolated remote-git tier: private-ref fetches + `ls-remote` tip probes, hardened so a daemon
/// never blocks on a credential prompt. Every remote call runs with `GIT_TERMINAL_PROMPT=0` +
/// `GIT_ASKPASS=/usr/bin/false` and a `Proc` timeout. All ops are `Proc.run(["git","-C",repo,…])`.
public actor RemoteParents {
    public init() {}

    /// The env that neuters every interactive credential path (terminal prompt + askpass helper).
    public static func remoteEnv() -> [String: String] {
        ["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false"]
    }
    private static let timeout: Duration = .seconds(20)

    /// Copy `ref` from `origin` into `refs/orch/parents/<name>` with a `+` (force) refspec so a remote
    /// history rewrite is mirrored rather than rejected. Returns the fetched OID. Throws a classified
    /// `.io` on failure (never hangs — timeout + no prompts).
    public func fetch(repo: String, _ ref: RemoteParentRef) throws -> String {
        let refspec = "+\(ref.remoteSrc):\(ref.privateRef)"
        let r = try Proc.run(["git", "-C", repo, "fetch", "--no-tags", "origin", refspec],
                             env: Self.remoteEnv(), timeout: Self.timeout)
        guard r.ok else {
            throw OrchestraError.io(r.stderr.isEmpty ? "git fetch \(refspec) failed" : r.stderr)
        }
        let v = try Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref.privateRef])
        let oid = v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.ok, !oid.isEmpty else {
            throw OrchestraError.io("fetched \(ref.privateRef) but could not resolve its OID")
        }
        return oid
    }

    /// `git ls-remote origin <src>` → the tip OID, `.gone` (branch/PR head deleted), or `.unavailable`
    /// (any error: the daemon must not mistake an auth failure for a deletion).
    public func lsRemoteTip(repo: String, _ ref: RemoteParentRef) -> RemoteTip {
        guard let r = try? Proc.run(["git", "-C", repo, "ls-remote", "origin", ref.remoteSrc],
                                    env: Self.remoteEnv(), timeout: Self.timeout) else {
            return .unavailable
        }
        guard r.ok else { return .unavailable }
        let line = r.stdout.split(separator: "\n").first.map(String.init) ?? ""
        let oid = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) ?? ""
        return oid.isEmpty ? .gone : .oid(oid)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RemoteParentTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/RemoteParents.swift Tests/OrchestraCoreTests/RemoteParentTests.swift
git commit -m "feat(bt6): RemoteParents actor — hardened fetch + tri-state lsRemoteTip"
```

---

## Task 3: `GhClient` protocol + `GhProbe` + `PrState`

The `gh` capability probe, behind a protocol so tests inject `FakeGh`. `gh` absent ⇒ the ladder degrades one tier; never a hard dependency.

**Files:**
- Create: `Sources/OrchestraCore/GhProbe.swift`
- Test: extend `Tests/OrchestraCoreTests/LadderTests.swift` (created in Task 5) — the real `GhProbe.available` gate is asserted there; `PrState` decoding is unit-tested here.

**Interfaces:**
- Produces:
  - `struct PrState: Decodable, Equatable, Sendable { let state: String; let mergedAt: String?; let mergeCommit: MergeCommit?; let baseRefName: String; var merged: Bool }`
  - `protocol GhClient: Sendable { var available: Bool { get }; func prState(repo:, number:) -> PrState?; func prNumber(repo:, head:) -> Int?; func editBase(repo:, number:, base:) -> Bool }`
  - `struct GhProbe: GhClient` (real) with `static var toolAvailable: Bool`.

- [ ] **Step 1: Write the failing test** (add to a new `GhProbeTests.swift`)

```swift
// Tests/OrchestraCoreTests/GhProbeTests.swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("GhProbe — PrState decode + capability gate")
struct GhProbeTests {
    @Test("decodes gh pr view JSON (state/mergedAt/baseRefName) → merged")
    func decodeMerged() throws {
        let json = """
        {"state":"MERGED","mergedAt":"2026-07-07T00:00:00Z","mergeCommit":{"oid":"abc123"},"baseRefName":"main"}
        """.data(using: .utf8)!
        let st = try JSONDecoder().decode(PrState.self, from: json)
        #expect(st.state == "MERGED")
        #expect(st.baseRefName == "main")
        #expect(st.mergeCommit?.oid == "abc123")
        #expect(st.merged)
    }

    @Test("an OPEN PR is not merged")
    func decodeOpen() throws {
        let json = #"{"state":"OPEN","mergedAt":null,"mergeCommit":null,"baseRefName":"main"}"#.data(using: .utf8)!
        let st = try JSONDecoder().decode(PrState.self, from: json)
        #expect(!st.merged)
        #expect(st.baseRefName == "main")
    }

    @Test("GhProbe.available reflects whether gh is on PATH")
    func availabilityGate() {
        #expect(GhProbe().available == Proc.toolExists("gh"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GhProbeTests`
Expected: FAIL — `PrState`/`GhProbe` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/OrchestraCore/GhProbe.swift
import Foundation

/// A pull request's merge state, decoded from `gh pr view --json state,mergedAt,mergeCommit,baseRefName`.
public struct PrState: Decodable, Equatable, Sendable {
    public struct MergeCommit: Decodable, Equatable, Sendable { public let oid: String? }
    public let state: String            // "OPEN" | "MERGED" | "CLOSED"
    public let mergedAt: String?
    public let mergeCommit: MergeCommit?
    public let baseRefName: String      // the branch the PR targets (the grandparent on merge)

    /// GitHub marks a squash/rebase/merge landing as `state == MERGED` (squash-proof — unlike an
    /// ancestry check). `mergedAt` is a redundant belt-and-braces signal.
    public var merged: Bool { state == "MERGED" || mergedAt != nil }
}

/// The `gh` boundary, behind a protocol so the ladder is testable with `FakeGh` and `gh`'s absence is a
/// tier, not a mock gap. NEVER a hard dependency: `available == false` degrades the ladder one step.
public protocol GhClient: Sendable {
    var available: Bool { get }
    func prState(repo: String, number: Int) -> PrState?
    /// The PR number whose head is `head` (for repairing a published child's base). nil if none/unknown.
    func prNumber(repo: String, head: String) -> Int?
    /// Repoint a published PR's base branch. Best-effort; false on any failure.
    func editBase(repo: String, number: Int, base: String) -> Bool
}

/// The real probe. `repo` is a filesystem path; `gh` needs a slug or a `--repo` inside the repo dir, so
/// every call runs with `cwd: repo` and lets `gh` infer the slug from `origin`. Hardened env (no prompts).
public struct GhProbe: GhClient {
    public init() {}

    public static var toolAvailable: Bool { Proc.toolExists("gh") }
    public var available: Bool { Self.toolAvailable }

    private static func env() -> [String: String] {
        RemoteParents.remoteEnv().merging(["GH_PROMPT_DISABLED": "1"]) { a, _ in a }
    }

    public func prState(repo: String, number: Int) -> PrState? {
        guard let r = try? Proc.run(
            ["gh", "pr", "view", String(number), "--json", "state,mergedAt,mergeCommit,baseRefName"],
            cwd: repo, env: Self.env(), timeout: .seconds(20)), r.ok,
            let data = r.stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PrState.self, from: data)
    }

    public func prNumber(repo: String, head: String) -> Int? {
        struct Row: Decodable { let number: Int }
        guard let r = try? Proc.run(
            ["gh", "pr", "list", "--head", head, "--state", "open", "--json", "number", "--limit", "1"],
            cwd: repo, env: Self.env(), timeout: .seconds(20)), r.ok,
            let data = r.stdout.data(using: .utf8),
            let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        return rows.first?.number
    }

    public func editBase(repo: String, number: Int, base: String) -> Bool {
        (try? Proc.run(["gh", "pr", "edit", String(number), "--base", base],
                       cwd: repo, env: Self.env(), timeout: .seconds(20)))?.ok ?? false
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GhProbeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/GhProbe.swift Tests/OrchestraCoreTests/GhProbeTests.swift
git commit -m "feat(bt6): GhClient protocol + GhProbe + PrState decode"
```

---

## Task 4: `resolvedParentRef` maps remote forms → private ref

The single BT3 seam now resolves a remote parent string to its fetched `refs/orch/parents/<name>`, so all four diff consumers (footer, inspectors, Zed, notes) baseline correctly against a remote parent with no per-consumer change.

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+ParentRef.swift`
- Test: `Tests/OrchestraCoreTests/RemoteParentRefTests.swift` (extend)

**Interfaces:**
- Consumes: `RemoteParentRef.parse`, `RemoteParentRef.privateRef`.

- [ ] **Step 1: Write the failing test** (append to `RemoteParentRefTests`)

```swift
    @Test("resolvedParentRef maps remote forms to the private fetch ref; local is identity")
    func resolvesToPrivateRef() async throws {
        let env = TestEnv.make()
        // A worktree card whose parentBranch is a remote form resolves to refs/orch/parents/…
        let remote = try await env.svc.spawn(SpawnInput(prompt: "x", repo: TestEnv.repo(env.base), branch: "c1"))
        // Directly exercise the pure mapping via a helper task shape:
        var t = remote
        t.parentBranch = "pr#7"
        #expect(env.svc.resolvedParentRef(t) == "refs/orch/parents/pr-7")
        t.parentBranch = "origin/feature-b"
        #expect(env.svc.resolvedParentRef(t) == "refs/orch/parents/feature-b")
        t.parentBranch = "feature-a"
        #expect(env.svc.resolvedParentRef(t) == "feature-a")   // local unchanged
        t.parentBranch = nil
        #expect(env.svc.resolvedParentRef(t) == nil)
    }
```

> Note: `resolvedParentRef` is a synchronous, `internal` method on `OrchestraService`; call it directly. If `TestEnv.make()`/`TestEnv.repo` need a git repo, reuse the `LineageSpawnTests.gitRepo` idiom; otherwise construct a bare `Task` value directly to avoid a spawn.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RemoteParentRefTests/resolvesToPrivateRef`
Expected: FAIL — remote form currently returned as identity (`pr#7` not mapped).

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/OrchestraCore/OrchestraService+ParentRef.swift  (replace the body)
extension OrchestraService {
    func resolvedParentRef(_ task: Task) -> String? {
        guard let pb = task.parentBranch, !pb.isEmpty else { return nil }
        // Remote parents (origin/<b>, pr#<N>) baseline against their fetched private ref; a local
        // parent is its own branch name (identity — byte-identical to pre-remote behavior).
        if let remote = RemoteParentRef.parse(pb) { return remote.privateRef }
        return pb
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RemoteParentRefTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+ParentRef.swift Tests/OrchestraCoreTests/RemoteParentRefTests.swift
git commit -m "feat(bt6): resolvedParentRef maps remote parents to refs/orch/parents"
```

---

## Task 5: `WorktreeManager.ensure` accepts a fully-qualified start-point

A remote-base spawn fetches into `refs/orch/parents/<name>` first, then hands that ref to `ensure` as the new branch's start-point. Local bases keep the `refs/heads/<base>` pinning unchanged (BT2 tests stay green).

**Files:**
- Modify: `Sources/OrchestraCore/WorktreeManager.swift`
- Test: `Tests/OrchestraCoreTests/RemoteSpawnTests.swift` (created here; grows in Task 7)

**Interfaces:**
- Consumes: same `ensure(repo:branch:base:)` signature; `base` may now be a `refs/…` ref.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OrchestraCoreTests/RemoteSpawnTests.swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Remote spawn — ensure(base:) with a fetched private ref")
struct RemoteSpawnTests {
    // reuse the bare-origin fixture builder
    static func makeOriginWithPR() throws -> (repo: String, bare: String) {
        try RemoteParentTests.makeOriginWithPR()
    }

    @Test("ensure starts a new branch at a fetched refs/orch/parents ref")
    func ensureFromPrivateRef() async throws {
        let (repo, _) = try Self.makeOriginWithPR()
        let oid = try await RemoteParents().fetch(repo: repo, .pullRequest(7))
        let wm = WorktreeManager(config: Config(reposRoot: repo))  // adapt to the real Config init
        let out = try wm.ensure(repo: repo, branch: "childR", base: "refs/orch/parents/pr-7")
        #expect(out.created)
        let head = try Proc.run(["git", "-C", out.worktree, "rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == oid)   // new branch starts exactly at the fetched PR tip
    }

    @Test("an unknown refs/ start-point throws and leaves no worktree dir")
    func unknownPrivateRef() throws {
        let (repo, _) = try Self.makeOriginWithPR()
        let wm = WorktreeManager(config: Config(reposRoot: repo))
        #expect(throws: (any Error).self) {
            try wm.ensure(repo: repo, branch: "childX", base: "refs/orch/parents/pr-999")
        }
        #expect(!FileManager.default.fileExists(atPath: wm.path(repo: repo, branch: "childX")))
    }
}
```

> Note: adapt `Config(reposRoot:)`/`WorktreeManager` construction to the real initializers (check `TestEnv`/`SpawnBaseTests` for the exact `Config` factory the suite uses — likely `TestEnv.make().config` or a `Config` test helper). Keep `repo` allowlisted so `assertAllowed` passes.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RemoteSpawnTests/ensureFromPrivateRef`
Expected: FAIL — `ensure` validates via `branchExists` and pins `refs/heads/`, so a `refs/orch/…` base is rejected as "base branch not found".

- [ ] **Step 3: Write minimal implementation** (in `WorktreeManager.ensure`, the new-branch else arm)

```swift
        } else {
            var a = ["git", "-C", realRepo, "worktree", "add", "-b", branch, wt]
            if let base = base?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
                if base.hasPrefix("refs/") {
                    // A fully-qualified ref (a fetched remote private ref, refs/orch/parents/…). Validate
                    // it resolves, then use it verbatim as the start-point — no refs/heads/ pinning.
                    guard refExists(repo: realRepo, ref: base) else {
                        throw OrchestraError.invalidParams("base ref not found: \(base)")
                    }
                    a.append(base)
                } else {
                    // Local branch base (BT2): validate + pin to refs/heads/ (avoid tag disambiguation).
                    guard branchExists(repo: realRepo, branch: base) else {
                        throw OrchestraError.invalidParams("base branch not found: \(base)")
                    }
                    a.append("refs/heads/\(base)")
                }
            }
            argv = a
        }
```

Add the helper next to `branchExists`:

```swift
    func refExists(repo: String, ref: String) -> Bool {
        let r = try? Proc.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", ref])
        return r?.ok ?? false
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RemoteSpawnTests`
Then regression: `swift test --filter SpawnBaseTests` (BT2 local path must stay green).
Expected: PASS both.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/WorktreeManager.swift Tests/OrchestraCoreTests/RemoteSpawnTests.swift
git commit -m "feat(bt6): ensure() accepts a fully-qualified refs/ start-point for remote bases"
```

---

## Task 6: Spawn remote-base threading + lineage recording

Wire the remote base end-to-end: `spawn` classifies `input.base`; a remote form fetches first, hands the private ref to `ensure`, and records lineage with the canonical remote string + `prNumber` + `watch: true`. `Task.parentBranch` gets the canonical remote form. (Watch is *started* in Task 7; this task records the state that Task 7's startup rebuild reads.)

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (the `.worktree` arm of `spawn`), `Sources/OrchestraCore/OrchestraService+Tree.swift` (add `recordSpawnRemoteBase`)
- Test: `Tests/OrchestraCoreTests/RemoteSpawnTests.swift` (extend)

**Interfaces:**
- Consumes: `RemoteParents.fetch` (Task 2), `RemoteParentRef` (Task 1).
- Produces: `func recordSpawnRemoteBase(repo:, branch:, ref: RemoteParentRef, oid: String) async throws -> String` — writes `ParentLink(parent: ref.canonical, base: oid, prNumber:, watch: true)`, returns `ref.canonical`.
- Adds stored property `let remoteParents = RemoteParents()` and `var remoteWatch: [UUID: _Concurrency.Task<Void, Never>] = [:]` on `OrchestraService` (the dict is used in Task 7).

- [ ] **Step 1: Write the failing test** (append to `RemoteSpawnTests`; use `TestEnv` with a real bare-origin repo)

```swift
    @Test("spawn(base: pr#7) fetches, starts the child at the PR tip, records remote lineage")
    func spawnRemoteBase() async throws {
        let (repo, _) = try Self.makeOriginWithPR()
        let env = TestEnv.make(allow: [repo])   // adapt to how the suite allowlists a repo
        let prTip = try await RemoteParents().fetch(repo: repo, .pullRequest(7))  // expected OID
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        #expect(t.parentBranch == "pr#7")                    // canonical remote form stored
        let link = try #require(await env.svc.lineage.read(repo: repo, branch: "childP"))
        #expect(link.parent == "pr#7")
        #expect(link.prNumber == 7)
        #expect(link.watch == true)                          // auto-watch on a remote-base spawn
        #expect(link.base == prTip)                          // recorded base = fetched PR tip
    }

    @Test("spawn(base: origin/feature-b) records a remote branch parent (no pr number)")
    func spawnRemoteBranchBase() async throws {
        let (repo, _) = try Self.makeOriginWithPR()
        let env = TestEnv.make(allow: [repo])
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childB", base: "origin/feature-b"))
        #expect(t.parentBranch == "origin/feature-b")
        let link = try #require(await env.svc.lineage.read(repo: repo, branch: "childB"))
        #expect(link.prNumber == nil)
        #expect(link.watch == true)
    }
```

> Note: `TestEnv.make()` in the suite uses `StubWorktrees` (a fake worktree). Remote spawn needs the REAL `WorktreeManager` because the start-point ref must actually exist. Two options: (a) add a `TestEnv.make(realWorktrees: true, allow:)` variant that wires the real `WorktreeManager`, or (b) drive `spawn` against a `TestEnv` whose `worktrees` is real. Inspect `TestEnv`/`Stubs.swift` and pick the smallest wiring; the fetch+lineage assertions are the contract, not the fake-vs-real worktree.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RemoteSpawnTests/spawnRemoteBase`
Expected: FAIL — remote base treated as a local branch name (`ensure` rejects `pr#7`), no lineage recorded.

- [ ] **Step 3: Write minimal implementation**

In `OrchestraService.swift`, add stored properties (near `let lineage = BranchLineage()`):

```swift
    let remoteParents = RemoteParents()
    /// Per-card remote watch loops, cancellation-keyed (the diffStatDebounce state pattern).
    var remoteWatch: [UUID: _Concurrency.Task<Void, Never>] = [:]
    /// Injectable poll cadence (short values in tests to avoid real sleeps).
    var remoteWatchIntervals: (active: Duration, idle: Duration) = (.seconds(60), .seconds(300))
    /// The gh boundary (FakeGh in tests). Default: the real probe.
    var gh: any GhClient = GhProbe()
```

In the `.worktree` arm of `spawn`, replace the base handling:

```swift
            realRepo = try resolver.resolveRepo(input.repo)
            // Classify the base: a remote form (origin/<b>, pr#<N>) is fetched into a private ref FIRST,
            // and that ref becomes the new branch's start-point. A local base flows through unchanged.
            let remoteRef = input.base.flatMap { RemoteParentRef.parse($0) }
            var remoteFetchedOID: String? = nil
            var ensureBase = input.base
            if let remoteRef {
                remoteFetchedOID = try await remoteParents.fetch(repo: realRepo, remoteRef)
                ensureBase = remoteRef.privateRef
            }
            let ensured = try worktrees.ensure(repo: realRepo, branch: input.branch, base: ensureBase)
            cwd = ensured.worktree
            origin = .worktree
            if ensured.branchExisted {
                derivedParentBranch = await lineage.read(repo: realRepo, branch: input.branch)?.parent
            } else if let remoteRef, let oid = remoteFetchedOID {
                derivedParentBranch = try await recordSpawnRemoteBase(
                    repo: realRepo, branch: input.branch, ref: remoteRef, oid: oid)
            } else if let base = input.base?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
                derivedParentBranch = try await recordSpawnBase(repo: realRepo, branch: input.branch, base: base)
            }
```

In `OrchestraService+Tree.swift`, add next to `recordSpawnBase`:

```swift
    /// BT6 remote spawn-with-base: record lineage for a card whose branch was CREATED on a fetched
    /// remote private ref. Stores the canonical remote form (`origin/<b>` / `pr#<N>`) + prNumber, and
    /// opts the card into watching by default (owner: auto-on for a remote-base spawn). `oid` is the
    /// fetched tip — the redirect/restack anchor.
    func recordSpawnRemoteBase(repo: String, branch: String,
                               ref: RemoteParentRef, oid: String) async throws -> String {
        let pr: Int? = { if case .pullRequest(let n) = ref { return n }; return nil }()
        try await lineage.set(repo: repo, branch: branch,
                              link: ParentLink(parent: ref.canonical, base: oid, prNumber: pr, watch: true))
        return ref.canonical
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RemoteSpawnTests`
Expected: PASS. Regression: `swift test --filter SpawnBaseTests` and `swift test --filter LineageSpawnTests`.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/OrchestraService+Tree.swift Tests/OrchestraCoreTests/RemoteSpawnTests.swift
git commit -m "feat(bt6): thread remote base through spawn — fetch + remote lineage recording"
```

---

## Task 7: Detection ladder + remote redirect

The decision core: given a remote tip observation + the `gh` probe, decide MERGED / warning / merged-by-ancestry / nothing, and apply the redirect (retarget this card onto the PR's `baseRefName`, keep the recorded base as the rebase anchor, nudge + wake, repair the child's PR base best-effort). Written as a pure-ish `remoteMergeStep` returning a typed outcome so it's testable with `FakeGh` over fixtures — the loop (Task 8) is a thin driver.

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Remote.swift` (created here)
- Test: `Tests/OrchestraCoreTests/LadderTests.swift`

**Interfaces:**
- Consumes: `RemoteParents`, `GhClient`/`FakeGh`, `RemoteParentRef`, `BranchLineage`, `Inbox`, `store`.
- Produces:
  - `enum RemoteMergeOutcome: Equatable { case none; case fetched; case redirected(grandparent: String); case warnedGone; case warnedAncestry }`
  - `func remoteMergeStep(cardId: UUID) async -> RemoteMergeOutcome` — one full ladder evaluation (ls-remote → fetch-on-move → ladder → redirect), idempotent.

- [ ] **Step 1: Write the failing test** — `FakeGh` + a bare-origin fixture; drive `remoteMergeStep` directly.

```swift
// Tests/OrchestraCoreTests/LadderTests.swift
import Foundation
import Testing
@testable import OrchestraCore

/// Scriptable gh double: a fixed PrState (or nil), an availability flag, and a recorded editBase call.
final class FakeGh: GhClient, @unchecked Sendable {
    let available: Bool
    var state: PrState?
    var headPR: Int?
    private(set) var editedBase: (number: Int, base: String)?
    init(available: Bool = true, state: PrState? = nil, headPR: Int? = nil) {
        self.available = available; self.state = state; self.headPR = headPR
    }
    func prState(repo: String, number: Int) -> PrState? { state }
    func prNumber(repo: String, head: String) -> Int? { headPR }
    func editBase(repo: String, number: Int, base: String) -> Bool { editedBase = (number, base); return true }
}

@Suite("Detection ladder — remote merge decision with FakeGh (no network, no gh)")
struct LadderTests {

    /// A spawned remote-parent card over a real bare origin, watch enabled. Returns (env, repo, card).
    static func remoteChild(pr: Int = 7) async throws -> (env: TestEnv, repo: String, card: Task) {
        let (repo, bare) = try RemoteParentTests.makeOriginWithPR()
        let env = TestEnv.make(allow: [repo])
        let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#\(pr)"))
        _ = bare
        return (env, repo, card)
    }

    @Test("gh MERGED ⇒ redirect fires with the PR baseRefName; child PR base repaired")
    func mergedRedirect() async throws {
        let (env, repo, card) = try await Self.remoteChild()
        await env.svc.setGh(FakeGh(available: true,
            state: PrState(state: "MERGED", mergedAt: "t", mergeCommit: .init(oid: "x"), baseRefName: "main"),
            headPR: 42))
        let outcome = await env.svc.remoteMergeStep(cardId: card.id)
        #expect(outcome == .redirected(grandparent: "main"))
        let link = try #require(await env.svc.lineage.read(repo: repo, branch: "childP"))
        #expect(link.parent == "origin/main")          // retargeted onto the remote base branch
        #expect(link.prNumber == nil)                  // no longer a PR parent
        let updated = try #require(await env.svc.store.get(card.id))
        #expect(updated.treeStat?.state == .restackNeeded)
        // inbox nudge enqueued (mentions rebase --onto + push --force-with-lease)
        #expect(await env.svc.inboxCount(card.id) >= 1)
    }

    @Test("gh unavailable + branch gone ⇒ warning tier, no redirect")
    func goneWarning() async throws {
        let (env, repo, card) = try await Self.remoteChild()
        await env.svc.setGh(FakeGh(available: false))
        // Delete the PR head on the bare side so lsRemoteTip → .gone
        // (find the bare via the origin url)
        let url = try Proc.run(["git", "-C", repo, "remote", "get-url", "origin"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "file://", with: "")
        try Proc.run(["git", "-C", url, "update-ref", "-d", "refs/pull/7/head"])
        let outcome = await env.svc.remoteMergeStep(cardId: card.id)
        #expect(outcome == .warnedGone)
        let link = try #require(await env.svc.lineage.read(repo: repo, branch: "childP"))
        #expect(link.parent == "pr#7")   // unchanged — no authoritative merge signal
    }

    @Test("squash merge (ancestry false) but gh MERGED ⇒ treated as merged")
    func squashMergedByGh() async throws {
        let (env, _, card) = try await Self.remoteChild()
        await env.svc.setGh(FakeGh(available: true,
            state: PrState(state: "MERGED", mergedAt: "t", mergeCommit: nil, baseRefName: "main")))
        let outcome = await env.svc.remoteMergeStep(cardId: card.id)
        #expect(outcome == .redirected(grandparent: "main"))
    }
}
```

> Note: this test needs three small service test-affordances — `setGh(_:)` (async setter for the injected `gh`), `inboxCount(_:)` (test read of the inbox depth), and possibly `TestEnv.make(allow:)`. If `inboxCount`/`setGh` are awkward to add, assert on the emitted `taskUpserted`/activity events the suite already captures, or read the inbox via the existing `InboxTests` accessor. Prefer reusing existing test hooks over adding new production API.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LadderTests`
Expected: FAIL — `remoteMergeStep`/`setGh` not defined.

- [ ] **Step 3: Write minimal implementation** — `OrchestraService+Remote.swift`

```swift
// Sources/OrchestraCore/OrchestraService+Remote.swift
import Foundation

/// The outcome of one ladder evaluation — a typed result so the loop stays thin and tests assert on it.
public enum RemoteMergeOutcome: Equatable, Sendable {
    case none               // tip unchanged, no conclusion
    case fetched            // tip moved, private ref refreshed, no merge conclusion
    case redirected(grandparent: String)
    case warnedGone         // branch vanished, gh couldn't confirm — warning surfaced
    case warnedAncestry     // merge-commit ancestry positive but base unknown (no gh) — warning surfaced
}

extension OrchestraService {
    /// Test seam: swap the gh boundary.
    func setGh(_ client: any GhClient) { self.gh = client }

    /// One full detection-ladder tick for a watched remote-parent card. Steps (stop at first conclusion):
    ///   1. `ls-remote` the parent tip. `.unavailable` ⇒ `.none` (backoff, no conclusion — never a
    ///      false "gone").
    ///   2. If the tip MOVED, `fetch` it into the private ref and `scheduleTreeStat` (stale badge tracks it).
    ///   3. LADDER:
    ///      (a) gh MERGED (authoritative, squash-proof) ⇒ redirect onto the PR's `baseRefName`.
    ///      (b) tip `.gone` + gh can't confirm ⇒ warning activity ("parent branch gone — likely merged").
    ///      (c) ancestry: the child's tip is contained in the fetched parent tip (merge-commit landing) ⇒
    ///          redirect using gh's baseRefName if available, else warn.
    /// Idempotent: after a redirect the link is no longer a PR, so a re-run takes tier (a) no path.
    @discardableResult
    func remoteMergeStep(cardId: UUID) async -> RemoteMergeOutcome {
        guard let t = await store.get(cardId), t.origin == .worktree, !t.archived,
              let link = await lineage.read(repo: t.repo, branch: t.branch),
              let ref = RemoteParentRef.parse(link.parent) else { return .none }

        let tip = await remoteParents.lsRemoteTip(repo: t.repo, ref)
        var fetchedTip: String? = nil
        var moved = false
        if case .oid(let o) = tip {
            let known = (try? Proc.run(["git", "-C", t.repo, "rev-parse", "--verify", "--quiet", ref.privateRef]))?
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if known != o {
                moved = true
                fetchedTip = try? await remoteParents.fetch(repo: t.repo, ref)
                scheduleTreeStat(cardId)
            } else {
                fetchedTip = known
            }
        }

        // (a) authoritative gh MERGED.
        if let pr = link.prNumber, gh.available, let st = gh.prState(repo: t.repo, number: pr), st.merged {
            await applyRemoteRedirect(cardId: cardId, link: link, grandparent: st.baseRefName,
                                      childHeadForPrRepair: t.branch)
            return .redirected(grandparent: st.baseRefName)
        }

        // (c) merge-commit ancestry (proof-positive only). child tip ⊆ fetched parent tip.
        if let parentTip = fetchedTip,
           let childTip = try? Proc.run(["git", "-C", t.repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(t.branch)"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines),
           !childTip.isEmpty,
           (try? Proc.run(["git", "-C", t.repo, "merge-base", "--is-ancestor", childTip, parentTip]))?.ok == true {
            if link.prNumber != nil, gh.available, let st = gh.prState(repo: t.repo, number: link.prNumber!) {
                await applyRemoteRedirect(cardId: cardId, link: link, grandparent: st.baseRefName,
                                          childHeadForPrRepair: t.branch)
                return .redirected(grandparent: st.baseRefName)
            }
            emitActivity(.warning, t, .daemon,
                "parent \(link.parent) appears merged (ancestry) — confirm and `set-parent` a new base")
            return .warnedAncestry
        }

        // (b) branch gone, unconfirmable.
        if tip == .gone {
            emitActivity(.warning, t, .daemon,
                "parent \(link.parent) branch is gone — likely merged; confirm and `set-parent` a new base")
            return .warnedGone
        }

        return moved ? .fetched : .none
    }

    /// Apply the remote redirect: retarget THIS card onto the (remote) grandparent branch, keep the
    /// recorded base as the rebase anchor, refresh the new parent's private ref, mark restackNeeded, nudge
    /// + wake, and best-effort repair a published child PR's base. Idempotent (safe to re-enter).
    private func applyRemoteRedirect(cardId: UUID, link: ParentLink, grandparent: String,
                                     childHeadForPrRepair childHead: String) async {
        guard let t = await store.get(cardId) else { return }
        let newRef = RemoteParentRef.branch(grandparent)                 // origin/<baseRefName>
        _ = try? await remoteParents.fetch(repo: t.repo, newRef)         // make refs/orch/parents/<gp> resolvable
        let anchor = link.base
        try? await lineage.set(repo: t.repo, branch: t.branch,
                               link: ParentLink(parent: newRef.canonical, base: anchor, prNumber: nil, watch: true))
        if let saved = try? await store.update(cardId, {
            $0.parentBranch = newRef.canonical
            $0.treeStat = TreeStat(state: .restackNeeded, parentIsRemote: true)
        }) { emit(.taskUpserted(saved)) }

        try? await inbox.enqueue(cardId,
            "remote parent merged into \(grandparent) — commit WIP, then "
            + "`git rebase --onto \(newRef.canonical) \(anchor)`, then `git push --force-with-lease`, "
            + "then `orchestra synced \(t.shortId)`")
        await wake(cardId)

        // Repair the child's own published PR base (GitHub auto-retarget is unreliable). Best-effort.
        if let pr = link.prNumber, gh.available, let childPr = gh.prNumber(repo: t.repo, head: childHead) {
            _ = pr
            _ = gh.editBase(repo: t.repo, number: childPr, base: grandparent)
        }
        emitActivity(.command, t, .daemon, "remote parent PR merged — redirected onto \(grandparent)")
    }
}
```

> Add `func inboxCount(_ id: UUID) async -> Int { await inbox.count(for: id) }` if the `Inbox` actor exposes a count; otherwise adjust the test to the available inbox read. Check `Inbox.swift`/`InboxTests` for the accessor before adding one.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LadderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Remote.swift Tests/OrchestraCoreTests/LadderTests.swift
git commit -m "feat(bt6): remote detection ladder + redirect onto PR baseRefName"
```

---

## Task 8: Watch loop lifecycle — start/stop/backoff/startup-rebuild

The thin driver around `remoteMergeStep`: a per-card `Task` while-loop with 60s-active / 300s-idle backoff (injectable short intervals in tests), held in the `remoteWatch` cancellation dict. Started on remote-base spawn, stopped on archive/clear, rebuilt at daemon startup from live cards' lineage.

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Remote.swift`, `Sources/OrchestraCore/OrchestraService.swift` (call `startRemoteWatch` in `spawn`; `stopRemoteWatch` in `archive`), `Sources/orchestrad/main.swift`
- Test: `Tests/OrchestraCoreTests/RemoteWatchLoopTests.swift`

**Interfaces:**
- Produces: `func startRemoteWatch(cardId:)`, `func stopRemoteWatch(_ id:)`, `func rebuildRemoteWatches() async`, `func remoteWatchActive(_ id:) -> Bool` (test read).

- [ ] **Step 1: Write the failing test** — inject tiny intervals; assert the loop ticks, backs off, redirects, and self-stops; and that a `.unavailable` tip never busy-loops.

```swift
// Tests/OrchestraCoreTests/RemoteWatchLoopTests.swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("Remote watch loop — lifecycle, backoff, startup rebuild")
struct RemoteWatchLoopTests {

    @Test("startup rebuild starts a watch for a live remote-parent card with watch=true")
    func rebuildFromLineage() async throws {
        let (repo, _) = try RemoteParentTests.makeOriginWithPR()
        let env = TestEnv.make(allow: [repo])
        let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        await env.svc.stopRemoteWatch(card.id)              // simulate a fresh daemon (no watches yet)
        #expect(await env.svc.remoteWatchActive(card.id) == false)
        await env.svc.rebuildRemoteWatches()
        #expect(await env.svc.remoteWatchActive(card.id) == true)
        await env.svc.stopRemoteWatch(card.id)
    }

    @Test("archive stops the watch")
    func archiveStops() async throws {
        let (repo, _) = try RemoteParentTests.makeOriginWithPR()
        let env = TestEnv.make(allow: [repo])
        let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        await env.svc.startRemoteWatch(cardId: card.id)
        #expect(await env.svc.remoteWatchActive(card.id) == true)
        try await env.svc.archive(card.id)
        #expect(await env.svc.remoteWatchActive(card.id) == false)
    }

    @Test("the loop redirects on a MERGED PR and then self-stops (no busy-loop)")
    func loopRedirectsAndStops() async throws {
        let (repo, _) = try RemoteParentTests.makeOriginWithPR()
        let env = TestEnv.make(allow: [repo])
        let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "childP", base: "pr#7"))
        await env.svc.setRemoteWatchIntervals(active: .milliseconds(20), idle: .milliseconds(20))
        await env.svc.setGh(FakeGh(available: true,
            state: PrState(state: "MERGED", mergedAt: "t", mergeCommit: nil, baseRefName: "main")))
        await env.svc.startRemoteWatch(cardId: card.id)
        // Give the loop a few ticks to observe MERGED and redirect.
        try await _Concurrency.Task.sleep(for: .milliseconds(200))
        let link = try #require(await env.svc.lineage.read(repo: repo, branch: "childP"))
        #expect(link.parent == "origin/main")
        await env.svc.stopRemoteWatch(card.id)
    }
}
```

> Note: add `func setRemoteWatchIntervals(active:idle:)`. Since a redirect clears `prNumber`, the loop keeps running against `origin/main` (harmless — main never "merges"). The test asserts the redirect happened; it does not require self-stop of the whole loop. If the design prefers stopping the watch entirely after redirect, add that and assert `remoteWatchActive == false`; either is acceptable, but keep it consistent with the ladder's idempotence.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RemoteWatchLoopTests`
Expected: FAIL — watch lifecycle methods not defined.

- [ ] **Step 3: Write minimal implementation** — append to `OrchestraService+Remote.swift`

```swift
    func setRemoteWatchIntervals(active: Duration, idle: Duration) {
        remoteWatchIntervals = (active, idle)
    }
    func remoteWatchActive(_ id: UUID) -> Bool { remoteWatch[id] != nil }

    /// Start (or restart) the per-card watch loop. Ticks `remoteMergeStep`; backs off 60s after a tick
    /// that saw movement (active), 300s otherwise (idle). Cancellation-safe: a re-start cancels the prior
    /// Task first. The loop exits when the card is gone/archived or the parent is no longer remote.
    func startRemoteWatch(cardId: UUID) {
        remoteWatch[cardId]?.cancel()
        remoteWatch[cardId] = _Concurrency.Task { [weak self] in
            guard let self else { return }
            while !_Concurrency.Task.isCancelled {
                let outcome = await self.remoteMergeStep(cardId: cardId)
                // Stop conditions: the card left the remote tier or vanished.
                if await self.shouldStopRemoteWatch(cardId) { break }
                let (active, idle) = await self.remoteWatchIntervals
                let delay = (outcome == .fetched || outcome == .none) ? idle : active
                // A conclusive outcome (redirect/warn) still loops (idempotent), but slowly.
                try? await _Concurrency.Task.sleep(for: (outcome == .redirected(grandparent: "") ? active : delay))
                if outcome == .warnedGone || outcome == .warnedAncestry {
                    try? await _Concurrency.Task.sleep(for: idle)   // extra backoff on an unconfirmable state
                }
            }
            await self.clearRemoteWatch(cardId)
        }
    }

    private func shouldStopRemoteWatch(_ id: UUID) async -> Bool {
        guard let t = await store.get(id), !t.archived, t.origin == .worktree,
              let link = await lineage.read(repo: t.repo, branch: t.branch),
              RemoteParentRef.parse(link.parent) != nil, link.watch else { return true }
        return false
    }

    func stopRemoteWatch(_ id: UUID) { remoteWatch[id]?.cancel(); remoteWatch[id] = nil }
    private func clearRemoteWatch(_ id: UUID) { remoteWatch[id] = nil }

    /// Daemon-startup reconstruction: for every live worktree card whose lineage records a watched remote
    /// parent, (re)start its watch. No global repo scan — only live cards' config.
    public func rebuildRemoteWatches() async {
        let active = await store.all().filter { !$0.archived && $0.origin == .worktree }
        for t in active {
            guard let link = await lineage.read(repo: t.repo, branch: t.branch),
                  link.watch, RemoteParentRef.parse(link.parent) != nil else { continue }
            startRemoteWatch(cardId: t.id)
        }
    }
```

> The `sleep(for: outcome == .redirected(grandparent: "") ? …)` line above is a placeholder-smell — simplify the backoff to: `let delay = (outcome == .fetched) ? active : idle` (movement ⇒ poll faster; steady ⇒ idle), then a single `try? await Task.sleep(for: delay)`. Keep it clean; the test only needs correct redirect + a bounded, non-busy cadence. Rewrite the loop body accordingly during implementation.

Wire the calls:
- In `spawn`, after `let created = try await store.create(task)` (and after the trust/session block, near the end), add: `if RemoteParentRef.parse(derivedParentBranch ?? "") != nil { startRemoteWatch(cardId: id) }`.
- In `archive`, before `store.update(... archived)`: `stopRemoteWatch(id)`.
- In `setParent` clear + `shipped` clear paths: `stopRemoteWatch(t.id)` / `stopRemoteWatch(child.id)`.
- In `main.swift` startup Task, after `recoverSessions()`: `await service.rebuildRemoteWatches()`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RemoteWatchLoopTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Remote.swift Sources/OrchestraCore/OrchestraService.swift Sources/orchestrad/main.swift
git commit -m "feat(bt6): remote watch loop lifecycle — start/stop/backoff/startup-rebuild"
```

---

## Task 9: `set-parent` remote parent + `watch` opt-in

Extend `set-parent` to accept a remote parent form (fetch + record prNumber) and a `watch` flag that starts/stops the watch. Local `adopt`/`move` behavior is unchanged.

**Files:**
- Modify: `Sources/OrchestraCore/OrchestraService+Tree.swift` (`setParent` signature + remote arm), `Sources/OrchestraKit/CommandCatalog.swift`, `Sources/OrchestraCore/CommandRegistry.swift`, `Sources/orchestra/CLIRunner.swift`
- Test: `Tests/OrchestraCoreTests/LadderTests.swift` or a new `SetParentRemoteTests.swift`

**Interfaces:**
- `setParent(ref:parent:mode:watch:source:)` — `watch: Bool = false`; a remote `parent` fetches, records `prNumber`+`watch`, starts the loop.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OrchestraCoreTests/SetParentRemoteTests.swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("set-parent — remote parent + watch opt-in")
struct SetParentRemoteTests {
    @Test("set-parent to pr#7 with watch:true fetches, records prNumber, starts the watch")
    func remoteSetParent() async throws {
        let (repo, _) = try RemoteParentTests.makeOriginWithPR()
        let env = TestEnv.make(allow: [repo])
        // A plain card on its own branch, no parent yet.
        let card = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: "solo"))
        _ = try await env.svc.setParent(ref: card.shortId, parent: "pr#7", mode: "adopt", watch: true)
        let link = try #require(await env.svc.lineage.read(repo: repo, branch: "solo"))
        #expect(link.parent == "pr#7")
        #expect(link.prNumber == 7)
        #expect(link.watch == true)
        #expect(await env.svc.remoteWatchActive(card.id) == true)
        await env.svc.stopRemoteWatch(card.id)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SetParentRemoteTests`
Expected: FAIL — `setParent` has no `watch:` param / no remote arm.

- [ ] **Step 3: Write minimal implementation** — in `setParent`, add `watch: Bool = false` and, at the top of the `if let p = trimmed, !p.isEmpty {` block, branch on remote:

```swift
            if let remote = RemoteParentRef.parse(p) {
                // Remote parent: fetch into the private ref, record canonical form + prNumber, opt into
                // watch per the flag (default off). base = the fetched tip (redirect/restack anchor).
                let oid = try await remoteParents.fetch(repo: t.repo, remote)
                let pr: Int? = { if case .pullRequest(let n) = remote { return n }; return nil }()
                try await lineage.set(repo: t.repo, branch: t.branch,
                    link: ParentLink(parent: remote.canonical, base: oid, prNumber: pr, watch: watch))
                let updated = try await store.update(t.id) {
                    $0.parentBranch = remote.canonical
                    $0.treeStat = TreeStat(state: .inSync, parentIsRemote: true)
                }
                emit(.taskUpserted(updated))
                if watch { startRemoteWatch(cardId: t.id) } else { stopRemoteWatch(t.id) }
                emitActivity(.command, updated, source, "set remote parent → \(remote.canonical)")
                return updated
            }
```

Update the `else` (clear) arm to also `stopRemoteWatch(t.id)`.

Catalog (`CommandCatalog.swift` `set-parent`): add `"watch": boolProp("Remote parents only: poll the PR/branch and auto-redirect this card when it merges.")` and update the `parent` prop text: `"Parent branch ref: a local name, or a remote form 'origin/<branch>' / 'pr#<N>'. Omit to clear."`

Registry (`CommandRegistry.swift` `set-parent`): add `watch: p.optBool("watch") ?? false` to the `setParent(...)` call.

CLI (`CLIRunner.swift` `set-parent` case): after the mode line, add:
```swift
                if flags.has("watch") { params["watch"] = .bool(true) }
```
(Adapt to the flag-parsing API — check how other bool flags like `--force`/`--scratch` are read in `CLIRunner`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SetParentRemoteTests`
Then: `swift test --filter SetParentMoveTests` and `swift test --filter CommandRegistryCatalogTests` (pairing) — must stay green.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/OrchestraService+Tree.swift Sources/OrchestraKit/CommandCatalog.swift Sources/OrchestraCore/CommandRegistry.swift Sources/orchestra/CLIRunner.swift Tests/OrchestraCoreTests/SetParentRemoteTests.swift
git commit -m "feat(bt6): set-parent accepts remote parents + watch opt-in"
```

---

## Task 10: TreeDocs remote section + catalog base help

Update the ship/restack guidance for both agents (Claude skill + Codex AGENTS.md section) to cover the remote publish path and restack-after-remote-merge, and update the `spawn.base` catalog help to document the two canonical remote forms.

**Files:**
- Modify: `Sources/OrchestraCore/Resources/tree-skill.md`, `Sources/OrchestraCore/Resources/tree-agents.md`, `Sources/OrchestraKit/CommandCatalog.swift`
- Test: `Tests/OrchestraCoreTests/TreeDocsTests.swift` (assert the remote guidance string is present in both variants)

**Interfaces:** documentation only; the install-mechanics tests already cover materialization.

- [ ] **Step 1: Write the failing test** (append to `TreeDocsTests`)

```swift
    @Test("both variants document the remote publish + restack path")
    func remoteGuidancePresent() throws {
        for v in [TreeDocs.Variant.claudeSkill, .codexAgents] {
            let text = try #require(TreeDocs.load(v))
            #expect(text.contains("gh pr create --base"))
            #expect(text.contains("force-with-lease"))
            #expect(text.contains("rebase --onto"))
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TreeDocsTests/remoteGuidancePresent`
Expected: FAIL — the remote line currently says "out of scope for now (BT6)".

- [ ] **Step 3: Write minimal implementation** — replace the remote bullet in **`tree-skill.md`** (the `## Ship` section) and mirror it in **`tree-agents.md`**:

```markdown
- **Remote parent (`origin/<branch>` or `pr#<N>`)** → do NOT merge locally. **Publish** your branch as a stacked PR:
  1. `git push -u origin <your-branch>`
  2. `gh pr create --base <parentHeadRef>` — target the PARENT's head branch (the branch behind the parent PR / `origin/<branch>`), not `main`, so your PR shows only your commits.
  Do NOT call `orchestra shipped`. Orchestra watches the parent PR; when it merges, it redirects your card onto the parent's base and nudges you to restack.

  **After the parent PR merges** (you'll get a nudge): restack onto the new base and republish.
  1. Commit WIP (never autostash). 2. `git rebase --onto <new-base> <recorded-base>` — `<recorded-base>` is the anchor in the nudge / `orchestra tree`, so only YOUR commits move (squash-proof — no phantom conflicts). 3. `git push --force-with-lease` (NEVER a bare `--force`). 4. `orchestra synced <you>`. Orchestra best-effort repairs your PR's base; if it didn't, `gh pr edit <your-pr> --base <new-base>`.
```

Update `CommandCatalog.swift` `spawn.base` help to add: `" A remote parent is 'origin/<branch>' (a same-repo remote branch) or 'pr#<N>' (a pull request) — Orchestra fetches it and watches it for merges."`

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TreeDocsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Resources/tree-skill.md Sources/OrchestraCore/Resources/tree-agents.md Sources/OrchestraKit/CommandCatalog.swift Tests/OrchestraCoreTests/TreeDocsTests.swift
git commit -m "docs(bt6): TreeDocs remote publish/restack guidance (Claude + Codex) + base help"
```

---

## Task 11: Spawn sheet remote base entry (desktop + iOS)

Add a remote entry to the base picker both sheets already have (BT2 left the extension point). Backend-agnostic: the sheet just sends `origin/<branch>` or `pr#<N>` as the `base` string. Build-verified + manual visual pass (no CI pixel tests, per test design).

**Files:**
- Modify: `App/Views/SpawnSheet.swift`, `App-iOS/Views/SpawnSheet.swift`

- [ ] **Step 1: Inspect the existing base picker** — read `App/Views/SpawnSheet.swift:190-210` (`basePicker`, `effectiveBase`) and the iOS equivalent, to match the established control style.

- [ ] **Step 2: Add a "PR # / remote branch" free-text affordance** — under the existing base branch picker, add a text field that, when non-empty, sets `base` to the typed remote form (`pr#<N>` or `origin/<branch>`). Keep `effectiveBase` semantics (nil for an existing branch). Mirror in iOS.

Example (desktop, adapt to the real view):
```swift
field("Remote base (optional — 'pr#12' or 'origin/branch')") {
    TextField("pr#12", text: $base).textFieldStyle(.roundedBorder)
}
```
(Only ONE base source active at a time — a typed remote value overrides the local picker; keep the existing `effectiveBase` gate.)

- [ ] **Step 3: Build both apps**

Run: `swift build` (core) then the app build per `scripts/build-app.sh` (desktop). iOS via the project's typecheck script.
Expected: clean build.

- [ ] **Step 4: Manual visual pass** — `scripts/orch-ui-shot.sh` (desktop) to confirm the field renders; note in the commit that visual verification was manual (no CI).

- [ ] **Step 5: Commit**

```bash
git add App/Views/SpawnSheet.swift App-iOS/Views/SpawnSheet.swift
git commit -m "feat(bt6): remote base entry in spawn sheets (desktop + iOS)"
```

---

## Task 12: Full suite + integration sweep

- [ ] **Step 1:** `swift build` — clean.
- [ ] **Step 2:** `swift test 2>&1 | tail -40` — all green EXCEPT the "SessionManager — real tmux" / E2E-binary suites IF they fail with "fork failed: Device not configured" (PTY exhaustion — environmental, ignore only that). Any other failure must be fixed.
- [ ] **Step 3:** Re-run the BT-regression filters together: `swift test --filter "SpawnBaseTests|LineageSpawnTests|SetParentMoveTests|ShipChoreoTests|DiffProviderTests|TreeStatTests|CommandRegistryCatalogTests|TreeDocsTests"` — green.
- [ ] **Step 4: Commit any fixups**, then move to review (see Workflow below).

---

## Self-Review (run before review handoff)

**Spec coverage (owner scope 1–5):**
1. `RemoteParents.fetch`/`lsRemoteTip` + hardened env → Tasks 2. ✅
2. Watch loop + backoff + ladder + lifecycle → Tasks 7, 8. ✅
3. `GhProbe` behind `GhClient` + FakeGh → Tasks 3, 7. ✅
4. Remote bases in spawn (both forms) + `resolvedParentRef` extension + sheets → Tasks 4, 5, 6, 11. ✅
5. TreeDocs remote section → Task 10. ✅

**Test-design coverage (04-tests.md):** fetch-lands-in-pr-N + force-refspec + `GIT_TERMINAL_PROMPT` env (T2); lsRemoteTip OID + gone (T2); ladder MERGED/gone-warning/squash-merged-by-gh (T7); watch tick/backoff/no-busy-loop (T8); remote spawn start-point + lineage keys incl. pr number (T5, T6). Ancestry merge-commit case → covered by the `(c)` tier; **add an explicit merge-commit fixture test in LadderTests if time permits** (fetch a parent tip that CONTAINS the child, gh unavailable ⇒ `.warnedAncestry`; gh available ⇒ `.redirected`).

**Type consistency:** `RemoteParentRef.canonical` is the ONE stored form (spawn, set-parent, redirect all use it); `privateRef` is the ONE resolved form (`resolvedParentRef`, ensure base, ladder). `RemoteTip` tri-state is used consistently (never `try? … nil`-conflated). `PrState.merged` is the single merge predicate.

**Placeholder scan:** the Task 8 loop body has a flagged placeholder-smell — simplify the backoff to a single `sleep(for: outcome == .fetched ? active : idle)` during implementation (noted inline).

---

## Workflow (owner-mandated)

1. This plan authored in **Plan** column. ✅
2. `move c2f1b0 --col impl`; implement Tasks 1–12 via superpowers:test-driven-development, committing per task.
3. `move c2f1b0 --col review`; superpowers:requesting-code-review — a review subagent over the diff vs `plan/parent-card-branch-linking`; fix; repeat until a clean round.
4. Final summary message; archive self (the merge signal). Never merge anything.
