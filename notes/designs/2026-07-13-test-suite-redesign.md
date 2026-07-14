# Test-suite redesign: isolate everything, mock most, fake time always

**Status:** design for review · **Card:** 581da4 · **Branch:** `perf/tiered-test-suite`
**Baseline (all measured 2026-07-13, AFTER the nudge-leak fix `e5ee73d`, contended machine):**
full suite = 1,157 tests / 179 suites / all green / **99.8s** · minus the `IntegrationTests`
target = 1,108 / 52.4s · pure-unit subset = 908 / **12.1s**.

## 1. What this replaces

The original brief asked for a tiering bolt-on (fast tier by default, slow tiers gated). Allen
superseded it with a redesign, in three parts:

1. **Prune** — delete tests that guard long-fixed bugs or impossible states. Obvious deletions
   are made directly; judgment calls go to Allen as a list with per-test reasoning. (This
   intentionally overrides the earlier "no test may be dropped" definition of done.)
2. **No real external waits or mutation** — tests must not sleep on wall-clock time or mutate
   shared git/filesystem/tmux state. This is the source of the cross-card flakiness.
3. **Organize** — the test tree mirrors the source tree, so the tests relevant to a change are
   obviously detectable from the file system.

## 2. The measured disease (what the design must cure)

The suite's wall-clock is **blocking, not work**. `Archive — scratch cards` reports 51.7s inside
a full run and takes 0.089s alone; `Ship choreography` reports 52.7s, takes 7.2s alone. Tests
that sleep or poll hold swift-testing concurrency slots while doing nothing, and everything
queued behind them inflates. The entire 99.8s full-suite figure is one test — `Slow-repo
lifecycle E2E — SMOKE (both agents)` at 99.821s.

Two root causes, both *shared ambient state*:

- **Time.** 146 sleep call sites in `Tests/`. Worst offenders: `CodexWakeTests.swift:143`
  (1300ms), `TaskStoreTests.swift:86` (1100ms — waits for a distinct ISO8601 second),
  `ControlClientTests.swift:152` (1s), `E2EBinaryTests.swift:219` (1.5s). These pass idle and
  fail under load — before the nudge fix they produced 24 failures on a clean branch. The
  `usleep()`s in `Stubs.swift` (49, 192, 202, 246, 273, 290) are *deliberate* injected latency
  used to widen race windows; they are race tests written as timing hopes.
- **Paths.** `Config.home` (`Sources/OrchestraKit/Config.swift:91`) reads `$HOME`, and
  `scratchRoot` / `dataDir` / `socketPath` / `configPath` / `hooksPath` are statics derived from
  it. One `HOME` per test process ⇒ ~950 tests share one scratch root, one data dir, one socket
  path. `sweepOrphanScratch` (`OrchestraService.swift:580`) deletes every dir under the shared
  scratch root not owned by a live card — i.e. sibling suites' in-flight fixtures. That is why
  `scratchTestLock` (`Tests/OrchestraCoreTests/Stubs.swift:428–455`) exists: a global mutex
  serializing scratch tests across suites.

What is *not* the disease: real git (`git init` ≈ 10ms) and real files in private temp dirs
(µs). `GitHermeticBootstrap` (landed on main) already redirects `HOME` to a `mkdtemp` and
neuters git config bundle-wide, so the suite cannot touch Allen's real machine state. The
remaining problem is state shared *within* the bundle, between concurrently running tests.

Also out of scope: build time. SwiftPM merges all test targets into one bundle, so any tiering
cuts what *runs*, never what *compiles*. Compile cost belongs to the (merged)
`perf/build-cache-and-contention` card.

## 3. Design principle

**Isolate everything, mock most, fake time always.** Not "mock everything": git is Orchestra's
domain logic, so a thin real-git/real-tmux contract layer survives to keep the mocks honest.
And not "mock the filesystem": real files in per-test private roots are fast and need no seam.

## 4. The four seams

### 4.1 Time is injected (`TestClock`)

Production code that sleeps or schedules (nudge loops, grace timers, backoff, watch loops,
liveness polls) takes a clock instead of hardcoding `Task.sleep` / `ContinuousClock`:

- A `Clock<Duration>`-conforming seam threaded through `OrchestraService` and the loops it owns.
  Production passes `ContinuousClock()`; the default parameter keeps call sites unchanged.
- `TestClock` (in test support) with `advance(by:)`: jumping time resumes every sleeper whose
  deadline passed, in microseconds. An hour of exponential backoff becomes one `advance`.
- **Mandatory sharp edge:** a naive fake clock races — the test can `advance` before the code
  under test has parked in `sleep`, and the sleeper then never wakes. `TestClock` therefore
  exposes *"wait until N sleepers are parked"* so tests synchronize on readiness, never on
  timing. (Same solution as Point-Free's swift-clocks.)
- Timestamp generation (`TaskStoreTests`' distinct-ISO8601-second wait) gets an injected
  `now()` date source, not a condition wait — there is nothing to wait *for*.

End state: **zero `sleep`/`usleep`/poll-loop calls in `Tests/`** outside the contract/e2e layer,
enforced by a lint (§8).

### 4.2 Paths are injected (`Paths`)

Injected path state, deliberately narrowed (plan-review amendment) to the two properties through
which one test's filesystem effects can reach another: instance `Config.scratchRoot` and
`Config.runtimeStateDir` (the readonly-settings write under `dataDir`). Every other derived path
is ALREADY per-instance injected via store constructors (`TaskStore(path:)`, `TrustLedger(path:)`,
`Inbox(path:)`, `WatchRegistryStore(path:)`, `borrowsPath`, `markersDir` — TestEnv passes all of
them under its private base), and the remaining statics (`socketPath`, `hooksPath`, `tmuxSocket`)
are launch/CLI-surface values unit tests never exercise. Both new properties are **non-Codable**:
`setConfig` replaces `Config` wholesale from the control plane, and `scratchRoot` is the fence
`PhaseStepper` checks immediately before `rm -rf` — it must be neither wire-settable nor persisted
as a stale absolute path across HOME redirects. `OrchestraService.setConfig` carries the running
instance's values across every replacement.

Consequences, in order: `sweepOrphanScratch` sweeps only its own root → the cross-suite
destruction disappears → `scratchTestLock` and its 12 call sites are **deleted** → the suite
de-serializes → concurrent cards stop colliding on `~/.orchestra` paths entirely.

### 4.3 Process execution is mocked at a gateable seam (`FakeProc`)

Today `Proc.run` is a static reached from everywhere; `WorktreeRegistry` already takes a `run:`
closure and `Stubs.swift` has a `Recorder`. This generalizes into one seam:

- An **async** `ProcRunning` protocol (`run(argv, cwd, env, timeout) async throws → ProcResult`),
  production-implemented by `RealProc` (blocking `Proc.run` inline — today's thread semantics
  exactly), injected into the components the hidden-integration suites reach git through
  (BranchLineage, RemoteParents, the tree/parent-ref probes). Async is load-bearing:
  BranchLineage and RemoteParents are actors, so a blocking gate would wedge their cooperative
  thread and deadlock the test's next await; a suspension gate cannot. Launch-time forks
  (Launcher, adapters, SessionManager) stay on `Proc` behind their existing protocol seams.
- `FakeProc`: scripted responses keyed by argv pattern, full invocation recording (assert on
  *intent*: "we ran `git worktree add -b …`"), and — the load-bearing part — **gates**:

  ```swift
  let gate = worktrees.ensureGate           // the StubWorktrees seam — WorktreeRegistry is its
  async let spawn = service.spawn(card)     // own actor, so its gate lives at the stub, and the
  await gate.reached()                      // lineage/remote gates live on FakeProc; both park
  await service.reconcile()                 // by SUSPENSION, so the racing op runs deterministically
  gate.release(.success)
  #expect(await spawn.phase == .live)
  ```

  A gated call suspends until the test releases it, so every race/interleaving test exercises the
  *exact* schedule it names, every run — including interleavings (a poll landing in a 3ms
  window) that real timing can essentially never produce. Gates replace every
  `usleep`-to-widen-the-window in `Stubs.swift` and every `ensureSleepMs`-style knob.

~95% of tests use `FakeProc` and assert on intent. They are pure, parallel-safe, and instant.

### 4.4 A thin real contract layer keeps the mocks honest

If everything is mocked, nothing validates that the command strings we generate actually work —
a mock passes even when the flag is wrong or git's porcelain changed. So a small
**contract tier** (a few dozen tests) runs real `git` (and a real tmux server on a private
socket) against per-test private temp repos, no concurrency tricks, asserting "this exact
invocation does what the production code believes." The existing hidden-integration suites are
the quarry: most of their *logic* assertions move to unit tests over `FakeProc`; their
real-git essence distills into contract tests. `GitHermeticityTests` already is one.
Contract tests run inside the `GitHermeticBootstrap` throwaway HOME with a fixed injected git
identity, so the suite is independent of the machine's git settings — it behaves identically on
a box with no `~/.gitconfig` at all. The only machine requirements are the tool binaries
themselves (`git`, `tmux`; built products for e2e).

**No virtual filesystem.** Isolate (per-test roots), don't mock. A fake FS would route every
`FileManager` call through a seam forever and buy nothing — the FS was never the cost.

## 5. Organization: the test tree mirrors the source tree

```
Tests/
  UnitTests/                     ← ONE target; directories mirror Sources/
    OrchestraCore/
      Agents/ Control/ Diff/ Keyboard/ …   (same subfolders as Sources/OrchestraCore)
    OrchestraKit/  …
    OrchestraUI/   …
  ContractTests/                 ← real git / real tmux, per-test private roots
    Git/  Tmux/  Proc/           (grouped by the tool whose behavior they pin)
  E2ETests/                      ← built binaries + slow-repo fixture (both agents)
    Cli/  Mcp/  Daemon/  SlowRepo/   (mirrors the product targets: orchestra, orchestra-mcp, orchestrad)
  TestSupport/                   ← TestClock, FakeProc, Paths fixtures, TestEnv (target, not tests)
  GitHermeticBootstrap/          ← existing C hermeticity target (unchanged)
```

- **Tier = target.** Auditable by construction (a file is in exactly one target), uniform across
  the mixed swift-testing + XCTest population, and selectable *today* via `--filter`/`--skip`
  regex over `<target>.<suite>/<test>` (verified working; tag-based filtering does not exist on
  Swift 6.3.3 — swiftlang/swift-testing#591, milestone 6.4.0). `@Tag` metadata is added anyway:
  free now in IDE navigators, and `--filter tag:` lights up on 6.4 with no migration.
- **Area = directory.** `Tests/UnitTests/OrchestraCore/Diff/` is where `Sources/OrchestraCore/
  Diff/` tests live — Allen's "obviously detectable, parallel in the file system" requirement.
  Cross-area service tests (spawn/archive/ship choreography over the whole service) live under
  `OrchestraCore/Service/`, named for the flow they exercise.
- The 30 real-git suites currently hiding in `Tests/OrchestraCoreTests/` (BorrowLifecycle,
  ShipChoreo, TreeStat, MergeRequestBackoff, ServiceTeardown, RemoteWatchLoop, …) are split:
  logic → `UnitTests` over `FakeProc`; real-git essence → `ContractTests`. The audit that found
  them is done and reused; note that a grep lint would have misfiled 6 of them (they reach git
  only via `TestEnv.makeReal()` / cross-file helpers), which is why tier = target, not pattern.

### Selection policy (what runs when)

| invocation | runs | when |
|---|---|---|
| `./scripts/test.sh` | `UnitTests` (everything mirrored) | default; every task loop |
| `./scripts/test.sh --contract` | + `ContractTests` | touching git/tmux/proc command generation |
| `./scripts/test.sh --e2e` | + `E2ETests` | touching binaries/daemon wiring |
| `./scripts/test.sh --all` | whole matrix | merge gate, once per PR |

**Selection is additive and fail-safe — structure is not a license to skip.** The evidence: a
co-change analysis over 359 commits (leave-one-out validated) shows `Foo.swift → FooTests.swift`
is right only 51% of the time, a tighter map picks zero correct tests on 48% of commits, and
`OrchestraService.swift` appears in 31% of all source commits co-changing with 82 files. And the
unit tier is already 12s *before* this redesign removes the sleeps — running all of it is
cheaper than deciding what to skip. Once the sleeps die, the expectation is the whole unit tier
in low single-digit seconds, at which point per-change selection buys nothing on the fast path;
the directory mirror is for *navigation* (find the tests for this code) and for choosing which
*slow* tier to add.

## 6. Pruning policy

Delete directly (recorded in the PR description with one line each):

1. Tests asserting on code paths that no longer exist.
2. Provable duplicates — another test makes the identical assertion on the identical path.
3. Tests that only exercise stub behavior (they test the fake, not production).

Goes to Allen as a decision list with per-test reasoning:

4. Regression tests for fixed bugs where it takes judgment whether the bug is still
   *representable* in the current code. If the restructure made the state impossible, deletion
   is proposed; if it still guards a live invariant, it stays (possibly rewritten over the new
   seams, usually becoming stronger — a gate instead of a timing hope).

Accounting is exact in both directions: the final report states tests deleted (with reasons),
tests merged, tests added, and reconciles start count → end count. Nothing disappears silently.

## 7. Staging

Exclusive repo access (no other cards until this lands), so staging is for review quality:

- **Stage 1 — seams and semantics (all the risk lives here).** Introduce `Paths`, the clock
  seam, `ProcRunner`/`FakeProc` with gates. Convert sleeps to clock advances and race windows to
  gates; delete `scratchTestLock`; prune category 1–3 deletions; produce the category-4 list.
  Behaviour-preserving for production (default parameters = today's values). The suite must be
  green after every task.
- **Stage 2 — the moves (near-mechanical).** Create the new targets, `git mv` files into the
  mirror layout, split the hidden-integration suites into unit + contract, update
  `Package.swift` and `scripts/test.sh` flags. Reviewable as a mapping table.
- **Stage 3 — docs and guardrails.** `CLAUDE.md`, `docs/08-building-operations.md`, plan
  templates: *fast tier per task, `--all` once at the merge gate* (today's plans mandate a full
  `swift test` after every task — ~126 references across 10 PR plans). Add the lints (§8).

## 8. Guardrails against re-clumping

- **No-sleep lint:** CI/script check that `Tests/UnitTests/` contains no
  `sleep`/`usleep`/`Task.sleep`/`Thread.sleep` (contract/e2e allowed where genuinely waiting on
  an external process, but condition-waits preferred).
- **No-ambient-path lint:** `Tests/UnitTests/` must not reference `NSHomeDirectory()`,
  `Config.defaultScratchRoot`, or the derived write-target statics (`dataDir`/`tasksPath`/
  `hooksPath`/`socketPath`/`logPath`). `Config.home` itself is deliberately excluded — it is a
  pure derivation input asserted by the config-derivation tests; the hazard is shared filesystem
  state through the write targets, not reading the env var.
- **Tier honesty:** enforced by the default construction path plus the lint, not the type system
  (`RealProc` remains a public symbol): `TestEnv.make` hands out `FakeProc` + per-test paths by
  default, `TestEnv.makeReal()` lives in `ContractTests`' support, and lint rules ban `Proc.`
  calls, `RealProc(`, and `makeReal` from the unit tier.
- **Both agents stay covered:** the slow-repo E2E remains parameterized over claude-code and
  codex; the shared 12k-repo fixture is generated once per run and shared across both cases.

## 9. What we report at the end

- Wall-clock per tier (unit / contract / e2e / all), measured on an idle machine, explicitly
  post-nudge-fix, alongside today's 99.8s / 52.4s / 12.1s baseline.
- The exact test accounting of §6.
- Zero sleeps in unit; `scratchTestLock` deleted; race tests enumerable as gate schedules.

## 10. Risks

- **Init-signature churn.** Threading clock/paths/runner through `OrchestraService` touches many
  call sites. Mitigation: default parameters preserve every production call site; only tests
  pass overrides.
- **TestClock's own race** — addressed by design (§4.1 sleeper-park synchronization), not left
  to discovery.
- **Mock drift** — the contract tier exists precisely for this; every `FakeProc` scripted
  response shape should have a contract test pinning the real behavior it imitates.
- **One-bundle caveat** — tier selection cuts run time only; compile time is unchanged and out
  of scope here.
