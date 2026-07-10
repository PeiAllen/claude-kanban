# Codex Hook-Trust & Stale-Install Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two empirically-confirmed Codex defects so a fresh Codex card's Stop hook actually fires and drains a queued `send` (Layer A of the codex-wake-delivery busy path).

**Architecture:** Two independent, adapter-local edits. (1) Broaden `CodexHooks`'s "is this ours?" predicate so a stale Orchestra hooks.json (retired `--event orient`) is replaced by the current 3-hook file, while a genuinely foreign hooks.json is still never clobbered. (2) Establish Codex hook-trust at launch by adding `--dangerously-bypass-hook-trust` to the Codex `start`/`resume` argv, **gated on a `<binary> --help` build-probe** so a stock `codex-rs` build (which lacks both the trust gate and the flag) still launches. Both changes live entirely inside the Codex adapter surface — Claude's argv and all shared code are untouched.

**Tech Stack:** Swift, swift-testing (`@Test`/`@Suite`), `Proc.run` subprocess helper.

## Global Constraints

- **Agent-agnostic:** no `if agentId ==` in shared code. All Defect-2 logic lives in `CodexAdapter`; Claude's argv MUST be byte-identical to before.
- **`swift test --no-parallel` green after every task** (the authoritative gate; parallel runs hit a known PTY-exhaustion flake — re-run in isolation).
- **Strict TDD:** write the failing test, watch it fail, implement minimally, watch it pass, commit.
- **Never clobber a foreign hooks.json** — the safety guarantee Defect-1 must preserve.
- **Degrade gracefully on builds lacking the flag** — an unknown flag breaks Codex launch (`exit 2, "unexpected argument"`, empirically confirmed), so the flag is conditional on a build-probe.

## Empirical grounding (verified against `codex-cli 0.142.5`, the real installed binary)

- `--dangerously-bypass-hook-trust` is a **global** flag AND is accepted **after the `resume` subcommand** (both `codex --help` and `codex resume --help` list it).
- It is the **only** mechanism that runs untrusted hooks: with the flag a fresh untrusted `SessionStart` hook fired (marker written) even through a 401; **without** it the marker was absent; `-c bypass_hook_trust=true` did **not** run the hook (the config override is inert in this path); the persisted trust is **hash-keyed** (`hashTrustHooks`/`HashChanged` in the binary), so a config-seed would require fragile hash reverse-engineering. → **Use the flag; reject config-seed and `-c` override.**
- An unknown flag → `exit 2` ("unexpected argument") → **build-probe is mandatory** for graceful degradation.
- The current `CodexHooks.sentinel` is `"_report --event session"`; a retired install wired `_report --event orient` (contains `_report --event` but NOT `...session`); a foreign file contains no `_report --event`. → broaden the marker to `"_report --event"`.

---

## Task 1: Defect 1 — replace a stale Orchestra hooks.json (broaden the "ours" marker)

**Files:**
- Modify: `Sources/OrchestraCore/Agents/CodexHooks.swift:14-25` (marker constant + doc + predicate)
- Test: `Tests/OrchestraCoreTests/SessionBriefTests.swift` (existing `@Suite("Codex SessionStart hook install (CodexHooks)")`, ~line 68)

**Interfaces:**
- Consumes: `CodexHooks.installIfSafe(content:to:) -> Bool`, `CodexHooks.sentinel: String` (both already public).
- Produces: `CodexHooks.sentinel == "_report --event"` (the general Orchestra marker); `installIfSafe` returns `true` for absent / any-Orchestra-authored file (session, stop, retired orient), `false` only for a file containing no `_report --event`.

- [ ] **Step 1: Write the failing test — a retired `--event orient` file IS overwritten**

Add to the `CodexHooksTests` suite in `Tests/OrchestraCoreTests/SessionBriefTests.swift`:

```swift
@Test("a stale Orchestra file wired to the retired --event orient hook IS overwritten")
func overwritesRetiredOrient() throws {
    let dest = tmp() + "/hooks.json"
    let stale = #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/bin/orchestra _report --event orient --agent codex"}]}]}}"#
    try FileManager.default.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try stale.write(toFile: dest, atomically: true, encoding: .utf8)
    #expect(CodexHooks.installIfSafe(content: rendered, to: dest) == true)   // recognized as ours → replaced
    let got = try String(contentsOfFile: dest, encoding: .utf8)
    #expect(got.contains("_report --event session"))   // now the current file
    #expect(!got.contains("--event orient"))            // stale hook gone
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --no-parallel --filter overwritesRetiredOrient`
Expected: FAIL — current code sees no `"_report --event session"` in the orient file → returns `false`, so `#expect(... == true)` fails.

- [ ] **Step 3: Broaden the marker in `CodexHooks.swift`**

Replace the constant + doc comment (lines 14-16):

```swift
    /// Marker identifying an Orchestra-rendered hooks file: the `_report --event` command no other tool
    /// emits. Matches ANY Orchestra event — `session`, `stop`, the retired `orient`, and any future one —
    /// so a stale pre-change install (e.g. the retired `--event orient`) is recognized as OURS and
    /// replaced, while a genuinely foreign hooks.json (no `_report --event` at all) is left untouched.
    public static let sentinel = "_report --event"
```

(The predicate at lines 22-24 already keys on `existing.contains(sentinel)`; broadening the constant is the whole fix. No other line changes.)

- [ ] **Step 4: Run the new test + the existing suite to verify pass**

Run: `swift test --no-parallel --filter CodexHooksTests`
Expected: PASS — `overwritesRetiredOrient`, `writesWhenAbsent`, `idempotentForOurs`, `skipsForeign` (its `"my-own-script"` file has no `_report --event` → still `false`), `renderCodexSubstitutes` all green. Also confirms `SessionBriefTests` line 78 (`got.contains(CodexHooks.sentinel)`) still holds (rendered contains `_report --event`).

- [ ] **Step 5: Commit**

```bash
git add Sources/OrchestraCore/Agents/CodexHooks.swift Tests/OrchestraCoreTests/SessionBriefTests.swift
git commit -m "fix(codex): replace a stale Orchestra hooks.json (broaden the ours marker to _report --event)"
```

---

## Task 2: Defect 2 — establish hook trust at launch (build-probed `--dangerously-bypass-hook-trust`)

**Files:**
- Modify: `Sources/OrchestraCore/Agents/CodexAdapter.swift` (init `:26-29`, add probe + flag helper, splice into `start` `:175-181` and `resume` `:183-193`)
- Test: `Tests/OrchestraCoreTests/CodexAdapterTests.swift` (`CodexAdapterArgvTests` suite)

**Interfaces:**
- Consumes: `Proc.run(_ argv:cwd:env:timeout:) throws -> ProcResult` (resolves argv[0] on PATH via `/usr/bin/env`). Note: it does NOT throw on timeout (it SIGTERMs the child and returns a non-zero `exitCode`), and an absent sub-binary under `/usr/bin/env` exits 127 without throwing — so the probe keys on `exitCode == 0`, not on a thrown error.
- Produces:
  - `CodexAdapter.init(binOverride:codexHome:hookTrustBypass:)` — new optional `hookTrustBypass: Bool? = nil` (test injection; `nil` = probe the real binary once, cached).
  - `start(ctx)` / `resume(ctx)` argv include `--dangerously-bypass-hook-trust` **iff** the build supports it; the flag sits right after `binary` (start) / after `[binary, "resume", sid]` (resume), so the trailing positional prompt/seed invariant is preserved.

- [ ] **Step 1: Write the failing tests — flag present when supported, absent when not, and Claude unaffected**

Add to `CodexAdapterArgvTests` in `Tests/OrchestraCoreTests/CodexAdapterTests.swift`:

```swift
// Defect 2 · hook-trust. This customized Codex build trust-gates hooks behind a launch modal Orchestra
// can't answer; the flag establishes trust by construction (Orchestra authors the hooks). Gated on a
// build-probe so a stock codex-rs build (no gate, no flag) still launches. `hookTrustBypass:` injects
// the probe result for hermetic tests.
@Test("start/resume carry --dangerously-bypass-hook-trust when the build supports it")
func hookTrustBypassPresentWhenSupported() throws {
    let a = CodexAdapter(binOverride: "codex", hookTrustBypass: true)
    let start = a.start(AdapterContext(cwd: "/wt", model: "gpt-5.5", prompt: "go"))
    #expect(start.contains("--dangerously-bypass-hook-trust"))
    #expect(start.last == "go")                            // positional prompt still last
    let resume = try #require(a.resume(AdapterContext(cwd: "/wt", sessionId: "sess-9", seed: "drain")))
    #expect(resume.contains("--dangerously-bypass-hook-trust"))
    #expect(adjacent(resume, "resume", "sess-9"))          // flag must NOT split `resume <sid>` (review #2)
    #expect(resume.last == "drain")                        // folded seed still last
}

@Test("start/resume OMIT the flag on a build that lacks it (graceful degradation)")
func hookTrustBypassAbsentWhenUnsupported() throws {
    let a = CodexAdapter(binOverride: "codex", hookTrustBypass: false)
    #expect(!a.start(AdapterContext(cwd: "/wt", prompt: "go")).contains("--dangerously-bypass-hook-trust"))
    let resume = try #require(a.resume(AdapterContext(cwd: "/wt", sessionId: "sess-9")))
    #expect(!resume.contains("--dangerously-bypass-hook-trust"))
}

@Test("the hook-trust flag is Codex-local: Claude's argv never carries it")
func claudeUnaffectedByHookTrust() {
    let claude = ClaudeCodeAdapter()
    #expect(!claude.start(AdapterContext(cwd: "/wt", prompt: "go")).contains("--dangerously-bypass-hook-trust"))
    let r = claude.resume(AdapterContext(cwd: "/wt", sessionId: "abc")) ?? []
    #expect(!r.contains("--dangerously-bypass-hook-trust"))
}
```

> **Note on `seed:`** — confirm `AdapterContext` has a `seed` parameter (used at `CodexAdapter.swift:191`). If its initializer label differs, match the real signature (grep `struct AdapterContext`).

- [ ] **Step 2: Run to verify failure**

Run: `swift test --no-parallel --filter hookTrustBypass`
Expected: FAIL — `CodexAdapter.init` has no `hookTrustBypass:` label (compile error), and neither `start` nor `resume` emits the flag.

- [ ] **Step 3: Add the injectable probe + flag helper, splice into argv**

In `CodexAdapter.swift`, extend the stored config + init (`:23-29`):

```swift
    /// Test injection (fake binary / isolated home) — never spawns real Codex.
    let binOverride: String?
    let codexHomeOverride: String?
    /// Test injection for the hook-trust build-probe. `nil` ⇒ probe the real binary once (cached);
    /// `true`/`false` ⇒ force the result (hermetic tests, no subprocess).
    let hookTrustBypassOverride: Bool?

    public init(binOverride: String? = nil, codexHome: String? = nil, hookTrustBypass: Bool? = nil) {
        self.binOverride = binOverride
        self.codexHomeOverride = codexHome
        self.hookTrustBypassOverride = hookTrustBypass
    }
```

Add the probe + flag helper (place near `accessFlags`, `:166`):

```swift
    // Defect 2 · Codex hook-trust. This customized Codex build TRUST-GATES hooks behind a launch-time
    // modal ("Hooks need review") Orchestra can't answer — so without intervention the Stop hook never
    // runs and the durable inbox never drains. `--dangerously-bypass-hook-trust` establishes trust by
    // construction: Orchestra AUTHORS the hooks (it owns CODEX_HOME + writes hooks.json), so trusting
    // them is correct. Empirically it is the ONLY mechanism that runs untrusted hooks (the `-c
    // bypass_hook_trust` override is inert; persisted trust is hash-keyed → a config-seed is fragile).
    // It is DANGEROUS only re: hook trust — it does NOT touch approvals/sandbox.
    private var hookTrustFlags: [String] {
        bypassHookTrustSupported ? ["--dangerously-bypass-hook-trust"] : []
    }

    /// Does the installed Codex build accept `--dangerously-bypass-hook-trust`? An unknown flag would
    /// abort launch (`exit 2, unexpected argument`), so this is build-gated. The flag's presence exactly
    /// tracks the trust gate's presence: this customized build has BOTH; a stock codex-rs build has
    /// NEITHER — so probing the flag is the correct capability gate. Probed per binary via `--help`; a
    /// DEFINITIVE result (help completed, `exit 0`) is cached, anything else degrades to no flag for THIS
    /// launch WITHOUT caching (see below). Never blocks launch; never spawns for fake-bin tests (they
    /// inject `hookTrustBypass:`; an absent bin fails the probe → no flag).
    private var bypassHookTrustSupported: Bool {
        if let forced = hookTrustBypassOverride { return forced }
        return Self.probeBypassHookTrust(binary)
    }

    private static let probeLock = NSLock()
    private static var probeCache: [String: Bool] = [:]
    /// Probe `<bin> --help` for the flag. CRITICAL (review #1): only cache a DEFINITIVE outcome — a
    /// `--help` that ran to completion (`exit 0`, whose output we can trust to fully list flags). A
    /// timeout (`Proc.run` returns a SIGTERM, non-zero exit — it does NOT throw) or a spawn failure is
    /// TRANSIENT (cold first-exec under load, AV scan): return `false` for this launch but DON'T cache
    /// it, so the next launch retries. Caching a transient `false` would silently disable the flag for
    /// the whole daemon session → the exact non-delivery bug this fixes. Double-checked locking (review
    /// #3): the subprocess runs OUTSIDE the lock so a concurrent launch isn't stalled up to 5s. Stale on
    /// an in-place codex upgrade until daemon restart (review #5) — acceptable; daemons restart on upgrade.
    private static func probeBypassHookTrust(_ bin: String) -> Bool {
        probeLock.lock()
        let cached = probeCache[bin]
        probeLock.unlock()
        if let cached { return cached }

        guard let r = try? Proc.run([bin, "--help"], timeout: .seconds(5)), r.exitCode == 0 else {
            return false   // transient/failed probe → no flag THIS launch, but NOT cached (retry next time)
        }
        let supported = (r.stdout + r.stderr).contains("--dangerously-bypass-hook-trust")
        probeLock.lock()
        probeCache[bin] = supported   // definitive → cache
        probeLock.unlock()
        return supported
    }
```

Splice into `start` (`:175-181`) — flag right after `binary`, before access/model/prompt:

```swift
    public func start(_ ctx: AdapterContext) -> [String] {
        var argv = [binary]
        argv += hookTrustFlags
        argv += accessFlags(ctx.access)
        argv += modelFlag(ctx.model)
        if let p = ctx.prompt, !p.isEmpty { argv.append(p) }   // launch positional prompt
        return argv
    }
```

Splice into `resume` (`:183-193`) — flag right after `[binary, "resume", sid]` (help confirms it's valid there):

```swift
    public func resume(_ ctx: AdapterContext) -> [String]? {
        guard let sid = ctx.sessionId else { return nil }
        var argv = [binary, "resume", sid]
        argv += hookTrustFlags
        argv += accessFlags(ctx.access)
        argv += modelFlag(ctx.model)
        if let seed = ctx.seed, !seed.isEmpty { argv.append(seed) }
        return argv
    }
```

- [ ] **Step 4: Run the new tests to verify pass**

Run: `swift test --no-parallel --filter "hookTrustBypass|claudeUnaffectedByHookTrust"`
Expected: PASS — flag present with `hookTrustBypass: true`, absent with `false`, absent for Claude.

- [ ] **Step 5: Run the full CodexAdapter suite to confirm no regressions**

Run: `swift test --no-parallel --filter CodexAdapter` then `swift test --no-parallel --filter HandoffResume`
Expected: PASS. Real-bin tests that use `CodexAdapter()` (no override) now spawn a live `codex --help`, so their outcome is coupled to the local codex build — verify, don't assume. Traced (all still pass because the flag sits early):
- `startArgv` (`argv.last == prompt`), `startNoPrompt` (`argv.last == -m value`), `resumeArgv` (adjacency of `resume`/`-m`, `!contains("should be ignored")`), `startAccessGated`/`resumeReadOnly` (adjacency of `-s`/`-a`).
- `HandoffResumeTests.codexCarriesSeed` (`Tests/OrchestraCoreTests/HandoffResumeTests.swift:75`, `argv.last == "SEED-CTX"`) and `codexNoSeed` (`:82`, `argv.last == "m"`) — flag inserts after `[codex, resume, sid]`, before `-m`, so the tail assertions hold.
- `CodexSpawnWiringTests` (`fake-codex`) probes a non-existent bin → `exitCode != 0` → `false` → no flag → `argv.first == "fake-codex"` + read-only assertions unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrchestraCore/Agents/CodexAdapter.swift Tests/OrchestraCoreTests/CodexAdapterTests.swift
git commit -m "fix(codex): establish hook trust at launch via build-probed --dangerously-bypass-hook-trust"
```

---

## Task 3: Full-suite gate + fold decisions into the design doc

**Files:**
- Modify: `notes/designs/codex-wake-delivery/01-design.md` ("Decisions made" table — record the Layer-A defects + the flag-over-config-seed decision).

- [ ] **Step 1: Run the authoritative full suite**

Run: `swift test --no-parallel 2>&1 | tail -30`
Expected: all tests pass. If a PTY-exhaustion flake appears under load, re-run the affected suite in isolation and paste both outputs (per superpowers:verification-before-completion).

- [ ] **Step 2: Fold the decisions into the design doc**

Append two rows to the "Decisions made" table in `notes/designs/codex-wake-delivery/01-design.md` (the referenced `live-wake-delivery/01-design.md` does not exist on this branch — this is the corresponding doc):

```markdown
| **Layer A — replace a stale Orchestra hooks.json** | An older install wired the retired `--event orient` (no `session` sentinel), so `installIfSafe` treated the current 3-hook file as foreign and never installed it → the Stop hook could not fire. Broaden the "ours" marker to `_report --event`. | keep the narrow `session` sentinel (strands old installs) |
| **Layer A — hook trust via build-probed `--dangerously-bypass-hook-trust`** | This customized Codex build trust-gates hooks behind a launch modal; the flag is the ONLY empirically-verified way to run untrusted hooks (config `-c bypass_hook_trust` inert; persisted trust hash-keyed → config-seed fragile). Build-probed so a stock codex-rs build (no gate/no flag) still launches. Adapter-local — Claude unaffected. | config.toml `[hooks.state]` hash seed (fragile); `-c bypass_hook_trust=true` (inert) |
```

- [ ] **Step 3: Commit**

```bash
git add notes/designs/codex-wake-delivery/01-design.md
git commit -m "docs(codex-wake-delivery): record Layer-A hook-trust + stale-install decisions"
```

---

## Optional end-to-end verification (if feasible — the true proof)

Per project memories `orchestra-isolated-testing` / `iso-stack`: spin up an **isolated real-Codex** daemon+card (own `HOME`/`CODEX_HOME`, real auth copied in), send a message to a fresh Codex card, and confirm the **Stop hook fires and the durable inbox drains** (block-continuation with the inbox framing appears in the session). This exercises the full launch → hooks-install → trust-bypass → Stop-drain path against the real binary, which unit tests cannot. Paste the evidence. If auth/isolation makes this impractical, note it and rely on the empirical probes above + the unit gate.

## Self-Review

- **Spec coverage:** Defect 1 → Task 1 (3 required test cases: retired-orient overwritten, foreign untouched via existing `skipsForeign`, idempotent-ours via existing `idempotentForOurs`). Defect 2 → Task 2 (flag present/absent for Codex; absent for Claude; build-aware). Full suite + doc fold → Task 3.
- **Placeholder scan:** none — every code/test block is complete.
- **Type consistency:** `CodexHooks.sentinel`, `installIfSafe`, `CodexAdapter.init(...:hookTrustBypass:)`, `hookTrustFlags`, `bypassHookTrustSupported`, `Proc.run`, `AdapterContext(seed:)` used consistently. Verify `AdapterContext`'s `seed` label against the source before writing Task 2's test.
```