---
project: claude-kanban
feature: agent-provider-interface
type: pre-implementation-review
created: 2026-07-01
reviewer: skeptical final pass (autonomous overnight implementation)
links: ["[[index]]", "[[01-design]]", "[[02-contract]]", "[[03-implementation]]", "[[04-tests]]", "[[agent-provider-interface]]"]
---

# Final Review — Agent-Provider Interface (autonomous overnight build)

> Skeptical pre-implementation review. The plan is **substantively strong**: the seam is grounded in
> real Swift symbols, the capability freeze is genuinely complete and consistent, the greenfield types
> are contract'd enough to build, and the DAG is acyclic with a correct critical path. The blockers
> below are **operational** (how an *unattended* forest is run), not design flaws — all three are cheaply
> fixable before the run starts.

## Verdict: **GO-WITH-FIXES** — one real blocker (M1)

**Updated after author review (2026-07-01).** Two of the original three "must-fix" items were downgraded
after checking the actual harness and merge model:
- **M2** (UX-e2e TCC/GUI): the harness drives the board **via daemon state/RPC**, uses **no synthetic
  input** (0 `cliclick`/`osascript`/`CGEvent`/`AXUIElement` calls), and screenshots via `screencapture`
  charged to the already-granted host process. **Screen Recording is already granted; Accessibility is
  never used.** Downgraded to a caveat (needs a logged-in GUI session; keep future UC drivers state-based).
- **M3** (parallel roots): the roots are **branches merged serially**, their edits sit in **different
  regions** of the shared files (git auto-merges), and each root compiles on `main` in isolation.
  Downgraded to a low-risk watch. The one genuine same-construct conflict (D1↔T2) is already handled by
  the `also-needs` ordering.

**The single remaining blocker is M1** (design vault not on `main`). Fix it and this is a clean **GO**.

---

## Must-fix before implementing (blocking)

### M1 — The design vault is **absent on `main`**; the forest bases on `main`
**Where:** git. `git cat-file -e main:notes/designs/agent-provider-interface/index.md` → **ABSENT**;
`main:notes/designs/agent-provider-interface.md` → **ABSENT**. The vault exists only on
`design/agent-provider-interface` (8 commits ahead of `main`), and the SSOT still has an **uncommitted**
edit (`git status`: `M notes/designs/agent-provider-interface.md`).

**Why it stalls:** every PR's `Base` is `main` (or a branch stacked off it). Each card cuts a worktree
off that base. The orchestrator plan is that each card "uses the superpowers skills to write a detailed
implementation + test plan **using these layers** + current code." A worktree cut from `main` **does not
contain these layer files** — the planning step is blind (or the agent burns the night hunting for docs
that aren't in its tree).

**Fix (before the forest runs):**
1. Commit the pending SSOT edit.
2. **Merge the design vault to `main`** (`docs/`-SSOT policy already treats merged `notes/designs/` as
   sync input, so this is consistent with the DoD). *Or* base the entire forest off
   `design/agent-provider-interface` instead of `main`. *Or* have the orchestrator inline each layer's
   contents into every card's seed. Merging to `main` is simplest and matches the auto-sync design.

### ~~M2 — UX-e2e can't be a merge gate~~ → DOWNGRADED to a caveat (author-verified)
**Where:** `scripts/orch-ux-e2e.sh`; [[04-tests]] §"App UX e2e (D3)".

**Original concern (Accessibility/Screen-Recording TCC prompt stalls the run) does not hold for the
current harness:**
- It **drives the board via daemon state / RPC** (`orch-rpc.py inspect`, an isolated seeded card) — grep
  for `cliclick|osascript|CGEvent|System Events|AXUIElement` = **0**. **No synthetic input → Accessibility
  is never exercised.**
- It screenshots via `screencapture -x -o -l<wid>` (line 163) — Apple's binary, TCC-charged to the
  already-granted **host** process, **by window id** (no foregrounding, no whole-screen).
- Per the author, Screen Recording + Accessibility are already granted and won't prompt.

**Residual caveat (not a blocker):** `screencapture` needs a **logged-in / unlocked GUI session** (a
locked or headless session has no window server to capture). And the D3 note that "UC-workflow drivers get
added onto this harness" should **keep driving via state/RPC, not synthetic input**, so no new
Accessibility dependency creeps in. Whether per-PR e2e **gates** the merge or is **advisory** is a
judgment call, not a correctness issue — advisory (gate on unit + `typecheck-app.sh`, run the full UC1–UC8
pass as a final acceptance) is still the lower-risk default for an unattended run.

### ~~M3 — Serialize the parallel roots~~ → DOWNGRADED to a low-risk watch (author-verified)
**Where:** [[03-implementation]] forest (A1, E1, T1 root off `main`).

**Original concern (unattended 3-way merge conflict) is unlikely** given how the forest actually runs:
- The roots are **separate branches merged serially** by the orchestrator (one PR at a time), not
  simultaneously — so there is no live 3-way merge; each merge is A-then-B-then-C.
- The edits sit in **different regions** of the shared files: A1 → `Adapter.swift` protocol/struct +
  `isResumable`; T1 → `trustCwd:` call-site args (`OrchestraService.swift:123`, `+Recovery.swift:64,115`)
  + new `TrustLedger.swift`; E1 → `models()` in `ClaudeCodeAdapter.swift`. Git **auto-merges** non-adjacent
  edits. Note `ClaudeCodeAdapter.prepareToLaunch` **already reads `ctx.trustCwd`** (lines 43–47), so T1
  barely touches that file.
- Each root **compiles on plain `main` in isolation** (T1 doesn't need A1's caps/`seed`; A1 doesn't need
  T1's ledger), so "builds green on its stated base" holds independently.

**Residual watch (cheap insurance, not a gate):** land **A1 first** anyway — it's the logical seam root
and makes any later textual overlap trivial to rebase. The one *genuine* same-construct conflict is
**D1 ↔ T2** (two `case`s added to the one `CLIRunner` `switch` + two `Command`s in `CommandRegistry.build`)
— and that is **already handled**: T2 `also-needs` D1, so T2 develops on top of D1's merged changes.

---

## Should-fix (non-blocking gaps)

- **S1 — SSOT §12 still lists q4 + q10 as "Still open"**, contradicting all four layers and the index
  ("all open questions resolved 2026-07-01"). Move both to Resolved: q4 → *soft-warn only, no cap*
  (matches E2); q10 → *send-keys + detect-and-defer for v1* (matches C4). `agent-provider-interface.md`
  lines **829–835**.
- **S2 — SSOT core-decisions D1–D5 and D12 still say "Recommend"** while D6–D11 are "Confirmed" and every
  layer treats the whole set as settled. Flip D1–D5/D12 to Confirmed (or annotate "flips as-built").
  `agent-provider-interface.md` lines **50–61**.
- **S3 — Descriptor name drift.** SSOT §4 names it **`AdapterCapabilities`** (`agent-provider-interface.md:159,165`);
  the layers + the A1 freeze name it **`AgentCapabilities`**. The L2 "name map" note doesn't cover this
  rename — add it so the implementer creates the right type.
- **S4 — SSOT `ControlEvent` shows deferred fields as if in-scope.** `agent-provider-interface.md:174-184,219-222`
  list `turnEnded{reason}`, `approvalRequested`, `approvalResolved` as ControlEvent fields; L2/L3 explicitly
  **defer** typed-turnEnded + approvals out of this forest. Annotate the SSOT diagram "approval / typed
  turnEnded deferred to a later PR" so A2 isn't over-built.
- **S5 — A1's "0 of 9 `AdapterContext(...)` call sites" is wrong.** Actual = **14** (6 in `Sources/`, 8 in
  `Tests/`: `ReadOnlyAdapterTests.swift`, `AdapterTests.swift`). The defaulted-`seed` argument still holds;
  fix the number. `03-implementation.md:84`.
- **S6 — `capabilities` cannot be protocol-defaulted meaningfully**, so A1 must implement it on **every**
  conformer (`ClaudeCodeAdapter` **and** `StubAdapter` in `Tests/OrchestraCoreTests/Stubs.swift:67`), not
  just add a protocol requirement. A1 already says "cap-parameterized StubAdapter" — make explicit that
  the freeze touches the test stub in the same PR or A1 won't compile.
- **S7 — Layer numbering.** The index Layers table labels the tests layer "**3 — Tests**" (should be 4);
  `04-tests.md` frontmatter says `layer: 3` and the H1 is "Layer 3 — Test Design." Cosmetic, but confusing.
- **S8 — D3 UC-replay needs a fake agent, unspecified.** `orch-ux-e2e.sh` excludes real `claude` from
  `PATH` (good — no billing), but replaying UC1–UC8 "through the real UI" needs *some* agent to take turns.
  The fake-agent path (`ClaudeCodeAdapter(binOverride:)`) is not wired into the harness. D3's plan must
  specify how UC turns actually execute (fake-agent fixture on PATH), or the UC replays are UI-only.

---

## Human-intervention risks (ranked)

| # | Risk | Where | Why it stalls an unattended run | Mitigation |
|---|------|-------|----------------------------------|------------|
| 1 | Plan docs not on `main` | git (M1) | Cards cut off `main` can't read their own layer docs → planning blind/stalls | Merge vault to `main` (commit the pending SSOT edit) before the forest, or base forest off the design branch, or seed layer contents into each card |
| 2 | UX-e2e needs a live GUI session | `orch-ux-e2e.sh` (M2, downgraded) | `screencapture` needs an unlocked GUI session; **TCC already granted, no synthetic input, no dialog** | Run on a logged-in/unlocked Mac; keep UC drivers state/RPC-based; advisory-gate is the safe default |
| 3 | A1/E1/T1 textual merge overlap | `Adapter.swift`, `ClaudeCodeAdapter.swift`, `OrchestraService.swift` (M3, downgraded) | Serial merges of non-overlapping edits → **git auto-merges**; low residual | Land A1 first as cheap insurance; each root already builds on `main` in isolation |
| 4 | Live **trust grant** fires mid-run | `resolveTrust` `borrowed` path → MCP `requestElicitation` | Elicitation is **human-only**; no human → deny/timeout → card clamps to sandboxed (or the untrusted spawn stalls) | **Guarantee every forest card is `worktree` origin off the already-trusted `claude-kanban` repo** → `resolveTrust` returns `trusted` (inherit), **no grant ever triggers**. Never autonomously spawn `borrowed`/foreign-repo cards. Tests use the **stub grant resolver** ([[04-tests]] fixtures: "stub human-grant resolver approve/deny/timeout") — confirmed, no live MCP client needed |
| 5 | D1 ↔ T2 co-edit `Commands.swift` + `CLIRunner.swift` | both add a case to the hand-written switch (`CLIRunner.swift` has 14 verb cases today) | Two PRs adding to the same `switch` conflict | Already mitigated: **T2 also-needs D1** → orchestrator merges D1 before spawning T2 (enforce "also-needs = merge-into-branch-before-spawn"); registry↔MCP parity test guards the surface |
| 6 | Real vendor binary spawn / billing | any launch; UX-e2e cards | Would log in / bill a real agent | `orch-ux-e2e.sh` excludes `~/.local/bin` from PATH (`USE_REAL_CLAUDE=1` opt-in); unit tests use `StubSessions` + `binOverride`. **Confirm no UC e2e sets `USE_REAL_CLAUDE`** |
| 7 | C1 ↔ A2 Stop-hook 3-way | `Control/HooksRenderer.swift:38` (`Stop` = `_report --event notify`) | Both edit the Stop hook | Mitigated: **C1 bases on A2** (linear), as [[03-implementation]] "Concerns" states |
| 8 | E1 ↔ A2 both edit `ClaudeCodeAdapter` (`models()` vs `parse`) | reconcile at B2 (base B1-off-A2, also-needs E1) | Two additive edits to the same adapter file | Likely auto-mergeable (different methods); state the rule "land A2 before E1, or B2 rebases E1 in" |

---

## Consistency + stale-citation findings

**Ground-truthed and CORRECT (the plan does not lie about the code):**
- `Config.home` at `Config.swift:50`; `socketPath`/`dataDir`/`hooksPath` derive from it (`:64-69`). ✓
- App `ControlClient` path at `BoardModel.swift:51` (`init(socketPath: Config.socketPath)`). ✓ — so the
  D3 isolation contract ("`$HOME` steers both sides") is real.
- `DaemonLifecycle` label `com.orchestra.daemon` is **fixed** (`DaemonLifecycle.swift:17`); the `plistPath`
  is HOME-namespaced but the **launchctl label is not**, so the collision-with-live claim holds and
  "spawn `orchestrad` directly, not launchctl" is correct. ✓ *(doc cites `:18`; label is `:17` — off by one.)*
- `ReportHelper.map` lives in the **`orchestra` CLI target** at `Sources/orchestra/ReportHelper.swift:38`.
  ✓ — A2's "relocate `ReportHelper.map` into the adapter (cross-target move)" is a **real, correctly
  identified** move, not just a signature change.
- `CardOrigin { worktree, scratch, borrowed }` `Model.swift:97`; `CardAccess { readWrite, readOnly }`
  `Model.swift:102`. ✓
- `AdapterContext.trustCwd` **already exists** (`Adapter.swift:14`), currently set from `origin == .scratch`
  (`OrchestraService.swift:123`, `+Recovery.swift:64,115`) — matches L2's "today just `origin == .scratch`". ✓
- The `resumeWaiters` / `awaitResume` / `resolveResume` `CheckedContinuation` pattern exists
  (`OrchestraService+Recovery.swift:177-192`, `OrchestraService.swift:20`) — so MergeWatch's "continuation
  keyed on the watch set, like `awaitResume`" is a real, reusable pattern. ✓
- Test harness is real: `StubAdapter`, `StubSessions.ensureArgv`, `EventCollector`, `TestEnv.make()` in
  `Tests/OrchestraCoreTests/Stubs.swift`. ✓
- Stop hook = `_report --event notify` (`HooksRenderer.swift:38`) — C1's "preserve the notify report" is
  grounded. ✓
- **Capability freeze is genuinely complete and consistent:** the 7-field enum with every variant spelling
  (incl. later-only `wakeTransport: controlChannel/relaunch`, `inboxDrain: sessionSeed`,
  `readOnlyEnforcement: orchestraSandboxed`, `telemetry: ptyScrape`, `contextUsage: none`) is **identical**
  between SSOT §4 (`agent-provider-interface.md:165-172`) and the L2 classDiagram (`02-contract.md:190-198`).
  The A1 "freeze the spellings" claim is real and enforceable. ✓
- `Adapter` protocol today has **no** `capabilities`/`parse`; `AdapterContext` has **no** `seed`. All three
  are correctly marked **NEW / added by A1–A2**. The `Adapter.swift:4` pointer for `seed` targets the
  struct declaration (a location pointer, not an existing field) — acceptable. ✓

**Stale / inaccurate:**
- `DaemonLifecycle.swift:**18**` → label is `:17` (S-level, off by one).
- A1 "**9** `AdapterContext(...)` call sites" → actually **14** (S5).
- SSOT §12 q4/q10 "Still open" contradicts the layers (S1).
- SSOT D1–D5/D12 "Recommend" vs layers-treat-settled (S2).
- Descriptor named `AdapterCapabilities` in SSOT vs `AgentCapabilities` in layers (S3).
- SSOT `ControlEvent` shows deferred approval/turnEnded fields un-annotated (S4).

**No diagram shows the *old* (pre-resolution) design** — the sequence/state/class/flow diagrams across
index, L1, L3 all reflect the resolved three-function F1/F2/F3 model, send-keys Codex wake, subscriber
MergeWatch, and the A1 seam-freeze. The only stale *text* is SSOT §12 (S1) and the D-row statuses (S2).

---

## DAG buildability

- **Valid DAG, no cycles.** Edges: A1←main; A2←A1; E1←main; E2←A1; T1←main; T2←T1(+D1); B1←A2(+T1);
  B2←B1(+E1); C1←A2; C2←C1; C3←C2; C4←C2(+B1); D1←C2(+C3); D2←D1; D3←D1(+T1). No back-edges; every
  also-needs points "earlier." ✓
- **Critical path** `A1 → A2 → C1 → C2 → C3 → D1 → {D2, D3}` is **correct** (longest chain; live-delivery
  spine). ✓
- **Builds green in isolation on stated base — with two provisos:** (a) apply **M3** (serialize A1, then
  rebase E1/T1) or the roots collide; (b) treat **also-needs as "merge into the branch before spawning"**
  (the forest legend says the orchestrator does this) so B1 has T1, B2 has E1, D1 has C3, D3 has T1, T2
  has D1 — otherwise those PRs don't compile/test in isolation.

---

## Per-PR readiness checklist

| PR | Ready? | Gap / note |
|----|--------|------------|
| **A1** | ✅ | Enum freeze complete & consistent (SSOT§4 = L2). Fix "9→14" call sites (S5); make explicit that `capabilities` has no protocol default so **`StubAdapter` must gain it in A1** (S6). Land **first** (M3). |
| **A2** | ✅ | Cross-target `ReportHelper.map` move correctly identified; `ReportTests` byte-identical gate. Land **before E1** to ease B2 (risk 8). |
| **E1** | ✅ | Offline table + unknown-model fallback + vendored JSON well-specified. Rebase onto post-A1 main (M3). |
| **B1** | ✅ | Base A2, also-needs T1 (merge T1 first). `trust_level` from `ctx.trustCwd`, RO-first, session discovery all specified. |
| **B2** | ✅ | Base B1, also-needs E1. Rollout tail + rename tolerance + seq-gate specified. E1↔A2 reconcile lands here (risk 8). |
| **C1** | ✅ | Base A2 (avoids Stop-hook 3-way, risk 7). Inbox durability/order/cap + preserve-`notify` all covered. |
| **C2** | ✅ | Subscriber MergeWatch + continuation pattern grounded in real `awaitResume`. 0-commit regression test named. |
| **C3** | ✅ | `seed` frozen in A1 → C3 only reads `ctx.seed`, `resume` sig unchanged. Clean. |
| **C4** | ✅ | Base C2, also-needs B1. Send-keys + detect-and-defer, nudge-only, composer detection specified. |
| **D1** | ✅ | `wait`/`handoff` Command + **CLIRunner case** + parity tripwire. Co-edits with T2 (risk 5) — D1 lands first. |
| **D2** | ✅ | Skill + AGENTS.md; prose-heavy, low risk. |
| **D3** | ⚠️ | Isolation contract fully grounded & matches `orch-ux-e2e.sh`. **But** e2e-as-gate TCC/GUI risk (M2) + unspecified fake-agent for UC replay (S8). Ready to build the UI actions; keep e2e advisory. |
| **E2** | ✅ | Soft-warn only, **no cap** (q4 resolved); per-adapter rate state. Clean. |
| **T1** | ✅ | Ledger schema + origin→decision table + "`trustCwd` resolved not hardcoded" specified. Parallel-root conflict with A1 (M3) — rebase onto post-A1 main. |
| **T2** | ✅ | Base T1, also-needs D1. Elicitation gated on client `elicitation` flag; `isatty` split; no `--trust`; autonomy-exempt. Merge D1 first (risk 5). |

---

## Bottom line

The **design** is ready — grounded, internally consistent, and complete enough to plan+build+test each PR
without a human decision. After author verification, the **only hard pre-req is M1** (merge the plan vault
to the forest's base branch so cards can read their own plan). The former M2/M3 are handled by how the
harness and forest actually work: the UX-e2e drives via state/RPC with no synthetic input and an existing
Screen-Recording grant (needs only a live GUI session), and the "parallel" roots are serially-merged
branches whose edits git auto-merges. The remaining safeguard is the **trust-origin guarantee** (risk 4 —
every forest card is `worktree` origin on the already-trusted repo, so the human-only elicitation never
fires). Do M1 + that, and the forest can run overnight with no human in the loop. **GO once M1 lands.**
