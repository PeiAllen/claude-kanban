# PR7 — Slow-repo E2E fixture (both agents) + final docs coherence sweep

> **AS-BUILT NOTE (2026-07-10):** the fixture default shipped at **12k files**, not the **28k** written
> throughout this plan — 12k already yields a multi-second `git worktree add` (~4-10s), far above the
> ~0.8s a borrowed card needs to overtake it, while keeping generation cheap (28k was ~80s × 2 agent
> cases). Generation uses a single `awk` pass. Wherever this plan says "~28k", read the 12k as-built
> value. The deviation is recorded in `notes/designs/lifecycle-convergence/04-tests.md` (Decisions made).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one end-to-end **smoke** test (`test_slowRepoSpawn`, run for **both** claude-code and codex) that exercises the shipped lifecycle-convergence machinery over a real git checkout + real tmux, and reconcile `docs/` (the project SSOT) so it is internally consistent and matches the shipped code after PR1–PR6b.

**Architecture:** A scripted ~28k-file git fixture (generated into a temp dir at test setup, never committed) gives a multi-second checkout window. A real-git + real-tmux `OrchestraService` (mirroring `E2EBinaryTests`) with **both** agent adapters registered spawns two same-branch cards; a background `reconcile()` loop drives them. The one test asserts three shipped behaviours end-to-end: race-free `WorktreeRegistry.ensure` under two same-branch spawns (Stage 3), a non-frozen service actor during the checkout (Stages 4–5), and the `creatingWorktree → launching → live` phase walk (Stage 2). The docs sweep is a **coherence pass** — fix stale cross-references and contradictions left between PRs; do not rewrite.

**Tech Stack:** Swift (swift-testing), real `git worktree`, real `tmux`, the bundled `fake-agent.sh` adapter shim, `WorktreeRegistry`/`OrchestraService`/`SessionManager`.

## Global Constraints

- **E2E is SMOKE, not the regression guard.** Every race `test_slowRepoSpawn` exercises already has a deterministic stub test in a prior PR (`test_concurrentSameBranchEnsureJoins` — PR3b; `test_actorNotBlockedByExec`/`_byLivenessList` — PR5; `test_spawnDrivesPhases` — PR2). **Do not remove or weaken any deterministic stub test in its favor.** Never present this test as race proof — its suite/doc comments say "smoke".
- **Both agents.** `test_slowRepoSpawn` runs for `claude-code` **and** `codex` (repo rule; parameterized suite).
- **Fixture generation stays scripted + cheap.** Do **not** commit 28k files. Generate them in a temp dir at setup via a bundled shell script; tear the dir down in `deinit`.
- **`swift test --no-parallel` green** is the authoritative gate (841+ tests, 0 failures). The E2E is smoke — if it flakes under the default parallel run's real-tmux/UDS load, that is expected; re-run in isolation.
- **Docs sweep is reconciliation, not rewrite.** `docs/` must match the shipped code + the vault's as-built "Decisions made" tables. Fix stale refs/contradictions/gaps between PRs; keep prose intact where correct.
- **Fold any deviation into the vault** (`notes/designs/lifecycle-convergence/` Decisions tables) and mention it in the merge-request.
- **Provenance:** anchors below verified against `lc/7-e2e-slow-repo` @ current tip (2026-07-10). `E2EBinaryTests.swift` (real git+tmux harness), `IntegrationSupport.swift` (fixture bundle + tool gates), `WorktreeRegistryIntegrationTests.swift` (real-git registry pattern), `Package.swift:87-90` (`resources: [.copy("Fixtures")]` — a new `Fixtures/*.sh` is auto-bundled), `Stubs.swift:498` (`spawnAndAwaitLive`), `OrchestraService.swift:358` (`spawn`), `+Reconcile.swift:47` (`reconcile`), `Model.swift:83-87` (`Phase.Kind`).

## File structure

| File | Responsibility | Task |
|---|---|---|
| `Tests/IntegrationTests/Fixtures/gen-slow-repo.sh` (new) | Efficient shell generator: create N tiny files across nested dirs in a caller-given dir, `git init/add/commit`. Bundled via the existing `.copy("Fixtures")`. | E1 |
| `Tests/IntegrationTests/SlowRepoE2ETests.swift` (new) | The `test_slowRepoSpawn` smoke suite (both agents) + a fixture-sanity test. | E1, E2 |
| `docs/02,03,04,05,09-*.md` (modify) | Coherence pass: fix stale cross-refs/contradictions/gaps so docs match shipped code + vault Decisions. | D1 |
| `notes/designs/lifecycle-convergence/04-tests.md` / `05-pr-tree.md` (modify, only if deviations) | Fold any PR7 as-built deviation into the Decisions tables. | E2, D1 |

---

## Task E1 — Slow-repo fixture generator + fixture-sanity test

**Files:**
- Create: `Tests/IntegrationTests/Fixtures/gen-slow-repo.sh`
- Create: `Tests/IntegrationTests/SlowRepoE2ETests.swift` (fixture-sanity test only; the E2E lands in E2)
- Test: `Tests/IntegrationTests/SlowRepoE2ETests.swift::fixtureGeneratesSlowCheckout`

**Interfaces:**
- Consumes: `IntegrationSupport.tempDir(_:)`, `IntegrationSupport.gitAvailable`, `Bundle.module.path(forResource:ofType:)`, `Proc.checked(_:)`.
- Produces: `gen-slow-repo.sh <dir> [count]` — creates a git repo at `<dir>` with `count` (default 28000) committed tiny files across nested dirs, on branch `main`, one commit. A `SlowRepoFixture` helper in the test file resolves the script from the bundle, runs it, and returns the repo path.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import OrchestraCore

/// PR7 (cross-cutting) — SMOKE, not the regression guard. Every race exercised here has a deterministic
/// stub test in a prior PR (`test_concurrentSameBranchEnsureJoins` — PR3b; `test_actorNotBlockedByExec`/
/// `_byLivenessList` — PR5; `test_spawnDrivesPhases` — PR2). This just proves the shipped machinery holds
/// together over a REAL git checkout + REAL tmux.
enum SlowRepoFixture {
    /// Absolute path to the bundled generator script.
    static var scriptPath: String {
        Bundle.module.path(forResource: "Fixtures/gen-slow-repo", ofType: "sh")
            ?? Bundle.module.path(forResource: "gen-slow-repo", ofType: "sh") ?? ""
    }

    /// Generate a slow repo of `count` files at `<base>/repos/app`; returns the canonical repo path.
    @discardableResult
    static func generate(base: String, count: Int = 28_000) throws -> String {
        let repo = base + "/repos/app"
        try FileManager.default.createDirectory(atPath: base + "/repos", withIntermediateDirectories: true)
        let r = try Proc.run(["/bin/bash", scriptPath, repo, String(count)])
        guard r.exitCode == 0 else {
            throw OrchestraError.io("gen-slow-repo failed: \(r.stderr)")   // `.io`, not `.internalError` (no such case)
        }
        return PathResolver.canonical(repo)
    }
}

@Suite("Slow-repo fixture sanity", .enabled(if: IntegrationSupport.gitAvailable), .serialized)
struct SlowRepoFixtureTests {
    @Test("generator produces a large committed working tree")
    func fixtureGeneratesSlowCheckout() throws {
        #expect(!SlowRepoFixture.scriptPath.isEmpty)
        let base = IntegrationSupport.tempDir("slowfix")
        defer { try? FileManager.default.removeItem(atPath: base) }
        // A small count keeps this sanity test fast; the E2E uses the full ~28k default.
        let repo = try SlowRepoFixture.generate(base: base, count: 2_000)
        let n = try Proc.checked(["git", "-C", repo, "ls-files"]).stdout
            .split(whereSeparator: \.isNewline).count
        #expect(n >= 2_000)
        // HEAD is a single commit on main
        let head = try Proc.checked(["git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == "main")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter SlowRepoFixtureTests`
Expected: FAIL — `SlowRepoFixture.scriptPath` is empty (script absent) → `generate` throws / `#expect` fails.

- [ ] **Step 3: Write the generator script**

Create `Tests/IntegrationTests/Fixtures/gen-slow-repo.sh` (mark executable, `chmod +x`):

```bash
#!/bin/bash
# gen-slow-repo.sh — generate a large git repo whose `git worktree add` checkout takes multiple seconds.
# Usage: gen-slow-repo.sh <repo-dir> [file-count]   (default 28000)
# Files are tiny and spread across nested dirs so file COUNT (not size) drives checkout time. The repo is
# generated fresh at test setup and torn down after — it is never committed to THIS repository.
set -euo pipefail
repo="${1:?repo dir required}"
count="${2:-28000}"
per_dir=200                                   # files per leaf dir → count/200 dirs

mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email "t@t.t"
git -C "$repo" config user.name "T"
git -C "$repo" config core.autocrlf false

i=0
dir=""
while [ "$i" -lt "$count" ]; do
  if [ $((i % per_dir)) -eq 0 ]; then
    dir="$repo/d$((i / per_dir))"
    mkdir -p "$dir"
  fi
  printf 'f%d\n' "$i" > "$dir/f$i.txt"
  i=$((i + 1))
done

git -C "$repo" add -A
git -C "$repo" commit -q -m "seed $count files"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --no-parallel --filter SlowRepoFixtureTests`
Expected: PASS (script bundled via `.copy("Fixtures")`; 2000 files committed on `main`).

- [ ] **Step 5: Commit**

```bash
git add Tests/IntegrationTests/Fixtures/gen-slow-repo.sh Tests/IntegrationTests/SlowRepoE2ETests.swift
git commit -m "test(e2e): scripted slow-repo git fixture + sanity test"
```

---

## Task E2 — `test_slowRepoSpawn` end-to-end smoke (both agents)

**Files:**
- Modify: `Tests/IntegrationTests/SlowRepoE2ETests.swift` (add the E2E suite)
- Test: `Tests/IntegrationTests/SlowRepoE2ETests.swift::slowRepoSpawn`

**Interfaces:**
- Consumes: `SlowRepoFixture.generate(base:count:)` (E1); `OrchestraService.spawn(_:)`, `.reconcile()`, `.list(includeArchived:)`, `.sessions(_:)`; `WorktreeRegistry(config:borrowsPath:markersDir:)`; `SessionManager`; `ClaudeCodeAdapter(binOverride:)` + `CodexAdapter(binOverride:codexHome:)`; `IntegrationSupport.fakeAgentPath`; `Phase.Kind` (`.creatingWorktree`/`.launching`/`.live`).
- Produces: `test_slowRepoSpawn` (parameterized `["claude-code", "codex"]`).

**Design notes (locked):**
- **Harness = real git + real tmux**, mirroring `E2EBinaryTests.init` (real repo, `SessionManager` on a temp `-L` socket, `WorktreeRegistry` over the real `WorktreeManager`, a 200ms background `reconcile()` + `pollTelemetry()` loop). **Both** adapters are registered so a `codex` card is a genuine second backend; `AgentRegistry(adapters: [claude, codex])`. Both are backed by `fake-agent.sh` via `binOverride` — the fake agent ignores unknown flags and stays alive echoing stdin, so the tmux `:agent` window comes up for either adapter and the **N=3 liveness fallback** drives `launching → live` (the fake agent fires no readiness hook — same as `E2EBinaryTests`).
- **Non-frozen-actor assertion (phase-ordering, replaces the timing approach — codex findings 1 & 3):** a wall-clock `list()`-latency sample is inherently vacuous (can race ahead of the checkout) or flaky (a tight frozen-actor inequality trips under CI load). Instead, prove non-freezing by **phase ordering**: concurrently spawn a fast **borrowed** card `c` (cwd = a pre-created dir under `base`; instant materialize, no git checkout — borrowed not scratch, so nothing leaks into the real `~/.orchestra/scratch` to flake full-suite runs) and assert it reaches `.live` **while both A and B are still `.creatingWorktree`**. If the service actor were frozen by an on-actor `git worktree add`, the reconcile loop could not advance `c`; on the shipped code it does, because `stepIfEligible` dispatches each card's stepper as a **detached** `_Concurrency.Task` (per-card `inFlightSteps`) and git runs off-actor in the registry (`runStep` docstring: "the tick that dispatched it isn't frozen"). Margin is wide and non-flaky: `c` reaches live in ~0.8s (N=3 fallback) vs the ~9s checkout; the ~28k fixture is sized so the checkout reliably outlasts `c`'s launch. This is honest smoke; PR5's actor-hygiene stubs (`test_actorNotBlockedByExec`/`_byLivenessList`) remain the deterministic guard.
- **Race-free ensure:** both cards use the **same** repo+branch. After both reach `.live`, assert their `cwd` are the **same** worktree path and exactly **one** worktree dir exists for that branch (`git worktree list` shows one entry for it) — the registry joined the two `ensure` calls (no `branchInUse` throw, no second card `dead(.spawnFailed)`). Verified: worktree spawn does **no** synchronous `ensure` (`OrchestraService.swift:424-426` just derives `cwd = worktrees.path(...)`), co-located same-branch `.worktree` siblings are permitted (warn-only), and the ensures join in the reconcile loop.
- **Phase walk:** poll until both cards are `.live` (~20s cap = 100 × 200ms, headroom over the ~9s checkout + launch + N=3 fallback; the background `reconcile()` loop does the driving). Assert each card was observed passing through the being-born phases during polling, reached `.live`, and — for **both** cards — its session `:agent` window exists via `try await svc.sessions(cardId)` (`.targets.contains { $0.window == "agent" }`).
- **TDD honesty:** the product ships already; the "red" is structural — before the fixture/harness exist the target won't build / the poll times out. The test is smoke over shipped behaviour.

- [ ] **Step 1: Write the failing test**

```swift
@Suite("Slow-repo lifecycle E2E — SMOKE (both agents)",
       .enabled(if: IntegrationSupport.gitAvailable && IntegrationSupport.tmuxAvailable), .serialized)
final class SlowRepoE2ETests {
    // one harness per test instance (swift-testing makes a fresh instance per case/arg)
    let base: String
    let tmuxSock: String
    let ctlSock: String
    var service: OrchestraService!
    var pollLoop: _Concurrency.Task<Void, Never>!

    init() {
        base = IntegrationSupport.tempDir("slowe2e")
        tmuxSock = "orch-slow-\(UUID().uuidString.prefix(8))"
        ctlSock = "/tmp/orch-slow-\(UUID().uuidString.prefix(8)).sock"
    }

    deinit {
        pollLoop?.cancel()
        _ = try? Proc.run(["tmux", "-L", tmuxSock, "kill-server"])
        try? FileManager.default.removeItem(atPath: base)
    }

    private func makeService(repo: String) -> OrchestraService {
        let config = Config(reposRoot: PathResolver.canonical(base) + "/repos",
                            worktreesRoot: PathResolver.canonical(base) + "/worktrees",
                            allowlist: [PathResolver.canonical(base)])
        let sessions = SessionManager(socket: tmuxSock, confPath: SessionManager.bundledConf, sockEnvPath: ctlSock)
        let claude = ClaudeCodeAdapter(binOverride: IntegrationSupport.fakeAgentPath)
        let codex = CodexAdapter(binOverride: IntegrationSupport.fakeAgentPath, codexHome: base + "/codexhome")
        let svc = OrchestraService(config: config, store: TaskStore(path: base + "/tasks.json"),
                                   registry: AgentRegistry(adapters: [claude, codex]),
                                   worktrees: WorktreeRegistry(config: config, borrowsPath: base + "/borrows.json",
                                                               markersDir: base + "/worktree-markers"),
                                   sessions: sessions)
        let s = svc
        pollLoop = _Concurrency.Task {
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .milliseconds(200))
                await s.reconcile()
                await s.pollTelemetry()
            }
        }
        return svc
    }

    @Test("slow-repo spawn: race-free ensure + non-frozen actor + phase walk",
          arguments: ["claude-code", "codex"])
    func slowRepoSpawn(agentId: String) async throws {
        let repo = try SlowRepoFixture.generate(base: base)      // ~28k files → multi-second checkout
        service = makeService(repo: repo)
        let branch = "slow-\(agentId)"

        // Two SAME-branch spawns, concurrently — both return immediately at `.creatingWorktree`.
        let a = try await service.spawn(SpawnInput(id: UUID(), prompt: "x", repo: repo, branch: branch, agentId: agentId))
        let b = try await service.spawn(SpawnInput(id: UUID(), prompt: "y", repo: repo, branch: branch, agentId: agentId))
        #expect(a.phase.kind == .creatingWorktree)
        #expect(b.phase.kind == .creatingWorktree)

        // Non-frozen proof by PHASE ORDERING (not wall-clock — codex findings 1 & 3 killed the timing
        // approach as vacuous/flaky). Concurrently spawn a fast card `c` that skips the git checkout —
        // a BORROWED card whose cwd is a pre-created dir UNDER `base` (materialize = instant, no
        // `worktrees.ensure`; then the N=3 liveness fallback ≈ 600ms → `.live`). Borrowed (not scratch)
        // deliberately: a scratch card materializes under the REAL `~/.orchestra/scratch/<id>` and would
        // leak state / flake full-suite runs (codex cleanup note); a borrowed dir under `base` is torn
        // down with `base` in `deinit`. If the service actor were frozen by an on-actor `git worktree
        // add`, the reconcile loop could not dispatch/advance ANY other card, so `c` could NOT reach
        // `.live` while A and B are still `.creatingWorktree`. On the shipped code it CAN: `stepIfEligible`
        // dispatches each card's stepper as a DETACHED `_Concurrency.Task` (per-card `inFlightSteps`) and
        // git runs off-actor in the registry, so `c` (~0.8s to live) overtakes the ~9s checkout with a
        // wide, non-flaky margin. The ~28k-file fixture is sized so the checkout reliably outlasts `c`.
        let cDir = base + "/borrowed-c"
        try FileManager.default.createDirectory(atPath: cDir, withIntermediateDirectories: true)
        let c = try await service.spawn(SpawnInput(id: UUID(), prompt: "z", agentId: agentId, cwd: cDir))

        var sawBeingBorn = false
        var overtook = false                                     // c reached .live while BOTH A and B still creating
        for _ in 0..<100 {                                       // 100 × 200ms = 20s cap
            let cards = await service.list(includeArchived: true)
            func phase(_ id: UUID) -> Phase.Kind? { cards.first { $0.id == id }?.phase.kind }
            if [a.id, b.id].contains(where: { phase($0) == .creatingWorktree || phase($0) == .launching }) {
                sawBeingBorn = true                              // Stage 2 being-born phases observed
            }
            if phase(c.id) == .live && phase(a.id) == .creatingWorktree && phase(b.id) == .creatingWorktree {
                overtook = true                                 // fast card advanced during the slow checkout
            }
            if [a.id, b.id].filter({ phase($0) == .live }).count == 2 { break }
            try await _Concurrency.Task.sleep(for: .milliseconds(200))
        }
        #expect(sawBeingBorn)                                     // Stage 2 phase walk observed
        #expect(overtook)                                        // Stages 4-5: service actor stayed responsive during the checkout

        let final = await service.list(includeArchived: true).filter { $0.id == a.id || $0.id == b.id }
        #expect(final.count == 2)
        #expect(final.allSatisfy { $0.phase.kind == .live })     // both reached live

        // Race-free ensure (Stage 3): both cards joined ONE worktree for the shared branch.
        #expect(Set(final.map(\.cwd)).count == 1)
        let wtList = try Proc.checked(["git", "-C", repo, "worktree", "list"]).stdout
        #expect(wtList.split(whereSeparator: \.isNewline).filter { $0.contains(branch) }.count == 1)

        // The tmux `:agent` window is up for BOTH live cards (codex finding 2 — assert each, not just
        // one). `sessions(_:)` is `throws`-returning a NON-optional `CardSessions` (Model.swift:876);
        // its `targets: [TmuxTarget]` carry the windows (`TmuxTarget.window == "agent"`, Model.swift:796)
        // — there is no `.windows` field.
        for card in final {
            let cs = try await service.sessions(card.id)
            #expect(cs.targets.contains { $0.window == "agent" })
        }
    }
}
```

> Session-accessor shapes verified against the code (Opus review finding 2): `func sessions(_ id: UUID) async throws -> CardSessions` (`OrchestraService.swift:889`), `CardSessions.targets: [TmuxTarget]` (`Model.swift:876-884`), `TmuxTarget.window`/`.target` (`Model.swift:796`). It only throws for an unknown card/agent — safe for a live card.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter SlowRepoE2ETests`
Expected: FAIL to build (references `SlowRepoFixture` from E1 if reordered) or the poll times out / accessor mismatch — a structural red for a not-yet-wired harness.

- [ ] **Step 3: Fix the mechanical accessors + wire it green**

Reconcile the session-accessor names against the real API (search `func sessions(` and the `E2EBinaryTests` `:agent` assertion). Confirm both adapters register (`AgentRegistry(adapters:)` accepts the array) and a `codex`-`agentId` spawn routes to the Codex adapter. No product changes — only test-side accessor fixes.

- [ ] **Step 4: Run test to verify it passes (both agents)**

Run: `swift test --no-parallel --filter SlowRepoE2ETests`
Expected: PASS for `slowRepoSpawn (claude-code)` and `slowRepoSpawn (codex)`. If it flakes under a full parallel run, re-run in isolation (smoke doctrine).

- [ ] **Step 5: Full suite green**

Run: `swift test --no-parallel`
Expected: 841+ tests, 0 failures (the new tests add to the count; no stub test removed or weakened).

- [ ] **Step 6: Commit**

```bash
git add Tests/IntegrationTests/SlowRepoE2ETests.swift
git commit -m "test(e2e): slow-repo lifecycle smoke — race-free ensure + non-frozen actor + phase walk (claude+codex)"
```

---

## Task D1 — Final docs coherence sweep

**Files:** Modify `docs/02-architecture.md`, `docs/03-data-model.md`, `docs/04-cards-worktrees-sessions.md`, `docs/05-command-reference.md`, `docs/09-design-decisions.md` (only where stale). This is **reconciliation, not rewrite** — prior PRs updated their own slices; PR7 fixes cross-references, contradictions, and gaps **between** PRs.

**Coherence checklist (verify each; fix only what's stale):**

| Area | Docs | Must match (shipped code / vault) |
|---|---|---|
| Phase model + funnel + epochs | `03-data-model.md`, `04-cards-worktrees-sessions.md#recovery-resume-and-restart` | `Phase`/`RunState` cases, `sessionEpoch`/`phaseChangedAt`/`pendingSeed`, `transition()` as sole writer, `isLegalEdge`, the one-time `status`/`waitReason` migration |
| Reconciler / steppers / convergence | `02-architecture.md#request-flow-server-side`, `#the-daemon-orchestrad` | `PhaseStepper` (Materialize/Launch/Relaunch/Teardown), reconciler driving discipline, boot order, epoch-identity adoption, conservative mode |
| Verb taxonomy | `05-command-reference.md` | `CommandSchema.kind`/`phaseGate`, Query/Mutation/Convergence classes, dispatch-time gate (bug #3) |
| WorktreeRegistry | `04-cards-worktrees-sessions.md#worktrees` | single-owner actor, marker arms, on-demand sibling counts, one `release()` policy, persisted borrows, path safety |
| Sync / idempotency / deadlines / displayState | `02-architecture.md#the-control-plane`, `#the-client-transport-seam-and-reconnect`, `#the-three-clients` | board `rev`, apply-iff-rev + gap resync, client-minted ids, per-RPC deadline + ping keepalive, `displayState` render contract |
| Design decisions | `09-design-decisions.md` | phase/epoch decision, wire-break decision, registry decision — matching each layer's "Decisions made" as-built table |

- [ ] **Step 1: Stale-term scan.** Run the scan and triage each hit as *legitimate-historical* (describing the retired model as rejected/migrated — keep) vs *stale current-state* (claims a removed field/behaviour is live — fix):

```bash
grep -rn "waitReason\|AgentStatus\|\.recovering\|recovering set\|scheduleRecovering" docs/*.md
```

Known stale hit to fix: `docs/02-architecture.md` — the report-merge field list includes `waitReason` (removed in Stage 2; it should read `phase`/`RunState`, matching `03-data-model.md`'s "replaces the retired `status`/`waitReason` pair"). Fix that line; re-verify every other hit is a correct historical/migration reference.

- [ ] **Step 2: Cross-reference each checklist row** against the shipped symbols. For each row, grep the doc for the concept and confirm the described mechanism/field/verb-class matches the code (e.g. `Phase.Kind` cases in `Model.swift:83-87`, `phaseGate` in `CommandCatalog.swift`, `WorktreeRegistry` API, `displayState` in `DisplayState.swift`). Fix contradictions between two docs (e.g. one doc calls a phase `provisioning`, another `creatingWorktree`) and fill any gap a prior PR left dangling.

- [ ] **Step 3: Adversarial coherence review (subagent).** Dispatch a `general-purpose` Opus subagent (xhigh) to read `docs/02-05,09` against `notes/designs/lifecycle-convergence/` + the shipped `Sources/` and report ONLY concrete inconsistencies (stale field, contradicted term, missing cross-ref) with file:line — not style. Apply the confirmed findings.

- [ ] **Step 4: Verify no regressions in prose links.** Re-run the scan from Step 1; confirm no *stale current-state* hits remain. Spot-check that no fixed line contradicts a sibling doc.

- [ ] **Step 5: Commit**

```bash
git add docs/
git commit -m "docs: final lifecycle-convergence coherence sweep (reconcile cross-refs to shipped code)"
```

---

## Self-review checklist (run before merge-request)

1. **Scope coverage:** `test_slowRepoSpawn` exercises Stage 3 (race-free same-branch ensure), Stages 4–5 (non-frozen actor during checkout), Stage 2 (phase walk) — ✔; runs for claude-code **and** codex — ✔; docs 02/03/04/05/09 reconciled — ✔.
2. **Smoke doctrine:** suite/doc comments label it smoke; each race cites its deterministic stub guard; **no stub test removed or weakened** — ✔.
3. **Fixture cheapness:** 28k files generated at setup into a temp dir, torn down in `deinit`; **nothing committed** to this repo; script bundled via existing `.copy("Fixtures")` — ✔.
4. **Both-agent honesty:** both adapters registered; a `codex`-`agentId` card routes to the Codex adapter (not Claude-with-different-caps) — ✔.
5. **Gate:** `swift test --no-parallel` green; deviations folded into the vault + noted in the merge-request — ✔.

## Execution handoff

Plan saved to `notes/plans/2026-07-10-pr7-slow-repo-e2e-and-docs-sweep.md`. Per Allen's workflow: **Phase B** reviews this plan (Opus general-purpose xhigh + a read-only GPT-5.5 codex card in this worktree) until clean, then **Phase C** implements via `superpowers:subagent-driven-development` (high effort, strict TDD), **Phase D** reviews the diff (same dual pattern), **Phase E** verifies `swift test --no-parallel` green with pasted output, **Phase F** files the `merge-request`.
