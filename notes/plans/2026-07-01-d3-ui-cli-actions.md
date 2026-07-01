# D3 — Board/CLI Actions + SpawnSheet Trust · UX-e2e Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development for each backend task (red → green → commit). Steps use checkbox (`- [ ]`) syntax for tracking. App-UI tasks are guarded by `typecheck-app.sh` (not unit tests); the UX-e2e is advisory (screenshot may fail headless).

**Goal:** Ship the dual-surface (board + CLI) live-delivery actions — **Handoff / Fork / Send / Fan-out** — plus **SpawnSheet trust · read-only · cancel** controls, and add the **UC1–UC8 UX-e2e** drivers on the isolated app+daemon harness.

**Architecture:** Reuse the command set D1 already landed. `handoff`, `send`, `wait` exist. **Fork = `spawn` with a seed; Fan-out = `batch-spawn` with a seed** — so the one backend primitive D3 adds is a **`seed` on `SpawnInput`** folded into the launch prompt inside `OrchestraService.spawn` (no adapter change; `start` keeps its single positional). The SpawnSheet trust control reads T1's ledger via a new **read-only `trustState`** query command (T2 owns the actual grant). The app wires thin `BoardModel` methods to these commands; the UI (InspectorView actions, Toolbar Fan-out, SpawnSheet) is typecheck-guarded. The UX-e2e replays UC1–UC8 by driving the isolated daemon over RPC with a fake-agent fixture on PATH.

**Tech Stack:** Swift 6 / swift-testing (`@Suite`/`@Test`/`#expect`), OrchestraCore actor model, SwiftUI (App target, typecheck only), bash + `orch-rpc.py` for the UX-e2e.

## Global Constraints

- **Only new `Command`s touch `CommandsTests.expected`.** IF (and only if) I add a `Command` to `CommandRegistry.build()`, I MUST (a) add its name to `expected` in `Tests/OrchestraCoreTests/CommandsTests.swift` and (b) add a `CLIRunner` `case`. MCP parity (`E2EBinaryTests`) auto-derives from `registry.names` — no edit needed there.
- **Reuse existing Commands.** `handoff` (F1, D1), `send` (F3), `wait` (F2, D1), `spawn`, `batch-spawn` already exist — do NOT duplicate them. Fork/Fan-out are `spawn`/`batch-spawn` calls with `seed` set.
- **No adapter-launch changes.** Seed for a *fresh* spawn folds into the launch prompt in `spawn()`; `ctx.seed` stays the resume-only carrier (C3). Claude/Codex/Stub `start` argv stays byte-identical → `AdapterTests`/`ReportTests`/`HandoffResumeTests` stay green.
- **Trust: read-only in D3.** D3 only *reads* trust state (`trust.isTrusted`, side-effect-free). The *grant* (writing the ledger via elicitation / `orchestra trust`) is T2. `trustState` must NOT call `resolveTrust` (which records for scratch/worktree).
- **UX-e2e isolation (unchanged contract):** isolated `$HOME` + `ORCHESTRA_TMUX_SOCKET`; `orchestrad` spawned DIRECTLY (never launchctl — fixed label `com.orchestra.daemon` collides with live); screenshot by OWNER PID; `USE_REAL_CLAUDE` stays unset (fake-agent fixture on PATH). Screenshot failure = expected headless outcome, NOT a defect.
- **Build:** `swift build`/`test` need an UNSANDBOXED shell. `typecheck-app.sh` self-pins CLT (no `DEVELOPER_DIR`). Stale build → `rm -rf .build` in THIS worktree only.
- **Known flake:** `no SessionStart callback in 2s` — if it's the ONLY failure, re-run the suite `--filter` in isolation and treat green.

---

## File Structure

- **Modify** `Sources/OrchestraCore/Model.swift` — add `SpawnInput.seed` (init + Codable decode).
- **Modify** `Sources/OrchestraCore/OrchestraService.swift` — fold `input.seed` into the launch prompt in `spawn()`.
- **Modify** `Sources/OrchestraCore/Commands.swift` — `seed` param on `spawn` + `batch-spawn`; new `trustState` command.
- **Modify** `Sources/orchestra/CLIRunner.swift` — `--seed` on `spawn`/`batch-spawn`; `trustState` case.
- **Modify** `Sources/orchestra/CLIHelp.swift` — help lines for `--seed` and `trustState`.
- **Modify** `Tests/OrchestraCoreTests/CommandsTests.swift` — add `trustState` to `expected`.
- **Create** `Tests/OrchestraCoreTests/SpawnSeedTrustTests.swift` — seed-fold + trustState unit tests.
- **Modify** `App/BoardModel.swift` — `handoff`, `fork`, `fanout`, `trustState` thin wrappers.
- **Modify** `App/Views/InspectorView.swift` — Handoff / Fork / Send card actions.
- **Modify** `App/Views/ToolbarView.swift` — Fan-out board action.
- **Modify** `App/Views/SpawnSheet.swift` — freeform trust · read-only · cancel control + a `context`(seed) field for Fork-into-sheet reuse.
- **Create** `scripts/fixtures/fake-agent` — a no-op `claude`-shaped binary for the UX-e2e PATH.
- **Modify** `scripts/orch-ux-e2e.sh` — put the fixture on PATH; add UC1–UC8 RPC drivers.

---

## Task 1: `SpawnInput.seed` + fold into the launch prompt (the Fork/Fan-out primitive)

**Files:**
- Modify: `Sources/OrchestraCore/Model.swift` (`SpawnInput` ~510–546)
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (`spawn` ~137–215)
- Test: `Tests/OrchestraCoreTests/SpawnSeedTrustTests.swift` (create)

**Interfaces:**
- Produces: `SpawnInput(prompt:…, seed: String? = nil)`; `spawn(SpawnInput)` where a non-nil `seed` is folded **ahead of** `prompt` into the card's `initialPrompt` and the launch positional. When `prompt` is empty but `seed` is present, the card is NOT provisional (it launches on the seed) and the title seeds from the seed's first line.
- Consumes (later tasks): `spawn`/`batch-spawn` Commands set `seed`; `BoardModel.fork`/`fanout` pass it.

- [ ] **Step 1: Write the failing test** — `Tests/OrchestraCoreTests/SpawnSeedTrustTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchestraCore

@Suite("D3 · spawn seed (Fork/Fan-out primitive)")
struct SpawnSeedTests {

    @Test("spawn with a seed folds it ahead of the prompt into the launch positional")
    func seedFoldedIntoLaunch() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(
            SpawnInput(prompt: "Do the fork task", repo: repo, branch: "fk", seed: "PARENT-CONTEXT"))
        // The launch argv the daemon handed the session carries the folded seed + prompt as ONE positional.
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        let positional = try #require(argv.last)
        #expect(positional.contains("PARENT-CONTEXT"))
        #expect(positional.contains("Do the fork task"))
        // Seed comes first (it's the context the fresh task opens on).
        #expect(positional.range(of: "PARENT-CONTEXT")!.lowerBound
                < positional.range(of: "Do the fork task")!.lowerBound)
    }

    @Test("seed-only spawn (empty prompt) launches on the seed and is not provisional")
    func seedOnlyNotProvisional() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(
            SpawnInput(prompt: "", repo: repo, branch: "fk2", seed: "SLICE"))
        #expect(t.titleProvisional == false)
        #expect(t.status == .running)
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(try #require(argv.last).contains("SLICE"))
    }

    @Test("spawn without a seed is unchanged (no seed positional)")
    func noSeedUnchanged() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "plain", repo: repo, branch: "p"))
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.last == "plain")
    }
}
```

- [ ] **Step 2: Run to verify failure** — `./scripts/test.sh --filter SpawnSeedTests` → FAIL (`seed:` label unknown on `SpawnInput`). Confirm `env.sessions.ensureArgv` + `TestEnv.make()`/`TestEnv.repo` exist (they back `HandoffResumeTests`); if the stub env accessor differs, mirror `HandoffResumeTests`' env shape.

- [ ] **Step 3: Add `seed` to `SpawnInput`** — in `Model.swift`, add the stored prop, init param (defaulted `nil`, placed last), and `decodeIfPresent` in `init(from:)`:

```swift
    /// Authored fork/fan-out context (the parent slice / handoff summary) for a FRESH spawn. Folded
    /// ahead of `prompt` into the launch positional in `OrchestraService.spawn` (F1's `ctx.seed` is the
    /// resume-only carrier; a fresh start delivers the seed as the initial prompt). nil ⇒ no seed.
    public var seed: String?
```

Add `seed: String? = nil` to the memberwise init (last param), assign `self.seed = seed`, and in `init(from:)`: `self.seed = try c.decodeIfPresent(String.self, forKey: .seed)`. Add `seed` to the `CodingKeys` (synthesized keys include it automatically since `SpawnInput` uses the compiler-synthesized `CodingKeys` — verify: `SpawnInput` has no explicit `CodingKeys`, so adding the stored property is enough for decode; keep the explicit `decodeIfPresent` for forward-compat).

- [ ] **Step 4: Fold the seed in `spawn()`** — in `OrchestraService.spawn`, replace the `provisional`/`launchPrompt`/`title` block (~178–184) so the seed folds ahead of the prompt:

```swift
        // Fork / fan-out: an authored seed (parent slice / handoff context) is delivered to a FRESH
        // card by folding it AHEAD of the prompt into the single launch positional (Claude/Codex take
        // one positional). Bounded like the F3 drain so a huge slice can't blow the argv.
        let seed = input.seed?.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptText = input.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded: String? = {
            switch (seed?.isEmpty == false ? seed : nil, promptText.isEmpty ? nil : input.prompt) {
            case let (s?, p?): return String((s + "\n\n" + p).prefix(StopDrain.maxPayloadChars))
            case let (s?, nil): return String(s.prefix(StopDrain.maxPayloadChars))
            case let (nil, p?): return p
            case (nil, nil): return nil
            }
        }()
        // Provisional (name-from-first-prompt) only when there is neither a prompt NOR a seed.
        let provisional = folded == nil
        let title = provisional ? (input.branch.isEmpty ? "New agent" : input.branch)
                                 : titleSeed(from: folded ?? input.prompt)
        let launchPrompt: String? = folded
```

Then keep the existing `Task(...)` construction, but set `initialPrompt: folded ?? input.prompt` so the persisted prompt reflects what was launched. (Search the `Task(...)` init in spawn and change `initialPrompt: input.prompt` → `initialPrompt: folded ?? input.prompt`.)

- [ ] **Step 5: Run to verify pass** — `./scripts/test.sh --filter SpawnSeedTests` → PASS (3 tests). Then run the seed-adjacent suites to prove no regression: `./scripts/test.sh --filter HandoffResumeTests` and `--filter CommandsTests` → green.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Model.swift Sources/OrchestraCore/OrchestraService.swift Tests/OrchestraCoreTests/SpawnSeedTrustTests.swift
git commit -m "feat(d3): SpawnInput.seed folded into launch prompt (Fork/Fan-out primitive)"
```

---

## Task 2: `seed` param on `spawn` + `batch-spawn` Commands & CLI

**Files:**
- Modify: `Sources/OrchestraCore/Commands.swift` (`spawn` ~37–61, `batch-spawn` ~196–213)
- Modify: `Sources/orchestra/CLIRunner.swift` (`spawn` ~24–45, `batchSpawn` ~188–214)
- Modify: `Sources/orchestra/CLIHelp.swift`
- Test: `Tests/OrchestraCoreTests/SpawnSeedTrustTests.swift` (extend)

**Interfaces:**
- Consumes: `SpawnInput.seed` (Task 1).
- Produces: `spawn` accepts optional `seed`; each `batch-spawn` task entry accepts optional `seed`. CLI: `orchestra spawn … --seed <text>` (Fork); batch-spawn JSON entries may carry `"seed"`.

- [ ] **Step 1: Write the failing test** — add to `SpawnSeedTests`:

```swift
    @Test("spawn Command threads `seed` to the service")
    func spawnCommandSeed() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let reg = CommandRegistry()
        let spawn = try #require(reg.command("spawn"))
        let params = JSONValue.object([
            "prompt": .string("task"), "repo": .string(repo), "branch": .string("s"),
            "seed": .string("FORK-SEED"),
        ])
        let task = try await spawn.run(env.svc, params, .mcp).decode(Task.self)
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(task.id)])
        #expect(try #require(argv.last).contains("FORK-SEED"))
    }
```

- [ ] **Step 2: Run to verify failure** — `./scripts/test.sh --filter spawnCommandSeed` → FAIL (seed ignored; positional == "task").

- [ ] **Step 3: Add `seed` to the `spawn` Command** — in `Commands.swift` `spawn` params, add after `"model"`:

```swift
                        "seed": strProp("Fork/fan-out context (the parent slice / handoff summary) the "
                            + "fresh card opens on — folded ahead of `prompt`."),
```

and in the `SpawnInput(...)` init inside the handler add `seed: p.optString("seed"),`.

- [ ] **Step 4: Thread `seed` through `batch-spawn`** — in the `batch-spawn` handler's per-item `SpawnInput(...)`, add `seed: item.optString("seed")`. (No schema change needed — `tasks` is a free array; document `seed` in the description string.)

- [ ] **Step 5: CLI** — in `CLIRunner.swift` `spawn` case, after the model/col merges, thread `--seed`:

```swift
                let p = JSONValue.object(fields
                    .merging(optional("model", flags.value("model"))) { a, _ in a }
                    .merging(optional("col", flags.value("col"))) { a, _ in a }
                    .merging(optional("seed", flags.value("seed"))) { a, _ in a })
```

(`batch-spawn` CLI reads JSON entries from stdin, which already pass `seed` through verbatim — no change.) Add help lines in `CLIHelp.swift`: on the `spawn` worktree line append ` [--seed <ctx>]` and a comment `# --seed = fork context`.

- [ ] **Step 6: Run to verify pass** — `./scripts/test.sh --filter SpawnSeedTests` → PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/OrchestraCore/Commands.swift Sources/orchestra/CLIRunner.swift Sources/orchestra/CLIHelp.swift Tests/OrchestraCoreTests/SpawnSeedTrustTests.swift
git commit -m "feat(d3): --seed on spawn/batch-spawn (Fork/Fan-out via existing commands)"
```

---

## Task 3: `trustState` read-only query Command (SpawnSheet trust wiring)

**Files:**
- Modify: `Sources/OrchestraCore/Commands.swift` (add command)
- Modify: `Tests/OrchestraCoreTests/CommandsTests.swift` (`expected` ~11–13)
- Modify: `Sources/orchestra/CLIRunner.swift` (add case)
- Modify: `Sources/orchestra/CLIHelp.swift`
- Modify: `Sources/OrchestraCore/OrchestraService.swift` (add a side-effect-free `isPathTrusted`)
- Test: `Tests/OrchestraCoreTests/SpawnSeedTrustTests.swift` (extend)

**Interfaces:**
- Produces: Command `trustState` with params `{ "path": string }` → result `{ "trusted": bool }`. Pure read of the `TrustLedger` (no record). Backs the SpawnSheet freeform trust control. The *grant* is T2's separate `trust` command.
- Consumes: `TrustLedger.isTrusted` (T1).

- [ ] **Step 1: Write the failing test** — add a `@Suite`:

```swift
@Suite("D3 · trustState query (read-only)")
struct TrustStateTests {

    @Test("registry includes trustState")
    func inRegistry() {
        #expect(CommandRegistry().command("trustState") != nil)
    }

    @Test("untrusted path → trusted:false; recorded path → trusted:true; no side effect")
    func trustStateQuery() async throws {
        let env = TestEnv.make()
        let reg = CommandRegistry()
        let cmd = try #require(reg.command("trustState"))
        let dir = env.base + "/borrowed-dir"

        let before = try await cmd.run(env.svc, .object(["path": .string(dir)]), .app)
        #expect(before["trusted"]?.boolValue == false)
        // Querying must NOT record — a second query is still false.
        let again = try await cmd.run(env.svc, .object(["path": .string(dir)]), .app)
        #expect(again["trusted"]?.boolValue == false)

        try await env.trust.record(dir, grantedBy: .human)
        let after = try await cmd.run(env.svc, .object(["path": .string(dir)]), .app)
        #expect(after["trusted"]?.boolValue == true)
    }
}
```

(If `TestEnv.make()` doesn't expose `.trust`, mirror the env accessor used in `TrustLedgerTests`/`HandoffResumeTests`; the service already holds a `trust` ledger — expose or reach it the same way those suites do.)

- [ ] **Step 2: Run to verify failure** — `./scripts/test.sh --filter TrustStateTests` → FAIL (`trustState` nil). Also expect `CommandsTests.fullSet` to now FAIL once the command lands (Set mismatch) — that's why Step 4 updates `expected`.

- [ ] **Step 3: Add a side-effect-free trust read on the service** — in `OrchestraService.swift` near `resolveTrust`:

```swift
    /// Pure trust query for a prospective borrowed cwd (SpawnSheet's trust indicator). Unlike
    /// `resolveTrust`, this NEVER records — it only reads the ledger. The grant surface is T2.
    public func isPathTrusted(_ path: String) async -> Bool {
        await trust.isTrusted(path)
    }
```

- [ ] **Step 4: Add the `trustState` Command** — in `Commands.swift build()` (after `sessions`, before `batch-spawn` or at the end of the array):

```swift
            Command(name: "trustState",
                    summary: "Is a directory already trusted? Read-only ledger query for the spawn "
                        + "sheet's trust indicator — never grants (granting is the `trust` tool).",
                    params: schema(["path": strProp("Absolute directory path to check")],
                                   required: ["path"])) { svc, p, _ in
                let trusted = await svc.isPathTrusted(try p.string("path"))
                return .object(["trusted": .bool(trusted)])
            },
```

- [ ] **Step 5: Update `expected`** — in `CommandsTests.swift`, add `"trustState"` to the `expected` array.

- [ ] **Step 6: CLIRunner + help** — add a case:

```swift
            case "trustState":
                let path = flags.positional(0) ?? flags.require("path")
                let r = try await client.call("trustState", .object(["path": .string(path)]))
                print(r["trusted"]?.boolValue == true ? "trusted" : "untrusted")
```

Add to `CLIHelp.swift`: `trustState <path>    Is a directory trusted? (read-only)`.

- [ ] **Step 7: Run to verify pass** — `./scripts/test.sh --filter TrustStateTests` and `--filter CommandsTests` → green. Then `./scripts/test.sh --filter E2EBinaryTests` (parity) → green (auto-derives from `registry.names`). Note: `E2EBinaryTests` may surface the known `SessionStart callback` flake — re-run in isolation if it's the only failure.

- [ ] **Step 8: Commit**

```bash
git add Sources/OrchestraCore/Commands.swift Sources/OrchestraCore/OrchestraService.swift Sources/orchestra/CLIRunner.swift Sources/orchestra/CLIHelp.swift Tests/OrchestraCoreTests/CommandsTests.swift Tests/OrchestraCoreTests/SpawnSeedTrustTests.swift
git commit -m "feat(d3): trustState read-only query command (SpawnSheet trust indicator)"
```

---

## Task 4: `BoardModel` action wrappers (app-side)

**Files:**
- Modify: `App/BoardModel.swift` (actions section ~208–305)

**Interfaces:**
- Produces (consumed by Task 5 UI): `handoff(_ id: UUID, context: String)`, `fork(from: Task, prompt: String, branch: String, context: String)`, `fanout(prompts: [String], repo: String, branch: String)`, `trustState(path: String) async -> Bool`. `send`, `spawn` already exist.
- Consumes: `handoff`/`spawn`/`batch-spawn`/`trustState` Commands.

- [ ] **Step 1: Add the wrappers** (no unit test — app target; validated by `typecheck-app.sh` + UX-e2e). Mirror the existing thin style (call `client.call`, `apply`, `toast`):

```swift
    /// Clean-context handoff (F1): resume THIS card seeded with `context` (folded with its inbox).
    func handoff(_ id: UUID, context: String) async {
        do {
            let t = try await client.call("handoff",
                .object(["ref": .string(id.uuidString), "context": .string(context)])).decode(Task.self)
            apply(.taskUpserted(t))
            toast("Handed off “\(t.title)”", sub: "clean context")
        } catch { toast("Handoff failed", sub: "\(error)", color: .red) }
    }

    /// Fork: spawn a NEW worktree card seeded with `context` (the parent slice). `spawn --seed`.
    func fork(from parent: Task, prompt: String, branch: String, context: String) async {
        var p: [String: JSONValue] = [
            "prompt": .string(prompt), "repo": .string(parent.repo), "branch": .string(branch),
            "seed": .string(context), "col": .string(StartIn.impl.rawValue),
        ]
        if !parent.model.id.isEmpty { p["model"] = .string(parent.model.id) }
        do {
            let t = try await client.call("spawn", .object(p)).decode(Task.self)
            apply(.taskUpserted(t)); selectedId = t.id
            toast("Forked “\(t.title)”", sub: "\((parent.repo as NSString).lastPathComponent) · \(branch)")
        } catch { toast("Fork failed", sub: "\(error)", color: .red) }
    }

    /// Fan-out: batch-spawn one worktree card per prompt line, same repo/branch base.
    func fanout(prompts: [String], repo: String, branch: String) async {
        let tasks = prompts.enumerated().map { i, prompt in
            JSONValue.object(["prompt": .string(prompt), "repo": .string(repo),
                              "branch": .string("\(branch)-\(i + 1)")])
        }
        do {
            let res = try await client.call("batch-spawn", .object(["tasks": .array(tasks)]))
                .decode(BatchSpawnResult.self)
            for t in res.spawned { apply(.taskUpserted(t)) }
            toast("Fanned out \(res.spawned.count) card(s)",
                  sub: res.failed.isEmpty ? nil : "\(res.failed.count) failed",
                  color: res.failed.isEmpty ? .green : .red)
        } catch { toast("Fan-out failed", sub: "\(error)", color: .red) }
    }

    /// Read-only trust check for the spawn sheet's freeform trust indicator.
    func trustState(path: String) async -> Bool {
        (try? await client.call("trustState", .object(["path": .string(path)]))
            .decode(TrustStateResult.self))?.trusted ?? false
    }
```

Add a tiny decode helper (top of file, near `Toast`): `private struct TrustStateResult: Codable { let trusted: Bool }` — OR decode inline via `["trusted"]?.boolValue`. Prefer inline to avoid a new type:

```swift
    func trustState(path: String) async -> Bool {
        guard let r = try? await client.call("trustState", .object(["path": .string(path)])) else { return false }
        return r["trusted"]?.boolValue ?? false
    }
```

- [ ] **Step 2: Typecheck** — `./scripts/typecheck-app.sh` → clean.

- [ ] **Step 3: Commit**

```bash
git add App/BoardModel.swift
git commit -m "feat(d3): BoardModel handoff/fork/fanout/trustState wrappers"
```

---

## Task 5: App UI — Handoff/Fork/Send actions, Fan-out, SpawnSheet trust control

**Files:**
- Modify: `App/Views/InspectorView.swift` (HeaderBar ~35–88)
- Modify: `App/Views/ToolbarView.swift`
- Modify: `App/Views/SpawnSheet.swift`

**Interfaces:** Consumes Task 4's `BoardModel` methods. No new public API. Guarded by `typecheck-app.sh` + UX-e2e.

- [ ] **Step 1: InspectorView card actions** — in `HeaderBar`, add three buttons (Handoff, Fork, Send) alongside "Archive", each toggling a small state-backed inline sheet/popover with a `TextEditor` + confirm that calls `model.handoff` / `model.fork` / `model.send`. Keep the styling consistent with the existing `.surface(theme.card, …)` buttons. Only show them when `task.status != .dead`. Use `@State private var showHandoff/showFork/showSend` + `@State` text fields on `HeaderBar`. Fork's popover pre-fills `branch = "\(task.branch)-fork"` and `context = ""`, `prompt = ""`; on confirm calls `model.fork(from: task, prompt:, branch:, context:)`.

- [ ] **Step 2: Toolbar Fan-out** — in `ToolbarView`, add a "Fan-out" button that presents a sheet (reuse `BoardModel.showSpawn`-style flag → add `@Published var showFanout = false` to `BoardModel`) containing a repo picker (reuse SpawnSheet's `repoCandidates` pattern or a simple text field), a base branch field, and a multi-line `TextEditor` (one prompt per line); confirm calls `model.fanout(prompts:repo:branch:)` with non-empty trimmed lines. A minimal inline `FanoutSheet` view in `ToolbarView.swift` (or a new small view) is fine.

- [ ] **Step 3: SpawnSheet trust control** — in `SpawnSheet.swift`, freeform (`.freeform`) mode:
  - Add `@State private var cwdTrusted: Bool? = nil` (nil = unknown/unchecked).
  - On `cwd` change (and after the `directoryPicker` sets it), run `_Concurrency.Task { cwdTrusted = await model.trustState(path: cwd) }`.
  - When `cwdTrusted == false` and `!cwd.isEmpty`, render an amber notice below the read-only toggle: `"⚠ Not a trusted directory — it will run read-only (sandboxed) unless you grant trust from the agent’s client or `orchestra trust`."` and **force `readOnly = true` + disable the toggle** (`.disabled(cwdTrusted == false)`), so an untrusted freeform card can only spawn read-only. When `cwdTrusted == true`, show a subtle "Trusted ✓" and leave the toggle free. Cancel already exists. This is the **trust · read-only · cancel** control: trust *status* + read-only fallback + cancel.
  - Guard: reset `cwdTrusted = nil` when leaving freeform mode / clearing `cwd`.

- [ ] **Step 4: Typecheck** — `./scripts/typecheck-app.sh` → clean. Fix any SwiftUI type errors (e.g. `@State` placement, `_Concurrency.Task` for async calls in button actions).

- [ ] **Step 5: Commit**

```bash
git add App/Views/InspectorView.swift App/Views/ToolbarView.swift App/Views/SpawnSheet.swift App/BoardModel.swift
git commit -m "feat(d3): board/card UI — Handoff/Fork/Send actions, Fan-out, SpawnSheet trust control"
```

---

## Task 6: UX-e2e UC1–UC8 drivers + fake-agent fixture

**Files:**
- Create: `scripts/fixtures/fake-agent` (executable)
- Modify: `scripts/orch-ux-e2e.sh` (PATH + a UC-driver section before the screenshot)

**Interfaces:** Drives the isolated daemon over `orch-rpc.py`. No product code. Advisory (screenshot may fail headless); the merge gate is unit tests + typecheck.

- [ ] **Step 1: Fake-agent fixture** — `scripts/fixtures/fake-agent`, a `claude`-shaped no-op that stays alive so a tmux pane doesn't immediately die (the daemon just needs a launchable binary; UC state is asserted at the daemon layer, not via real agent telemetry):

```bash
#!/usr/bin/env bash
# Fake coding-agent for the UX-e2e. Accepts (and ignores) claude-style flags/positionals and idles so
# the tmux pane stays alive. NEVER contacts a vendor / bills. Selected via a symlinked `claude` on PATH.
echo "[fake-agent] launched: $*" >&2
# Idle until the pane is killed at teardown.
while :; do sleep 3600; done
```

`chmod +x scripts/fixtures/fake-agent`.

- [ ] **Step 2: Put the fixture on PATH in the harness** — in `orch-ux-e2e.sh`, after `RUN_PATH` is computed (~99), when `USE_REAL_CLAUDE != 1`, create a per-run bin dir with a `claude` (and `codex`) symlink to the fixture and prepend it to `RUN_PATH`:

```bash
FAKE_BIN="$ROOT/fakebin"
if [ "${USE_REAL_CLAUDE:-0}" != "1" ]; then
  mkdir -p "$FAKE_BIN"
  ln -sf "$REPO_ROOT/scripts/fixtures/fake-agent" "$FAKE_BIN/claude"
  ln -sf "$REPO_ROOT/scripts/fixtures/fake-agent" "$FAKE_BIN/codex"
  RUN_PATH="$FAKE_BIN:$RUN_PATH"
fi
```

(Place this AFTER `ROOT` is defined; `mkdir -p "$FAKE_BIN"` needs `$ROOT` to exist — do it in the seed step (~197) or `mkdir -p "$FAKE_BIN"` explicitly.)

- [ ] **Step 3: UC1–UC8 driver section** — insert BEFORE the screenshot step (~299). A helper `rpc()` wraps `orch-rpc.py`; each UC drives via RPC and asserts daemon state. Keep them advisory (log ✓/✗ but do not `exit 1` on a UC miss — the screenshot/gate semantics own the exit). Example spine:

```bash
# --- UC1–UC8 replay over the isolated daemon (RPC-driven; no synthetic input) ---
rpc() { ORCH_SOCK="$SOCK" python3 "$REPO_ROOT/scripts/orch-rpc.py" "$@"; }
uc_ok() { echo "  ✓ $1"; }
uc_warn() { echo "  ⚠ $1 (advisory)"; }
REPO="$ROOT/repo"

echo "▶ UC replay (fake-agent on PATH; USE_REAL_CLAUDE unset)"

# UC6 Fan-out — batch-spawn N, assert N cards created.
rpc batch-spawn "{\"tasks\":[
  {\"prompt\":\"fan A\",\"repo\":\"$REPO\",\"branch\":\"fan-a\"},
  {\"prompt\":\"fan B\",\"repo\":\"$REPO\",\"branch\":\"fan-b\"}]}" >/dev/null \
  && uc_ok "UC6 fan-out batch-spawn" || uc_warn "UC6 fan-out"

# UC4/UC5 Fork / handoff→new — spawn with a seed, assert the seed rode into initialPrompt.
FORK=$(rpc spawn "{\"prompt\":\"fork task\",\"repo\":\"$REPO\",\"branch\":\"fork-1\",\"seed\":\"PARENT-SLICE\"}")
echo "$FORK" | grep -q "PARENT-SLICE" && uc_ok "UC4/UC5 fork spawn --seed" || uc_warn "UC4/UC5 fork seed"

# UC7 Send/queue — enqueue to the seeded card's inbox (durable F3).
rpc send "{\"ref\":\"aaaaaa\",\"message\":\"queued via UX-e2e\"}" >/dev/null \
  && uc_ok "UC7 send enqueue" || uc_warn "UC7 send"

# UC3 Handoff clean-context — resume-in-card seeded (same card).
rpc handoff "{\"ref\":\"aaaaaa\",\"context\":\"handoff summary\"}" >/dev/null \
  && uc_ok "UC3 handoff resume-in-card" || uc_warn "UC3 handoff"

# UC2 Reactive DAG / UC1 parallel / UC8 cross-agent — wait + conclude via archive.
# Spawn a child, archive it (settled conclusion), assert `wait` returns it.
CHILD=$(rpc spawn "{\"prompt\":\"child\",\"repo\":\"$REPO\",\"branch\":\"child-1\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])' 2>/dev/null || true)
if [ -n "$CHILD" ]; then
  rpc archive "{\"ref\":\"$CHILD\"}" >/dev/null || true
  rpc wait "{\"refs\":[\"$CHILD\"]}" | grep -q '"kind"' && uc_ok "UC2 wait→conclude (archive)" || uc_warn "UC2 wait"
fi
# UC8 cross-agent — spawn with agentId codex (adapter resolves; read-only argv). Advisory: fake codex.
rpc spawn "{\"prompt\":\"codex fork\",\"repo\":\"$REPO\",\"branch\":\"cx-1\",\"agentId\":\"codex\",\"seed\":\"X\"}" >/dev/null \
  && uc_ok "UC8 cross-agent spawn (codex adapter)" || uc_warn "UC8 cross-agent"

# trustState — the SpawnSheet's trust query, over the isolated daemon.
rpc trustState "{\"path\":\"$ROOT/repo\"}" | grep -q '"trusted"' && uc_ok "trustState query" || uc_warn "trustState"
```

Adjust `agentId` for `spawn` — the `spawn` Command takes no `agentId` param today; confirm whether the registry/`SpawnInput.agentId` is wired to the command. If `spawn` ignores `agentId`, drop UC8's agentId from the RPC (spawn defaults to Claude) and mark UC8 advisory-only. (Do NOT add an `agentId` param to `spawn` here — out of D3 scope; note it.)

- [ ] **Step 4: Run the e2e** — `scripts/orch-ux-e2e.sh --run-id d3ui` from an UNSANDBOXED shell. Expect: build → isolated daemon → app connect → UC ✓/⚠ lines → the screenshot step may fail with `could not create image from window` (EXPECTED headless outcome, advisory per O6). A non-screenshot failure (daemon didn't start, app didn't connect, UC RPC error) IS a real problem — fix it.

- [ ] **Step 5: Commit**

```bash
git add scripts/fixtures/fake-agent scripts/orch-ux-e2e.sh
git commit -m "test(d3): UX-e2e UC1–UC8 RPC drivers + fake-agent fixture (--run-id d3ui)"
```

---

## Task 7: Green gate + planning-doc record

- [ ] **Step 1: Full unit suite** — `./scripts/test.sh` → green (ignore the `SessionStart callback in 2s` flake if it's the ONLY failure; re-confirm via `--filter` in isolation).
- [ ] **Step 2: App typecheck** — `./scripts/typecheck-app.sh` → clean.
- [ ] **Step 3: UX-e2e** — `scripts/orch-ux-e2e.sh --run-id d3ui` runs; screenshot failure is the expected advisory outcome, not a gate.
- [ ] **Step 4: Record as-built** (planning hygiene, secondary — docs/ auto-syncs on merge): add a one-line D3 as-built note to `notes/designs/agent-provider-interface/03-implementation.md` (D3 row) and `04-tests.md` (App UX e2e row) — real symbol names (`SpawnInput.seed`, `trustState`, the four `BoardModel` actions, `scripts/fixtures/fake-agent`).
- [ ] **Step 5: Commit + move to `review`**

```bash
git add notes/
git commit -m "docs(d3): record as-built (seed/trustState/UI actions/UX-e2e)"
```

Then move the card to `review` and report `DONE: deleg/03-ui-actions — tests green` + a one-liner. **Do NOT merge/archive** — the orchestrator merges.

---

## Self-Review

**Spec coverage (D3 "plan must cover"):**
- *Which goals are card vs board actions* → Card actions: **Handoff** (F1 same-card, existing `handoff`), **Fork** (new card, `spawn --seed`), **Send** (F3, existing `send`) — all act on the selected card (InspectorView). Board action: **Fan-out** (`batch-spawn`, Toolbar, no selected card). ✓ (Task 4/5)
- *Fan-out kickoff UX* → Toolbar "Fan-out" → sheet with repo + base branch + one-prompt-per-line → `batch-spawn` with per-line `<branch>-<n>`. ✓ (Task 5 Step 2)
- *Trust-dialog wiring (reads T1 state)* → `trustState` read-only command → `TrustLedger.isTrusted`; SpawnSheet freeform shows Trusted ✓ / untrusted-forces-read-only + cancel. ✓ (Task 3/5)
- *App+daemon UX-e2e isolation contract* → isolated `$HOME`+`ORCHESTRA_TMUX_SOCKET`, direct `orchestrad` spawn, fake-agent on PATH, `USE_REAL_CLAUDE` unset, screenshot-by-PID, UC1–UC8 RPC drivers, `--run-id d3ui`. ✓ (Task 6)
- *New-Command discipline* → only `trustState` is new → `expected` array + `CLIRunner` case updated; parity auto-derives. ✓ (Task 3)

**Placeholder scan:** every code step shows real Swift/bash. The two soft spots — (a) exact `TestEnv`/`env.trust`/`env.sessions` accessor names, and (b) whether `spawn` accepts `agentId` — are called out with a concrete "mirror `HandoffResumeTests`" / "drop UC8 agentId if unwired" fallback rather than left as TODO.

**Type consistency:** `seed: String?` (Model/SpawnInput/spawn/Commands/CLIRunner/BoardModel.fork all use the same key `"seed"`). `trustState` returns `{"trusted": bool}` consistently (command, CLI, BoardModel, e2e grep). `BoardModel.fork(from:prompt:branch:context:)` and `fanout(prompts:repo:branch:)` signatures match their InspectorView/ToolbarView call sites.

**Risk notes:** No adapter-launch change → Claude byte-identical suites stay green. `trustState` is side-effect-free (uses `isPathTrusted`, not `resolveTrust`) → no ledger pollution. `trustState` vs T2's `trust` are different names → the D3/T2 merge overlap is confined to `CommandRegistry.build()` + `CLIRunner` + `CommandsTests.expected` (orchestrator serializes per O4; rebase resolves).
