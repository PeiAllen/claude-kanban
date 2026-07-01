# D1 · MCP/CLI Delegation Tools — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `handoff` delegation Command to the `CommandRegistry` (auto-surfaced in MCP, hand-wired
into the CLI switch), backed by the already-shipped `OrchestraService.resumeInCard(seed:)` (C3).

**Architecture:** `CommandRegistry.build()` single-sources the **MCP** tool list; the **CLI is a
hand-written `CLIRunner` switch** over the same command names (NOT auto-derived). So one new agent tool =
one new `Command` (auto in MCP) **+ one `CLIRunner` case** + its `CLIHelp` line. The `handoff` Command
resolves a card ref and delegates to `resumeInCard(id, seed:)` — F1 clean-context resume-in-place: kill +
`--resume` the same session id, seeded with the handoff context folded together with the card's pending
inbox (all of that logic already lives in C3's `resumeInCard`/`HandoffSeed.fold`).

**Tech Stack:** Swift, swift-testing (`@Suite`/`@Test`/`#expect`/`#require`), `scripts/test.sh` (needs an
**unsandboxed** shell — `swift build`/`test` trip `sandbox-exec`), `scripts/typecheck-app.sh` (self-pins
CLT), `scripts/orch-ux-e2e.sh` (advisory GUI e2e, O6).

## Global Constraints

- **`wait` is ALREADY shipped by C2** — do NOT re-add it. D1 adds **only** `handoff`.
- **CRITICAL (learned from C2):** every `Command` added to `CommandRegistry.build()` MUST ALSO be added to
  the `expected` array in `Tests/OrchestraCoreTests/CommandsTests.swift::fullSet` ("registry exposes the
  full command set") — else `main` goes red.
- **MCP parity is auto** — `orchestra-mcp/main.swift` maps `registry.commands`, and `E2EBinaryTests`
  asserts `tools/list == CommandRegistry().names`. Adding a `Command` keeps parity green with **no** test
  edit; the CLI switch is the only manual surface.
- **No new spawn args needed.** "stacked-spawn args for delegation" (the D1 forest-row note) are already
  satisfied by the existing `spawn` params (`repo`/`branch` for stacked-PR next-in-stack, `agentId` for
  cross-agent). D1 does NOT touch `SpawnInput`/`spawn`. Seeded-spawn for handoff→**new**-card / fork /
  fan-out (UC4/5/6) is a start-action wired by **D3** (board/CLI actions), not D1. The `handoff` Command
  is the F1 **same-card** resume-with-seed the contract binds to it (`02-contract.md` §4:
  "`resumeInCard` … Backs D1's `handoff` Command").
- Tests never spawn a real vendor agent (`USE_REAL_CLAUDE` stays unset); resumable cards are simulated with
  `spawn → markDead(.agentExited) → adapter.writeTranscript` (the C3 `makeResumable` pattern).
- Do throwaway work only in `./.scratch/`.

---

## File Structure

| File | Change | Responsibility |
|------|--------|----------------|
| `Sources/OrchestraCore/Commands.swift` | Modify — add one `Command` to `build()` | the `handoff` tool schema + handler → `resumeInCard` |
| `Sources/orchestra/CLIRunner.swift` | Modify — add one `case "handoff"` | CLI surface (switch is not auto-derived) |
| `Sources/orchestra/CLIHelp.swift` | Modify — add one usage line | `orchestra --help` lists `handoff` |
| `Tests/OrchestraCoreTests/CommandsTests.swift` | Modify — add `"handoff"` to `expected` | keep the full-command-set test green (schema-present) |
| `Tests/OrchestraCoreTests/HandoffResumeTests.swift` | Modify — add a `D1 · handoff Command` suite | round-trip: handoff Command dispatches to `resumeInCard`, carries seed, keeps id |
| `Tests/IntegrationTests/E2EBinaryTests.swift` | Modify — add a CLI-surface smoke | prove `orchestra handoff` **routes** (not "unknown command"); MCP parity already covers the tool list |

---

## Task 1: The `handoff` Command (schema + full-set test)

**Files:**
- Modify: `Sources/OrchestraCore/Commands.swift` (add a `Command` inside `build()`'s array, next to `wait`)
- Test: `Tests/OrchestraCoreTests/CommandsTests.swift:11` (the `expected` array in `fullSet`)

**Interfaces:**
- Consumes: `OrchestraService.resumeInCard(_ id: UUID, seed: String? = nil, graceSeconds: Int? = nil, source: ActivitySource = .daemon) async throws -> Task` (C3, `+Recovery.swift`); `svc.resolveRef(_:) async throws -> Task`; `CommandRegistry.strProp`/`refProp`/`schema`.
- Produces: a registered `Command(name: "handoff", …)`; the encoded updated `Task` as the tool result.

- [ ] **Step 1: Write the failing test — `handoff` is in the full command set**

In `Tests/OrchestraCoreTests/CommandsTests.swift`, extend the `expected` array in `fullSet()`:

```swift
        let expected = ["list", "spawn", "move", "send", "status", "archive",
                        "restart", "resume", "shell", "inspect", "closeShell", "exec", "sessions", "batch-spawn",
                        "wait", "handoff"]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/test.sh --filter CommandsTests/fullSet`
Expected: FAIL — `Set(reg.names) == Set(expected)` is false ("handoff" missing from the registry).

- [ ] **Step 3: Implement the `handoff` Command**

In `Sources/OrchestraCore/Commands.swift`, add this `Command` to the array returned by `build()`, placed
immediately after the `wait` command (before `status`):

```swift
            Command(name: "handoff",
                    summary: "Clean-context handoff (F1): kill + resume THIS card in a fresh process, "
                        + "same session id, seeded with `context` folded together with its pending inbox.",
                    params: schema([
                        "ref": refProp(),
                        "context": strProp("Handoff context — the summary/instructions the resumed, "
                            + "clean-context session opens on (folded ahead of any queued inbox messages)."),
                    ], required: ["ref", "context"])) { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let updated = try await svc.resumeInCard(t.id, seed: try p.string("context"), source: src)
                return try JSONValue(encodable: updated)
            },
```

- [ ] **Step 4: Run the full-set test to verify it passes**

Run: `./scripts/test.sh --filter CommandsTests/fullSet`
Expected: PASS — the registry now exposes `handoff`, and the per-command loop confirms its params are an
object schema with `properties` (schema-present requirement).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Commands.swift Tests/OrchestraCoreTests/CommandsTests.swift
git commit -m "feat(d1): add handoff Command (F1 resume-with-seed) to CommandRegistry"
```

---

## Task 2: `handoff` Command round-trips to `resumeInCard`

**Files:**
- Test: `Tests/OrchestraCoreTests/HandoffResumeTests.swift` (append a new `@Suite`)

**Interfaces:**
- Consumes: `CommandRegistry().command("handoff")`; `TestEnv.make(grace:)` → `(svc, sessions, worktrees, adapter, trust, base)`; `TestEnv.repo(base)`; `env.adapter.writeTranscript(for:)`; `env.svc.markDead(_:reason:.agentExited,detail:source:)`; `env.svc.report(_:StatusReport(sessionSource:"resume"))`; `env.sessions.ensureArgv[…]`.
- Produces: proof the Command reaches `resumeInCard` (seed carried in the resume argv, session id kept).

This mirrors `ResumeInCardTests` (same file): a resumable card is `spawn → markDead(.agentExited) →
writeTranscript`; the Command is invoked async, then a `report(sessionSource:"resume")` satisfies the
`awaitResume` grace so `resume` returns.

- [ ] **Step 1: Write the failing test**

Append to `Tests/OrchestraCoreTests/HandoffResumeTests.swift`:

```swift
@Suite("D1 · handoff Command — dispatches to resumeInCard")
struct HandoffCommandTests {

    /// Spawn a dead-but-resumable card with a transcript on disk (mirrors ResumeInCardTests).
    private func makeResumable(
        _ env: (svc: OrchestraService, sessions: StubSessions, worktrees: StubWorktrees, adapter: StubAdapter, trust: TrustLedger, base: String),
        branch: String) async throws -> Task {
        let repo = TestEnv.repo(env.base)
        let t = try await env.svc.spawn(SpawnInput(prompt: "x", repo: repo, branch: branch))
        await env.svc.markDead(t.id, reason: .agentExited, detail: nil, source: .daemon)
        env.adapter.writeTranscript(for: t.agentSessionId!)
        return t
    }

    @Test("handoff Command resumes the card with the context seed and keeps the session id")
    func dispatchesToResumeInCard() async throws {
        let env = TestEnv.make(grace: 2)
        let t = try await makeResumable(env, branch: "b")
        let oldId = t.agentSessionId
        let cmd = try #require(CommandRegistry().command("handoff"))

        async let done = cmd.run(
            env.svc,
            .object(["ref": .string(t.id.uuidString), "context": .string("HANDOFF-CTX")]),
            .agent)
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        try await env.svc.report(t.id, StatusReport(sessionSource: "resume"))
        let result = try await done

        // returns the updated Task (same id — resume, not a blank restart)
        #expect(try result.decode(Task.self).agentSessionId == oldId)
        // the resume argv carried the handoff context as its opening turn
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        #expect(argv.contains("--resume"))
        #expect(argv.last == "HANDOFF-CTX")
    }
}
```

- [ ] **Step 2: Run it to verify it passes** (implementation already landed in Task 1)

Run: `./scripts/test.sh --filter HandoffCommandTests`
Expected: PASS. (If it fails with a grace/`no SessionStart callback` timeout under parallel load — the
known flake — re-run this `--filter` in isolation to confirm green.)

- [ ] **Step 3: Commit**

```bash
git add Tests/OrchestraCoreTests/HandoffResumeTests.swift
git commit -m "test(d1): handoff Command round-trips to resumeInCard (seed + id kept)"
```

---

## Task 3: CLI `handoff` verb (surface) + help line

**Files:**
- Modify: `Sources/orchestra/CLIRunner.swift` (add `case "handoff"` to the `switch verb`)
- Modify: `Sources/orchestra/CLIHelp.swift` (add a usage line)
- Test: `Tests/IntegrationTests/E2EBinaryTests.swift` (add a CLI-surface smoke)

**Interfaces:**
- Consumes: `Flags.positional(_:)`, `Flags.require(_:)`, `Flags.value(_:)`, `Flags.positionalsFrom(_:)`, `client.call("handoff", …)`, `printRef(_:)`, `die(_:)`.
- Produces: the `orchestra handoff <ref> <context…>` verb; it must **route** (not fall through to
  `default: die("unknown command…")`).

- [ ] **Step 1: Write the failing CLI-surface test**

In `Tests/IntegrationTests/E2EBinaryTests.swift`, add this test to the `E2EBinaryTests` class (a cheap,
deterministic check that the verb is wired — a bare `orchestra handoff` fails on the missing ref, NOT on
"unknown command"):

```swift
    @Test("CLI: handoff is a routed verb (not an unknown command)")
    func cliHandoffRouted() throws {
        // No ref/context → the handoff case runs and dies on the missing ref; it must NOT reach the
        // `default:` unknown-command branch. Proves the CLI switch surfaces the new verb.
        let r = try cli(["handoff"])
        #expect(r.exitCode != 0)
        #expect(!r.stdout.contains("unknown command"))
        #expect(!r.stderr.contains("unknown command"))
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/test.sh --filter E2EBinaryTests/cliHandoffRouted`
Expected: FAIL — with no `case "handoff"`, the CLI hits `default: die("unknown command: handoff…")`, so
stderr contains "unknown command".

- [ ] **Step 3: Implement the CLI case**

In `Sources/orchestra/CLIRunner.swift`, add this case to the `switch verb` (place it right after the
`case "send":` block, mirroring `send <ref> <message…>`):

```swift
            case "handoff":
                // Clean-context handoff of THIS card: resume in place, seeded with the given context.
                // `orchestra handoff <ref> <context...>` (context may also be `--context <text>`).
                let ref = flags.positional(0) ?? flags.require("ref")
                let context = flags.value("context") ?? flags.positionalsFrom(1).joined(separator: " ")
                guard !context.isEmpty else { die("handoff needs context text: orchestra handoff <ref> <context...>") }
                let task = try await client.call("handoff", .object(["ref": .string(ref), "context": .string(context)]))
                printRef(task)
```

- [ ] **Step 4: Add the help line**

In `Sources/orchestra/CLIHelp.swift`, add after the `send` line (line 15):

```swift
      handoff <ref> <context...>                 Clean-context handoff: resume the card seeded with context
```

- [ ] **Step 5: Run the CLI-surface test to verify it passes**

Run: `./scripts/test.sh --filter E2EBinaryTests/cliHandoffRouted`
Expected: PASS — `orchestra handoff` now routes into the `handoff` case and dies on the missing ref
(exit ≠ 0, no "unknown command").

- [ ] **Step 6: Commit**

```bash
git add Sources/orchestra/CLIRunner.swift Sources/orchestra/CLIHelp.swift Tests/IntegrationTests/E2EBinaryTests.swift
git commit -m "feat(d1): orchestra handoff CLI verb + help; CLI-surface smoke"
```

---

## Task 4: Full green gate + advisory e2e

**Files:** none (verification only)

- [ ] **Step 1: Full unit + integration suite (unsandboxed)**

Run: `./scripts/test.sh`
Expected: PASS. Watch for the KNOWN FLAKE `no SessionStart callback in 2s` in `RecoveryTests` /
`HandoffResumeTests` under parallel load — if those are the ONLY failures, re-run the affected
`--filter` in isolation; treat green-in-isolation as green.

- [ ] **Step 2: App typecheck**

Run: `./scripts/typecheck-app.sh`
Expected: PASS (self-pins CLT via `scripts/toolchain.sh`; no `DEVELOPER_DIR`).

- [ ] **Step 3: Advisory UX e2e (O6 — not a merge gate)**

Run: `./scripts/orch-ux-e2e.sh --run-id d1tools`
Expected: best-effort. The screenshot step may fail on a headless/locked window server — that is
environmental (O6), not a defect. The unit tests + typecheck are the gate.

- [ ] **Step 4: Confirm registry↔MCP parity green** (already covered, no edit)

Run: `./scripts/test.sh --filter E2EBinaryTests`
Expected: `mcpSmoke` PASS — `tools/list` names == `CommandRegistry().names` (now including `handoff`),
proving the tool auto-surfaced in MCP.

---

## Self-Review

- **Spec coverage** (D1 forest row "Plan must cover"): tool schema → Task 1; add a `CLIRunner` verb case
  (CLI not auto-derived) → Task 3; preserve registry↔MCP parity test → Task 4 Step 4 (auto, no edit).
  `04-tests` `wait`/`handoff` row: schema present → Task 1 Step 4; round-trip → Task 2; surface in MCP →
  Task 4 Step 4; surface in CLI → Task 3; parity green → Task 4. CRITICAL C2 lesson (add to
  `CommandsTests.expected`) → Task 1 Step 1. `wait` NOT re-added → Global Constraints.
- **Placeholder scan:** every code step shows complete code; no TBD/TODO.
- **Type consistency:** `resumeInCard(_:seed:graceSeconds:source:)`, `resolveRef`, `strProp`/`refProp`/
  `schema`, `printRef`, `flags.positional/require/value/positionalsFrom`, `client.call` — all match the
  real signatures read from source. Command handler signature
  `(OrchestraService, JSONValue, ActivitySource) async throws -> JSONValue` matches `Command.run`.
