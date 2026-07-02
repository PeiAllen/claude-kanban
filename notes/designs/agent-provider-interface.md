---
project: claude-kanban
feature: agent-provider-interface
type: design-note
status: draft-for-review
created: 2026-06-29
updated: 2026-07-01
related:
  - "[[model-providers/index|model-providers (axis 2)]]"
  - "[[agent-integration/index|agent-integration (axis 3)]]"
  - "[[context-passing-topologies|context-passing topologies]]"
  - "[[context-continuity/index|context-continuity (axis 6)]]"
  - "[[freeform-and-borrowed-cards/index|freeform/borrowed/read-only]]"
  - "[[agent-provider-research-appendix|research appendix (sources)]]"
---

# The Agent-Agnostic Provider Interface — Design & Reference

> **What this is.** A single reference for how Orchestra runs *any* coding-agent CLI behind one seam —
> grounded in a deep investigation of Claude Code, OpenAI Codex, the broader agent-CLI landscape, ~14
> precedent orchestrators/protocols, the steering/merge-back problem, and the auth/ToS constraints.
> **Read it, confirm the decisions, iterate.** Every decision is tagged so you can react. Raw sources
> are in the [[agent-provider-research-appendix|research appendix]].
>
> **Status:** draft for your review. Nothing here is built yet; this deepens
> [[model-providers/index|axis 2 (model-providers)]] to an implementable design and pins the seam
> decisions that the other axes depend on.

---

## 0. The one-paragraph summary

Orchestra should keep doing exactly what it does — **drive the real vendor CLI as a process in a tmux
pane, one git worktree per card** — and generalize the seam around it. Almost every comparable system
(Databricks **Omnigent**, Vibe Kanban, OpenHands, opencode, Crystal, …) independently converged on this
shape, so it's the validated path, not a guess. A new provider plugs in by implementing a **small
adapter** (≈5 methods) that builds the launch command, **parses the agent's output into one normalized
event type**, and declares a **capability descriptor**. Everything variable across agents — session-id
ownership, telemetry transport, permission expression, steering — is handled by **capability flags +
per-adapter mapping**, never `if provider == "claude"` in the core. The hard invariant that keeps it
legal: **drive the official binary and let *it* authenticate; never reimplement the API client or lift
the login token.**

---

## 1. The core decisions (confirm / iterate on these)

| # | Decision | Recommendation | Status |
|---|----------|----------------|--------|
| D1 | Adapter shape | **Process-adapter over PTY/tmux** (not a server/HTTP adapter, not an in-proc SDK) | **Confirmed** (2026-07-01) |
| D2 | How a backend is added | **Runtime registry of ~5-method adapters** (not a recompiled enum) | **Confirmed** (2026-07-01) |
| D3 | Output handling | **One normalized event type** every adapter parses into | **Confirmed** (2026-07-01) |
| D4 | Variation handling | **Capability descriptor** (flags) + per-adapter native mapping | **Confirmed** (2026-07-01) |
| D5 | Session identity | **Discover-by-default** (store the id the backend emits); seeding is an optimization | **Confirmed** (2026-07-01) |
| D6 | Telemetry | **Structured-stream parse** where available (Claude hooks-push, Codex rollout-tail), **PTY-scrape** fallback; turn-done detected **out-of-band**. Parse is the **adapter's** (`adapter.parse`); the daemon owns only the **transport** | **Confirmed** (2026-07-01) — parse-in-adapter |
| D7 | Context window / cost | **Per-adapter offline model table** (extends `Adapter.models()`), vendored in-repo + PR-updated → `contextWindow` + capability flags. **No** models.dev/LiteLLM fetch — app stays offline | **Confirmed** (2026-07-01) — see §6 |
| D8 | Permissions | **3 orthogonal layers** (tool-gating · approval-policy · OS-sandbox); read-only is a **preset** | **Confirmed** — no-sandbox agents → `toolGatedOnly` + a visible **weak-RO badge** |
| D9 | Live delivery / merge-back | **Three core functions:** F1 resume-in-card (a *start* action), F2 wake (capability `wakeTransport` — Claude native re-invoke / Codex send-keys + detect-and-defer), F3 push-inbox (Stop-hook drain). Goals (handoff/fork/fan-out/send/queue) compose them; blocking-`await` pull **dropped** | **Confirmed** — see §8 |
| D10 | Transport | **Native Claude (TUI+hooks) + native Codex (TUI+rollout-tail) only.** ACP adapter **not built** (design reference only); Codex `app-server` **not needed for v1** (the inbox covers steering) | **Confirmed** |
| D11 | Auth invariant | **Drive the binary, never the token/API client** | **Hard constraint** |
| D12 | Auth modes | Carry `authMode ∈ {subscription, apiKey}`; **soft-warn only** on heavy parallel subscription use (no concurrency cap — q4 resolved) | **Confirmed** (2026-07-01) |

The **only true constraint** is D11 (a ToS bright line); the rest began as recommendations. All D-rows are
now **Confirmed** (D1–D5/D12 settled 2026-07-01, matching the layered plan); **no open questions remain** (§12).

> **Scope (confirmed 2026-06-29).** The targets that matter are **Claude, Codex, and (eventually) a local
> model.** The seam is built *agnostic* — the capability descriptor + normalized-event type mean any agent
> *could* be added — but the only concrete adapters built now are **Claude (done) + Codex (next)**. The
> long-tail (Gemini/opencode/Amp/Goose/…) and **ACP** are **not implemented**: we build the *base infra*
> that would admit them, nothing more. A **local-model** adapter (likely via Codex `--oss`/Ollama or a thin
> dedicated adapter) is a tracked future, not built now.

---

## 2. Grounding (why these decisions, in one screen)

This design rests on a multi-pass investigation (full sources in the appendix). The load-bearing findings:

- **Convergent architecture.** ~10 independent multi-agent coding orchestrators all (a) **wrap the real
  CLI**, (b) use **one git worktree per unit of work**, (c) drive it over **tmux/PTY**, and (d) normalize
  output to a board. Databricks **Omnigent** — the closest analog — states the contract as *"messages and
  files in, text streams and tool-calls out,"* with a per-agent `executor.harness` selector. **Orchestra
  already is this.**
- **Two telemetry strategies, period.** Structured-stream parse (preferred) vs **PTY scrape + buffer-hash
  + prompt-signature table** (the hook-less fallback). Turn-completion is detected from **process exit /
  buffer-stops-changing**, never from content.
- **Session ids are discovered, not seeded** — universally (even for Claude, Vibe Kanban parses the id
  from the stream). ACP's `session/new` *returns* the id.
- **Steering converged on queue-until-turn-boundary** — not mid-turn preemption. The synchronous path is
  reserved for **approvals** (an `approval_id` round-trip).
- **Standards validate the shape.** **ACP** (Zed) = capability handshake + discovered session id + a typed
  `session/update` event stream + a clean permission-option vocabulary — i.e. exactly the seam, minus
  Orchestra's tmux/worktree/async-steer core (which ACP lacks). **A2A** = AgentCard (capability
  descriptor) + a Task state machine + Artifact-rejoin. **AG-UI** = snapshot + JSON-Patch deltas for the
  board feed. **models.dev/LiteLLM** = the model/context-window registry.
- **Auth reality.** Claude: ACP/SDK reject subscription OAuth and ToS bars routing subscription creds
  through third-party tools — **only the native binary preserves a subscription.** Codex: native CLI,
  `app-server`, and `codex-acp` all preserve the ChatGPT subscription (they spawn the binary); only the
  SDK/Responses API forces a key. **Common rule: drive the binary, never the token.**

---

## 3. Architecture & the auth invariant

Orchestra is the **client** of each agent; each agent owns its pane, its worktree, and **its own auth**.
Orchestra never holds a provider API token and never speaks the provider's HTTP API directly.

```mermaid
flowchart TB
    subgraph Daemon["orchestrad (one coordinator)"]
        Reg["AgentRegistry<br/>(adapters by id)"]
        Svc["OrchestraService"]
        Store["TaskStore + per-card inbox"]
        Norm["Normalized event bus<br/>→ board (snapshot + JSON-patch)"]
        Reg --> Svc --> Store
        Svc --> Norm
    end
    subgraph Card["one card = one worktree"]
        Adp["Adapter (Claude / Codex / …)"]
        Tmux["tmux pane"]
        CLI["official vendor binary<br/>(claude / codex)"]
        Adp -->|"build argv/env/files"| Tmux --> CLI
    end
    Svc -->|spawn/resume/steer| Adp
    CLI -->|"telemetry: hooks-push OR file-tail OR pty-scrape"| Norm
    CLI -.->|"OAuth/login it owns — Orchestra never sees the token"| Vendor[(Vendor auth)]
    classDef hard fill:#fde,stroke:#c39;
    class Vendor hard
```

**D11 — the invariant (hard constraint).** An adapter MUST launch the vendor's official binary (or its
own server process) and let *it* authenticate. It must NEVER reimplement the provider API client, inject a
provider API token into its own HTTP calls, or extract/reuse the user's login (OAuth) token. This is what
keeps subscription auth legal on both providers (token-lifting got OpenCode/Roo/Goose's subscription access
blocked, Jan 2026) and it's what all precedent orchestrators do anyway. (Details + per-provider matrix: §9.)

**OrchestraService — authoritative reducer, not a relay (added 2026-07-01).** The coordinator decomposes
into four concerns: **action-ingress** (command handlers), **event-ingress** (`report()` + the seq-gate
merge), **event-egress** (the `AsyncStream<Event>` the board subscribes to), and **live-delivery +
recovery** (inbox · wake · MergeWatch · resume). Its authority splits by the D3 tier and is
**state-authoritative, not event-sourced**: it is the single writer that *adjudicates* card **lifecycle**
(ControlEvent) — rejecting stale snapshots via the seq-gate, deciding terminal-vs-revive via
liveness-reconcile, persisting to `TaskStore` — but it **relays content** (ContentEvent), for which the
**vendor transcript file is SSOT**. It is the authoritative *interpreter* of reality (process / transcript
/ git), not its definer; a late subscriber gets a **snapshot**, never an event-log replay.

---

## 4. The adapter seam

A backend is admitted by implementing a **small adapter** registered by id (D2). The interface converges
(across Crystal's `AbstractCliManager` and Vibe Kanban's `StandardCodingAgentExecutor`) on ~5
responsibilities:

```mermaid
classDiagram
    class Adapter {
      +id String
      +capabilities AgentCapabilities
      +buildLaunch(ctx) LaunchSpec
      +parse(source) NormalizedEvent_list
      +resumeHandle(task) Handle
      +prepareToLaunch(ctx) void
    }
    class AgentCapabilities {
      +sessionId  seeded_or_discovered
      +telemetry  hooksPush_fileTail_ptyScrape
      +contextUsage  percent_tokens_none
      +wakeTransport  nativeReinvoke_controlChannel_sendKeys_relaunch
      +inboxDrain  stopHook_sessionSeed_none
      +readOnlyEnforcement  sandboxed_toolGatedOnly_orchestraSandboxed
      +authMode  subscription_or_apiKey
    }
    class ControlEvent {
      +sessionDiscovered_id
      +turnStarted
      +turnEnded_reason_usage
      +idle
      +exited_code
      +error_kind_message
      +approvalRequested_id_action_options
      +approvalResolved_id_decision
      +usageUpdate_tokens_ctxPct
    }
    class ContentEvent {
      +assistantMessage_text
      +thinking_text
      +toolCall_id_name_summary_status
      +toolCallUpdate_id_status_result
      +plan_items
      +raw_kind_native
    }
    class LaunchSpec {
      +argv String_list
      +env Map
      +files Map
    }
    Adapter --> AgentCapabilities
    Adapter --> ControlEvent
    Adapter --> ContentEvent
    Adapter --> LaunchSpec
```

> `buildLaunch` returns argv+env+files and covers start/resume/read-only/seed; `parse` is **the
> normalization core**; `resumeHandle` returns the discovered id (resume = fresh process);
> `prepareToLaunch` does trust-grant + isolated config home + the read-only recipe. `AgentCapabilities`
> values are enums (e.g. `sessionId ∈ {seeded, discovered}`); the normalized event is a **two-tier sum
> type** — `ControlEvent` (reliable lifecycle) + `ContentEvent` (best-effort display) — detailed in D3.

**D3 — the normalization core (a *two-tier* event type).** The single most important move (how every
multi-CLI tool abstracts Claude-vs-Codex): they do **not** unify wire protocols — each adapter's `parse()`
collapses its agent's output into **one normalized event type**. Claude hooks, Codex rollout JSONL, ACP
`session/update`, opencode SSE — all become the same shape. But the events split into **two tiers with
different reliability guarantees**, because the architecture already sources them differently (turn-end is
detected *out-of-band* from content, §6):

- **`ControlEvent` — low-volume, must-not-drop.** Drives the card state machine, the inbox/steering (§8),
  lineage, approvals, and the meters: `sessionDiscovered`, `turnStarted`, `turnEnded{reason, usage}`,
  `idle`, `exited{code}`, `error`, `approvalRequested{id, action, options}`, `approvalResolved`,
  `usageUpdate{tokens, ctxPct}`. **Losing one is a bug** — a dropped `turnEnded` means the inbox never
  drains and a merge-back is silently lost. (`usageUpdate` lives here, not in content: it's low-volume and
  both agents emit it reliably — Claude `used_percentage`, Codex `turn.completed.usage`.)
  > **Scope note (forest vs eventual):** the **typed** `turnEnded{reason}`, `approvalRequested`, and
  > `approvalResolved` fields are **deferred out of this PR forest** (they land with the Codex approval
  > round-trip, a later PR). In-forest, turn-end is detected via **status transitions + the Stop hook** and
  > `EventReport` carries **no** typed turn/approval fields yet. A2 must not build them. (See [[03-implementation]] "Approvals deferred".)
- **`ContentEvent` — higher-volume, lossy-OK.** Feeds the activity line and the detail view:
  `assistantMessage{text}`, `thinking{text}`, `toolCall{id, name, summary, status}`,
  `toolCallUpdate{id, status, result}`, `plan{items}`, `raw{kind, native}`. **The vendor's own transcript
  file is the source of truth** (`~/.claude/.../<id>.jsonl`, Codex `rollout-*.jsonl`); this tier is only
  for liveness, so a dropped event just means a momentarily stale board — recoverable from the file.

Three properties that fall out of this split:

- **Content is coarse, not streamed (v1).** Events carry *complete blocks*, not token-deltas — both v1
  transports are already item/boundary-grained (Claude hooks fire at `Pre/PostToolUse`/`Stop`; Codex's
  rollout is append-of-completed-items), so streaming deltas aren't even available without abandoning those
  transports (§6/§9). Tool calls still feel live because `toolCall{status:running}` lands the instant a tool
  starts. The only thing deferred is word-by-word prose — and that returns later as a *detail-view render
  feature tailing the vendor file*, never as a property of the event bus.
- **`toolCall` carries an id + a status lifecycle** (`pending → running → ok|error`, borrowed from ACP
  `tool_call`/`tool_call_update`) so the board updates a tool row in place. An **approval is just a tool
  call sitting in `pending` with options** — `approvalRequested` references the same id.
- **`raw{kind, native}` is the open escape hatch.** Unmodeled output (a novel agent's plan format, a
  web-search result, an MCP-specific item) is still displayable and storable without a core schema change —
  this is what makes "agnostic" honest rather than aspirational, and it matches the confirmed scope (build
  base infra to admit others; don't model the long-tail).

> **`turnEnded` ≠ concluded.** The *parent's* inbox drains on every `turnEnded` (the turn boundary). A
> *fork's* merge-back fires when the fork **concludes** — `exited` or moved-to-Done — **not** on any
> `turnEnded` (a fork ends many turns before it's done). So both events are first-class and merge-back keys
> off `exited`. `turnEnded.reason` carries ACP's stop vocabulary (`end_turn | max_tokens | cancelled |
> refusal | error`) so the injector knows whether to continue-with-inbox or back off.

The board, status logic, and inbox only ever see these normalized events — never a provider's wire format.

**D4 — capability descriptor.** Everything that varies in *kind* is a flag the adapter advertises
(modeled on ACP's `initialize` handshake and A2A's AgentCard). The daemon and UI **degrade on flags, never
branch on provider identity.** This is what admits Codex without `if claude`.

**D2 — registry, not enum.** Keep `AgentRegistry` keyed by id; resolve the adapter from `Task.agentId` at
every op (already the case). A new provider = a new adapter file + a registry entry.

### 4.1 Start actions — the launch seam

Orchestra→agent actions split into **start actions** (made true at/before the process is born) and **live
actions** (delivered to a running agent, §8). This section is the start side.

**One request behind every way a process comes up.** `spawn`, `batch-spawn`, `restart`, `resume`, and
`fork` look distinct but are the *same* normalized `LaunchRequest` with different data — they never differ
in mechanism:

| Operation | What differs | Reduces to |
|---|---|---|
| `spawn` | new card, cold session | `resume: nil` |
| `batch-spawn` | N spawns (fan-out) | N × `resume: nil` |
| `restart` | reuse card/worktree, discard session | `resume: nil` on existing cwd |
| `resume` | restore prior session | `resume: <handle>` |
| `fork` | child seeded with a parent slice | `resume: nil, seed: <slice>` |

So **`resume` is just a kind of start** (same prep + handle-restore), and — because the OS sandbox is fixed
at exec (§7 L3) — **changing a card's access posture is a *relaunch*, not a live action.** Resume is the
vehicle for every start-bound change.

**The six goals of bringing up an agent.** Five are start-bound; the sixth (Task) bridges to the live path.

1. **Place** — right cwd + an **isolated config home** so per-card settings/hooks don't leak or collide.
2. **Admit** — trust resolved so the agent doesn't block on a "trust this folder?" prompt (see below).
3. **Instrument** — telemetry wired, MCP (inbox) wired, session made addressable.
4. **Constrain** — access posture / sandbox fixed (§7).
5. **Orient** — authored seed context in place, model chosen.
6. **Task** — deliver the first user turn — *or* leave the agent idle and deliver it through the same live
   idle-wake path as every later message (§8). There is **no special "initial prompt" mechanism**; the seed
   is system-level (materialized before turn 1), the task is the first user message.

**The normalized request + the two adapter entry points.** The core builds one provider-agnostic
`LaunchRequest`; the adapter lowers it. Most goals are "same kind, different flag" (pure mapping); only
three vary in *kind* and are resolved from the capability descriptor inside the adapter: `sessionId`
(seed vs discover), `telemetry` (push agents *install* a hook at launch; tail agents install nothing), and
`readOnlyEnforcement` (the 3-layer map).

```
LaunchRequest                      // normalized intent — core builds from the card
  cwd          Path
  origin       CardOrigin          // worktree | scratch | borrowed(freeform) — drives trust (below)
  resume       SessionHandle?      // nil = cold (spawn/restart/fork); present = resume
  model        ModelRef            // model + effort
  access       AccessPolicy        // enum {default, readOnly} now (grows later) → §7.1
  seed         SeedContext?        // authored system-level context (handoff / additionalContext)
  task         Message?            // first user turn; nil → launch idle, deliver via inbox
  tools        McpConfig           // Orchestra inbox server + card tools
  // config-isolation + telemetry-install are IMPLIED (our instrumentation, never per-card).
  // trust: resolved by the CORE from origin (advisory, not a boundary); applied by the adapter — see below.

adapter.prepareToLaunch(req)       // idempotent FILESYSTEM/CONFIG side effects (safe to re-run on resume):
  materialize isolated config home · mirror resolved trust onto cwd · install telemetry wiring
  (Claude hooks→_report / Codex none) · write seed files (CLAUDE.md/AGENTS.md/append-prompt) ·
  write MCP config · apply file-expressed posture
adapter.buildLaunch(req) → LaunchSpec{argv, env}   // PURE:
  binary + resume flag + model flag + sandbox/approval flags + seeded session-id + env
```

**Trust — advisory, resolved by the core, granted only by a human.** Trust is **not a containment
boundary**: an agent with a shell can self-edit the vendor's own trust file (`~/.claude.json`
`hasTrustDialogAccepted`, Codex `trust_level`), and an agent launched *outside* Orchestra never sees our
resolution at all. The real boundary is the **OS sandbox (§7 L3)**, which the agent cannot edit its way out
of. So trust's job is narrower and honest: **avoid *accidentally* auto-executing unfamiliar in-repo config
(hooks/MCP) at startup, and record human intent.** We resolve it sensibly and guard the *accidental* case;
we never pretend it's a wall. (Goal: *assume a human launched the agent — just don't let the agent
accidentally trust something against that human's wishes.*)

*Resolution (core, provider-agnostic).* The core resolves trust from `origin` against **one Orchestra-owned
ledger**; the adapter only *applies* the result (writes the native flag). Every answer bottoms out in a
prior human act:

| `origin` | Trust rule | Why it's reasonable |
|---|---|---|
| `worktree` | **inherit from the source repo** (registering a repo to run agents *is* the trust act); mirror repo-trust onto the worktree path | worktree = same code as the repo |
| `scratch` | **trust** | Orchestra created it empty — no foreign in-repo config to execute |
| `borrowed` (freeform) | **trust iff already in the ledger**; else it's a fresh grant decision (below) | an arbitrary cwd must carry its own trust |

*Granting (always a human, never automatic).* When the cwd is untrusted and not yet in the ledger, a grant
is **only ever a human answering a prompt** — never an autonomous agent action *and never an automatic
policy*. The prompt routes like any other elicitation/hook — the agent's pane by default, or a board/phone
surface if so configured (trust gets no special routing) — but its one inviolable rule is **who answers it:
a human**. In particular, an autonomy / auto-accept card (which auto-answers ordinary tool approvals) must
**exempt trust**. The prompt renders wherever that human is:

- **App new-agent dialog** → inline choice as you pick the cwd (*trust · read-only · cancel*).
- **Agent via MCP** → an **elicitation** to the human running that agent — in their own client, or, for an
  Orchestra-spawned agent, natively in the card's pane. Same human, same machine, approved outside
  Orchestra's app. This is a server→client `requestElicitation` gated on the client's advertised
  `elicitation` capability (MCP `initialize`) — **both v1 targets, Claude Code and Codex, support it**, so it
  is the native grant path for both. *(A hypothetical agent whose client lacks elicitation would need a
  fallback — a board-routed approval gate; not built, since neither target needs it.)*
- **CLI** → the human/agent split rides the **TTY** (human calls are interactive; an agent's Bash call is
  not):

| CLI case | Behavior |
|---|---|
| trusted / worktree / scratch | run |
| untrusted + **interactive (TTY → human)** | prompt *trust · read-only · cancel* |
| untrusted + `--read-only` (any caller) | run sandboxed read-only — the safe autonomous path |
| untrusted + **non-interactive, no `--read-only`** | **fail with actionable context** → "re-run with `--read-only` to run sandboxed, or use the MCP `trust`/`spawn` tool for **explicit human approval** (trust is a dangerous, human-only decision)" |

There is **no `--trust` flag** — no non-interactive path can grant trust, so an agent has no way to
*accidentally* trust; the worst it can do autonomously is run sandboxed. This is a deliberately *soft* guard
(a determined agent could allocate a PTY) — correctly scoped to the **accidental** case; malice is the
sandbox's job.

*Trusting a folder without launching a card.* Two deliberate pre-bless paths, same human-only property:
- **CLI `orchestra trust <path>`** — **interactive-only** (refuses non-interactively): a clearly deliberate
  human act, the agent can't reach it accidentally.
- **MCP `trust` tool** — agent-callable but **elicits explicit human approval** (same mechanism as the
  untrusted-spawn path): the agent *triggers*, the human *approves*. The agent never self-grants.

Notes: (a) the **one Orchestra-owned ledger** (keyed by repo/cwd, mirrored down per-agent) is what makes a
repo long-trusted in Claude not come up *untrusted* the first time you spawn a Codex card on it. (b)
`scratch`'s "trust" assumes it stays Orchestra-owned-and-empty; a scratch card that **clones a foreign repo
into itself** (external-intake) is really `borrowed` and demotes to conditional — the key is *whose code is
in the cwd*, with `origin` as the proxy.

---

## 5. Session identity (D5)

```mermaid
flowchart LR
    Spawn["spawn card"] --> Cap{"capabilities.sessionId"}
    Cap -->|"seeded (Claude)"| Seed["set agentSessionId pre-launch"]
    Cap -->|"discovered (Codex, ACP, most)"| Nil["agentSessionId = nil"]
    Seed --> Launch
    Nil --> Launch
    Launch["launch in pane"] --> Watch["parse emits the discovered sessionId"]
    Watch --> Save["store agentSessionId once seen"]
    Save --> Resume["resume = fresh process<br/>(claude --resume / codex resume)"]
```

Treat **discover-and-store** as the normalized model; Claude's seedable id is an optimization, not the
architecture. Resume is always a **fresh process** with the stored handle (no live reattach). Resumability
becomes an **adapter answer** (`resumeHandle`), replacing today's `~/.claude` transcript-file stat — Codex
has no such file (its analog is `~/.codex/sessions/.../rollout-*.jsonl`).

> This loosens two current couplings (`isResumable`/`resume` requiring a pre-seeded id and a Claude
> transcript path) — both flagged in the seam audit as Claude-structural.

---

## 6. Telemetry (D6, D7)

Two transports collapse into one normalized stream; the board renders from a **snapshot + JSON-Patch
deltas** (the AG-UI / Vibe Kanban pattern).

```mermaid
flowchart TB
    subgraph Sources["per-adapter telemetry source"]
      Push["Claude: hooks → orchestra _report<br/>(agent PUSHES; carries ctxPct%)"]
      Tail["Codex: daemon TAILS rollout JSONL<br/>(turn.completed.usage = tokens)"]
      Scrape["Fallback: PTY capture-pane<br/>+ buffer-hash + prompt-signature table"]
    end
    Push --> Map["adapter.parse() → NormalizedEvent[]"]
    Tail --> Map
    Scrape --> Map
    Map --> Ctx{contextUsage}
    Ctx -->|percent| Direct["ctxPct = reported %"]
    Ctx -->|tokens| Derive["ctxPct = tokens ÷ model.contextWindow<br/>(from models.dev/LiteLLM registry)"]
    Direct --> Bus["normalized bus"]
    Derive --> Bus
    Bus --> Board["board: STATE_SNAPSHOT then STATE_DELTA (JSON-Patch)"]
    Done["turn-end: process-exit / rollout turn.completed / buffer-idle — NOT 'model said done'"] --> Bus
```

- **Claude = hooks-push** (its strength; keep it — and it's the ToS-safe interactive path, §9). **Codex =
  rollout-tail**: the TUI doesn't emit `--json`, but it *does* write `~/.codex/sessions/.../rollout-*.jsonl`
  containing token usage, activity items, the session id, and turn completion — so the daemon tails that
  file per card. Both are instances of "structured-stream parse → normalized event."
- **PTY-scrape is the universal fallback** (for hook-less agents): `capture-pane` + SHA-256(buffer)
  unchanged = idle + a **prompt-signature table kept as adapter config, not hardcoded** (it's the
  highest-churn technique in the field).
- **The event bus is a control+liveness channel, not the transcript store.** The conversation's source of
  truth is the **vendor's own transcript file** (`~/.claude/.../<id>.jsonl`, Codex `rollout-*.jsonl`),
  rendered into the card-detail view on demand. So `ContentEvent`s are deliberately **coarse** (complete
  blocks, not token-deltas) — which also aligns with the transports: both push at item/boundary granularity
  (Claude hooks, Codex rollout items), so streaming would require a different, billing-disfavored transport
  (§9). A live word-by-word feed, if ever wanted, is a *detail-view render path tailing the vendor file* —
  decoupled from the bus. (See D3 for the `ControlEvent`/`ContentEvent` split.)
- **D7 — model data (per-adapter, offline).** Drop hand-maintained context windows, but **keep the data
  in the adapter**: extend the existing `Adapter.models()` with `contextWindow` + `tool_call/reasoning/
  vision` flags, sourced from a **vendored in-repo table, PR-updated** — **no** models.dev/LiteLLM fetch, so
  the app stays fully offline at build and runtime. `ctxPct` denominator = `adapter.model(for:).contextWindow`.
  *(Confirmed 2026-07-01, resolving §12 q6 — a separate global `ModelRegistry` component was rejected as
  redundant with `Adapter.models()` and as pulling toward an external source.)*

---

## 7. Permissions & read-only (D8)

Permissions are **three orthogonal layers**, not one knob. "Read-only" is a **preset across them**, not a
primitive.

```mermaid
flowchart TB
    subgraph Layers["3 orthogonal layers"]
      L1["L1 — Tool gating<br/>which tools the model may invoke"]
      L2["L2 — Approval policy<br/>auto vs ask-a-human (approval_id)"]
      L3["L3 — OS sandbox<br/>what the PROCESS may do, regardless of the model"]
    end
    Pol["AccessPolicy enum<br/>{default, readOnly} — grows later"] --> Map2["adapter maps policy → native mechanism"]
    Map2 --> L1 & L2 & L3
    RO["read-only preset"] -->|deny mutating tools| L1
    RO -->|"+ semantic 'deny any mutation' (Claude autoMode)"| L1b["L1.5 classifier"]
    RO -->|sandbox blocks writes/network| L3
    L3 --> Enf{osSandbox?}
    Enf -->|native| OK["readOnlyEnforcement = sandboxed (true RO)"]
    Enf -->|none| Gap["Orchestra wraps in its own sandbox<br/>OR downgrade → toolGatedOnly (weaker; surface it)"]
```

| | Claude | Codex | No-sandbox agents (opencode/Amp/Goose/Aider) |
|---|---|---|---|
| **L1 tool gating** | `--allowedTools`/`--disallowedTools` | approval rules | per-tool allow/ask/deny |
| **L2 approval** | `--permission-mode` + PreToolUse hooks | `--ask-for-approval` | varies |
| **L3 OS sandbox** | seatbelt + `denyWrite` | `--sandbox read-only/workspace-write/…` | **none** |
| **read-only** | L1+L1.5+L3 (shipped 3-layer barrier) | `--sandbox read-only -a never` | L1 only → **not true RO** |

**The real read-only decision (confirmed 2026-06-29):** `supportsReadOnly` is too coarse — model it as
`readOnlyEnforcement ∈ {sandboxed, toolGatedOnly, orchestraSandboxed}`. **For agents with no OS sandbox,
ship `toolGatedOnly` with a visible "weak read-only" badge** (a Bash escape could still write) rather than
Orchestra wrapping the process itself; `orchestraSandboxed` (our own `sandbox-exec`/container) stays a
*future* option, not built now. This is moot for the targets that matter — **Claude and Codex both have
native OS sandboxes → `sandboxed` (true read-only).** *Never advertise a read-only card you can't enforce —
the badge makes the weaker guarantee explicit.* Approvals normalize to one `ApprovalRequest{id, action}` event + a
`respond(id, decision)` call, `decision` using ACP's `{allow_once, allow_always, reject_once,
reject_always}` vocabulary — so the board's approval UI is provider-agnostic. On Claude these are sourced
from the **`Elicitation`/`ElicitationResult` hooks and `PreToolUse permissionDecision:"ask"`**; on Codex
from `--ask-for-approval` + its during-tool-flow elicitation. By default a prompt **passes through** to the
agent's pane for the human; re-routing it to another human surface (board/phone) is a **uniform hook choice,
not approval-specific** — any hook/elicitation can be routed that way. The trust elicitation (§4.1) is no
exception to this routing; its only special rule is *who* answers it: a human, never an automatic policy.

### 7.1 The access interface — what actually crosses the seam

For the targets that matter now, **two access sets** are defined:

| Set | Meaning |
|---|---|
| `default` | run under the **user's own** permission/sandbox config — Orchestra adds nothing but its instrumentation (the isolated config home *layers over* the user's settings, never replaces them) |
| `readOnly` | `default` minus the ability to mutate — Orchestra imposes the read-only barrier |

*(Tracked for later: `supervised`, and a "read-only except writes to plans/notes" carve-out — the latter
is `readOnly` + a path allow-list.)*

**What crosses the core↔adapter boundary is tiny**, despite all the conceptual machinery above — two things:
- **Request (core → adapter):** `LaunchRequest.access` — a small preset enum (`default | readOnly`),
  consumed inside `buildLaunch`/`prepareToLaunch` (§4.1); no separate method.
- **Capability (adapter → core):** `readOnlyEnforcement` — *what `readOnly` is worth on this agent.*

Everything else stays **below the line**: the **axes** (writeScope · network · approval · toolGating) are
the *vocabulary that defines what a preset means* — documentation, not types; the **layers** (L1/L1.5/L3)
are each adapter's *internal* realization (Claude stacks L1+L1.5+L3, Codex uses L3 alone) and a **checklist
for adapter authors**, never an interface.

**Capability flags are outcomes, not mechanisms.** The rule for what becomes a flag: *would core branch on
it?* Core branches on `readOnlyEnforcement` (badge vs trust); it would never branch on "has a classifier" or
"has an L3 sandbox" — those are *means*, and exposing them would (a) leak adapter internals and (b) force
core to recombine them into the guarantee, i.e. re-derive per-provider logic in core — the exact thing the
descriptor exists to avoid. So:
- **`readOnlyEnforcement` is the only access capability flag now.** `osSandbox` is **redundant with it** for
  the 2-set scope and is **deferred** — it earns its own flag only if a future `autonomous` mode needs "is
  the sandbox the boundary?" as a gate.
- **No `L1/L2/L3` flags** — they're the adapter's means, not a contract, and they don't even map uniformly
  (Codex *fuses* L1+L3 into `-s` modes, with no standalone L1 and no L1.5).

**Share the policy, realize the enforcement ad hoc.** The provider-agnostic part is the **policy intent**
(`AccessPolicy`) — defined once in core. The **enforcement** is irreducibly per-adapter, because the agents'
shapes diverge too much for a faithful shared framework: Claude separates gating/classifier/sandbox and
gates per-tool; Codex fuses them into `-s`/`-a` modes with no per-tool gating. A uniform "every adapter
implements L1/L2/L3" base class — or even a fine-grained allow/ask/deny rule-compiler — would be a **leaky
abstraction one of them fights** (Codex can't take per-path rules; they'd degrade lossily into the nearest
mode, and that degrade is itself per-adapter). So:
- **Now:** ad hoc per-adapter realization (two trivial branches); shared surface = the `AccessPolicy` enum +
  `readOnlyEnforcement`. A framework would be over-engineering.
- **At mode #3:** promote `AccessPolicy` to a more structured policy; each adapter **advertises which policy
  values it can bind**, provides the native binding, and reports an advertised **fidelity** (the
  `readOnlyEnforcement` pattern, generalized) — so a new mode is defined once without a shared enforcement
  framework. **The exact shape of that structured policy is an open question** — to be decided when mode #3
  forces it, with two real adapters to validate against. *(The axes named above —
  writeScope/network/approval/toolGating — are only a first sketch; their right decomposition is itself
  open and not yet agreed.)*
- **Never:** a shared `L1/L2/L3` base class adapters subclass — wrong seam.

> **Trust is part of this surface, but it is *advisory*, not a boundary (links to §4.1).** The trust gate
> controls whether the workspace's **own in-repo config executes** — `.claude/` SessionStart/PreToolUse
> hooks, in-repo `.mcp.json` servers, `AGENTS.md` — and that shell runs at startup, *below* the L1
> tool-gating layer. So trust matters (auto-trusting an untrusted repo lets an in-repo `SessionStart` hook
> run before the model takes a turn — config isolation doesn't cover this, since the in-repo config lives
> inside the very worktree being checked out). **But trust is not enforceable against the agent** — an agent
> with a shell can rewrite the vendor trust file itself. The actual containment is **this layer's L3 OS
> sandbox**, which the agent can't edit out of. So trust is scoped to the *accidental* case: resolved from
> `origin`, **granted only by a human** (§4.1), with the untrusted-freeform default being to **clamp posture**
> (read-only + sandbox + ignore in-repo config). If trust is ever defeated, L3 still holds.

---

## 8. Live delivery — feeding & waking a running agent (D9)

Start actions (§4.1) bring a process *up*; this is the live side — getting authored context into an
**already-running** agent (a user follow-up, a fork's conclusion, a handoff). The field converged on
**queue-until-boundary**, never mid-turn injection. All of it reduces to **three core functions** — and the
heaviest one is actually a *start* action. (The only synchronous path remains approvals, §7.)

### 8.1 The three core functions

| | Function | Kind | Claude | Codex (v1) |
|---|---|---|---|---|
| **F1** | **Resume-in-card** — kill the agent, relaunch it in the same card seeded with context + inbox | **start action** (§4.1) | `claude --resume <id>` + `SessionStart additionalContext` | `codex exec resume <id> "…"` |
| **F2** | **Wake** — trigger a turn on an *idle* agent so it drains its inbox | live | **native re-invoke** (agent backgrounds a watcher → harness wakes it) | **send-keys nudge** + detect-and-defer |
| **F3** | **Push-inbox** — enqueue a durable message; the agent reads it at its next turn-end via an Orchestra hook | live | Stop hook `decision:block` + `additionalContext` (10k) | Stop hook `decision:block` + `reason` |

**F1 — resume-in-card (a *start* action).** Killing the agent and relaunching it in the same card is — by
the §4.1 taxonomy — a *start*: a new process is born. It's `LaunchRequest{resume, seed}` on the existing
cwd, with the handoff context / pending inbox materialized as the **seed** (resume-seed). It's the **heavy**
path (fresh process, reloads the session), reserved for *deliberate replacement* — handoff-to-clean-context,
posture change (posture is exec-bound, §4.1), or a fallback wake where no lighter transport exists; **not**
for routine waking. (Use `resume`, never a blank `restart` — restart drops the session, resume keeps it.)

**F2 — wake (live).** When the agent is **idle** (no turn running) and unattended, nothing reaches a Stop
boundary on its own, so F3 can't fire — we must *trigger a turn*. F2 only **triggers**; the actual content
still rides F3 (the inbox via the hook), so a wake **never carries the conclusion through keystrokes**. The
transport is the capability `wakeTransport`:

- **Claude — `nativeReinvoke`.** The orchestrator agent backgrounds `orchestra wait <cards>`; when that task
  completes, **Claude's harness re-invokes the agent in the same session** (the proven merge-watch
  workflow). No keystrokes; stays interactive between wakes.
- **Codex — `sendKeys`.** Codex has no completion-wake (background exec is model-pull) and the plain TUI has
  no control channel — so Orchestra owns the watcher (its merge-watch) and nudges the idle TUI with
  `send-keys` to start a turn. **Gated by detect-and-defer** (below). Keeps the persistent, chattable TUI.
- **`controlChannel`** (future) — app-server `turn/start` / ACP / HTTP wakes an idle session cleanly, but
  needs that run-mode (Codex app-server drops the native TUI → an Orchestra-built viewer; §9).
  **`relaunch`** = F1, the universal fallback.

> **As-built correction + REVISIT — generalize F2 wake across agents (2026-07-01).** The design above
> assumed a Claude idle-wake is *always* covered by `nativeReinvoke` (the harness re-invokes when a
> background `orchestra wait` exits). That's only true for **reactive orchestration** (pattern A): a plain
> **`send`/queue to a genuinely idle Claude card has NO background wait**, so nothing reaches a turn and the
> message sat inbox-durable until some unrelated future turn (bug: `send-wakes-idle-card`). As-built fix:
> that one case now wakes via **resume-seed** — the `relaunch`/`resumeInCard` primitive (kill + `claude
> --resume` with the inbox folded into the opening turn, the same engine as `handoff`), gated to fire only
> when the card is `.waiting`, not `recovering`, resumable, and **not** a live watcher (`watchRegistry`
> empty — else the wait-exit re-invoke handles it). So Claude now has **two** F2 mechanisms depending on
> whether a wait is live: harness-reinvoke (has-wait) vs resume-seed relaunch (no-wait).
>
> This is a **stopgap on both sides** and should be revisited as one problem: Codex's `sendKeys` leans on a
> **fragile TUI pane-scraper** (`CodexComposer.canNudge`, self-described "FRAGILE BY NATURE", drifts across
> versions) and Claude's no-wait wake leans on a **heavy relaunch**. We deliberately did NOT build a
> `ClaudeComposer` to sendKeys-nudge Claude — a second fragile scraper plus the hazard of a blind keystroke
> into a permission/plan-mode prompt. The right generalization for **all** agents is **`controlChannel`** (a
> real `turn/start` RPC — Codex app-server / ACP / a native Claude control surface), which retires *both*
> the pane-scraper and relaunch-for-wake and makes "wake an idle card" one clean, agent-agnostic primitive.
> Until then, F2 is: `sendKeys` (Codex, gated) · `nativeReinvoke`-or-`resume-seed` (Claude, by wait-state) ·
> `controlChannel` (target). See `OrchestraService+Wake.swift` (`wake` / `resumeSeedWake`).

> **Detect-and-defer (the safety guard for `sendKeys` wake).** A wake is **not time-critical** — the
> conclusion is durable in the inbox — so Orchestra defers the nudge until it's safe. Gate: **idle AND
> composer-empty** (Orchestra reads the composer via `capture-pane`; an unsent draft → *hold* the wake until
> you submit/clear). **Focus is *not* a gate** — sitting on an idle orchestrator *watching it wait is the
> normal path*: composer empty → the wake fires → you see the next PR kick off. The only residual is the
> watching-then-suddenly-typing TOCTOU (a ~ms window) — and since you're present, a rare collision is
> *visible and self-correctable* (Ctrl-C, retype); the unattended case has no draft to collide with. So the
> dangerous quadrant — silent corruption — doesn't exist.

**F3 — push-inbox (live, uniform).** A **durable per-card inbox**; Orchestra installs a **Stop-hook** at
launch (`prepareToLaunch`, §4.1) that drains it at the agent's next turn-end and forces continuation
(`decision:block` + `additionalContext` (Claude) / `reason` (Codex)) — **no restart, no keystrokes,
receiver-transparent** (the agent reads the message as injected context; it never sees the hook). Both
agents expose `stop_hook_active` but **neither auto-enforces it** → Orchestra caps consecutive injects
(resolves q5). Payload stays small (Claude caps `additionalContext` at 10k): **conclusions ride the inbox,
artifacts ride git** (a branch + `parentCardId`).

**How they combine.** Busy agent → **F3** alone (a boundary comes naturally). Idle agent → **F2** triggers +
**F3** delivers. Fresh process needed (handoff/posture) → **F1**.

### 8.2 Two usage patterns over the three functions

- **A — reactive orchestration (self-wake).** The agent backgrounds a watcher; on a child's completion,
  **F2** wakes it and **F3** feeds it the conclusion; it reacts (spawns the next stacked PR). Claude:
  agent-owned watcher → native re-invoke. Codex: Orchestra-owned merge-watch → send-keys wake. The
  orchestrator **stays chattable** throughout. → UC1 (parallel discussions), UC2 (stacked-PR DAG).
- **B — push.** Something *else* (a human, another card) enqueues to **F3**; delivered at the agent's next
  boundary (**F2** if idle). → `send`, queue-a-command, handoff-in, fork-come-back to a *passive* parent.

```mermaid
sequenceDiagram
    participant Ag as Orchestrator agent
    participant O as orchestrad (merge-watch + inbox)
    participant Ch as Child card / PR
    Ag->>O: spawn stack head (MCP) + background `orchestra wait`
    Note over Ag: turn ends — stays chattable
    Ch->>O: concludes (merged to main)
    O->>O: detect via real card state (not git ancestry → no 0-commit false positive)
    alt wakeTransport == nativeReinvoke (Claude)
        O-->>Ag: `orchestra wait` exits → harness re-invokes in-session
    else sendKeys (Codex)
        O->>O: idle? composer-empty? (detect-and-defer)
        O-->>Ag: send-keys nudge → turn starts
    end
    Ag->>O: Stop-hook drains inbox (F3) → "PR A1 done"
    Ag->>O: spawn next-in-stack (A2 off A1's branch)
```

### 8.3 The desired goals, built from F1 · F2 · F3

| Goal | Forward | Come-back / delivery |
|---|---|---|
| **Handoff → new card** | spawn (start, seed) | — |
| **Handoff → clean context (same card)** | **F1** (resume-in-card, handoff = seed) | — |
| **Fork-out** | spawn (start, seed = parent slice) | — |
| **Fork come-back** | — | parent active → **F3**; parent idle → **F2 + F3** |
| **Fan-out** | batch-spawn (start) | — |
| **Fan-out DAG step** (reactive) | agent spawns next-in-stack | watcher concludes → **F2 + F3** → react (pattern A) |
| **Send** (human/agent → card) | — | **F3** (+ **F2** if idle) |
| **Queue a command** | — | **F3** (drained at next stop) |
| **Handoff-in** (into a running receiver) | — | **F3** (+ **F2** if idle) |

Native subagents are **kept** (Claude `Task`, Codex `MultiAgentV2`) for **ephemeral in-context helpers**; the
skill draws the line — *branch-worthy* work (own worktree/board card) → `orchestra.spawn`; a throwaway
sub-step → native subagent.

### 8.4 Exposure & integration — how agents use these, how goals reach agents and users

Three surfaces over one shared F1/F2/F3 substrate:

- **Agent-facing (MCP tools + a skill).** Tools: `spawn`/`batch_spawn` (delegation), `wait` (background
  watcher for self-wake), `handoff`, `send`. The inbox read is **automatic** (the Stop-hook) — no tool. A
  **skill (Claude) / AGENTS.md block (Codex)** teaches the patterns: the card-vs-native-subagent line; the
  spawn→wait→react loop (*Claude*: background `orchestra wait`; *Codex*: spawn and end your turn, Orchestra
  wakes you); the stacked-PR DAG idiom (spawn head → wait → spawn next off its branch). This is the "agent
  does it automatically" path — its native fan-out competence, redirected onto real cards.
- **Orchestra-internal (invisible to both).** Stop-hook install; the send-keys wake + detect-and-defer
  guard; F1 kill+resume; the **merge-watch** event detection (reads real card/merge state, fixing the
  0-commit-ancestor false-positive seen in the proven session); the capability-keyed `wakeTransport`.
  **Merge-watch is a *subscriber*, not a detector (added 2026-07-01):** it consumes `OrchestraService`'s
  lifecycle event bus + a continuation keyed on the watch set (the `awaitResume` pattern); the service is
  the single authority that marks terminal state (telemetry `exited` / `reconcileLiveness` / `move`-to-Done).
  It keys on the **settled** state, so a crash **revived** (≤ `maxRevivals`) is **not** a conclusion.
  Multi fan-out: **one conclusion per child as each concludes** (not a barrier), and concurrent returns
  **coalesce in the inbox** into one drain — wake triggers, content is durable (F3), none lost.
- **Human-facing (board UI / CLI).** The *same goals* as explicit actions: **Handoff** a card (→ F1),
  **Fork** a card to discuss (→ spawn + auto-wired come-back), **Send**/queue a message to a card (→ F3),
  kick off a **Fan-out**, and **watch the board**.

**Dual-surface principle.** Each goal lives on **both** surfaces — an agent can drive it (MCP + skill) *or* a
human can (UI/CLI) — because both compile to the same F1/F2/F3. Most goals (handoff, fork, send, queue) are
first-class on both; **fan-out** is *agent-executed* (it decomposes and sequences) but *human-kicked-off*
("fan this out into a stacked PR") and *board-viewed*. So: handoff/fork/send/queue → card actions in the UI
**and** MCP tools; fan-out → a UI kickoff + the board, executed via the agent's skill; the inbox drain and
the wake are **never** user-facing (Orchestra plumbing).

### 8.5 Per-agent provision (consolidated)

| | Claude | Codex (v1) | upgrade ladder |
|---|---|---|---|
| **F1 resume-in-card** | `claude --resume` + SessionStart `additionalContext` | `codex exec resume <id> "…"` | — |
| **F2 wake** | **`nativeReinvoke`** (background `orchestra wait` → harness re-invoke) | **`sendKeys`** nudge + detect-and-defer (persistent TUI kept) | → app-server `turn/start` (`controlChannel`, needs viewer) → native monitor (#29922 / #28144) |
| **F3 push-inbox** | Stop hook `decision:block` + `additionalContext` (10k) | Stop hook `decision:block` + `reason` (`stop_hook_active`) | — |

This **unifies** with [[context-passing-topologies]]'s `pendingContext` channel: the inbox is
provider-agnostic; only `wakeTransport` (F2) is capability-keyed.

---

## 9. Transport & auth (D10, D11, D12)

```mermaid
flowchart TB
    subgraph Now["build now (native process-adapters)"]
      C["Claude: interactive TUI in tmux + hooks-push"]
      X["Codex: TUI in tmux + rollout-tail"]
    end
    subgraph Later["design-for, NOT built now"]
      Local["local-model adapter — tracked future<br/>(Codex --oss / Ollama / thin adapter)"]
      AS["Codex app-server — tracked future<br/>(clean idle-wake F2 via turn/start — Symphony pattern;<br/>also mid-turn interrupt; needs an Orchestra-built viewer)"]
      ACP["ACP — design reference only<br/>(NOT built — confirmed 2026-06-29)"]
    end
    Now --> Later
    classDef warn fill:#fee,stroke:#c33;
    class ACP warn
```

**Auth — the per-path reality (drives D10/D11):**

| Path | Claude (Anthropic) | Codex (OpenAI) |
|---|---|---|
| Native binary in a pane (TUI/exec) | ✅ subscription — "ordinary use" | ✅ subscription (reuses `~/.codex/auth.json`) |
| ACP bridge | ❌ **API key required** (rejects OAuth; ToS-barred) | ✅ subscription (`codex-acp` spawns the app-server) |
| App-server / SDK | ❌ SDK not permitted on subscription | ⚠️ app-server ✅ subscription · SDK/Responses ❌ key |
| Extract/reuse OAuth token | 🚫 bright-line ToS violation, enforced | 🚫 same |

Implications:
- **Native adapters are the core, and the *only* legal subscription path for Claude.** The **ACP adapter is
  not built** (confirmed 2026-06-29) — it's kept only as a *design reference* (handshake / event taxonomy /
  permission vocabulary); it would force API billing on Claude users and degrade Claude to 200K context on
  Max anyway. **Prefer Claude's interactive TUI over `claude -p`** (a paused June-2026 billing split singled
  out headless `-p`; interactive is carved out as first-party).
- **Codex's app-server is subscription-safe but not needed for v1** — the inbox (§8) covers steering, so v1
  runs the Codex **TUI in tmux + rollout-tail**. The app-server stays an *optional future* (only if you ever
  want true mid-turn interrupt); auth doesn't constrain it, so the path is open without cost to subscription
  users.
- **D12 — carry `authMode ∈ {subscription, apiKey}`** so the UI can offer API-key mode (sidesteps the ToS
  gray zone + the shared rate pools) and **warn that heavy parallel fan-out on one subscription seat** is
  the exact pattern both providers' anti-automation clauses target (discretionary enforcement; shared
  5-hour/weekly rate pools with no per-agent isolation). Surface rate-limit state where the adapter can
  read it (Codex app-server can; Claude via reported usage).

---

## 10. Claude vs Codex mapped onto the seam (the build sheet)

| Seam point | Claude Code adapter | Codex adapter (v1) |
|---|---|---|
| Launch | interactive `claude` TUI in tmux | `codex` TUI in tmux |
| Auth | native OAuth subscription (or API key) | native ChatGPT login (or API key) |
| Session id | `.seeded` (`--session-id`) — or discover | `.discovered` (read from rollout / first event) |
| Telemetry | `.hooksPush` (managed `--settings` → `_report`) | `.fileTail` (daemon tails rollout JSONL) |
| ctxPct | `.percent` (reported) | `.tokens` ÷ `model.contextWindow` (offline model table) |
| Seed (`additionalContext`) | `SessionStart` hook / `--append-system-prompt` | `AGENTS.md` write / `-c model_instructions_file` / hook |
| Read-only | L1+L1.5+L3 (`disallowedTools` + classifier + `denyWrite`) | `--sandbox read-only -a never` |
| Trust | `~/.claude.json hasTrustDialogAccepted` | `-c projects."<cwd>".trust_level="trusted"` / isolated `CODEX_HOME` |
| Config isolation | per-card `--settings` | per-card `CODEX_HOME=<card-dir>` + `--ignore-user-config` |
| Live delivery (F3 inbox) | `.stopHook` (`decision:block`+`additionalContext`, 10k) | `.stopHook` (`decision:block`+`reason`, `stop_hook_active`) |
| Wake idle (F2) | `nativeReinvoke` (bg `orchestra wait` → harness re-invoke) | `sendKeys` nudge + detect-and-defer (→ app-server later) |
| Resume | `claude --resume <id>` (fresh proc) | `codex resume <id>` / `codex exec resume` (fresh proc) |

---

## 11. What this changes in the existing designs

- **[[model-providers/index|axis 2]]** — this note *is* its L3 deepening (the seam, capabilities,
  telemetry strategies, registry, transport/auth). The index should point here.
- **[[agent-integration/index|axis 3]]** — `additionalContext` stays the keystone; the **report path
  generalizes** to the normalized-event seam (mapping resolved by `agentId`, push *or* tail). The
  `progress`/`note`/`link` verbs ride the same normalized bus.
- **[[context-passing-topologies]]** — the steering/merge-back model is **materially refined** here into
  **three core functions** (F1 resume-in-card / F2 wake / F3 push-inbox) with the goals (handoff/fork/fan-out/
  send/queue) composed from them. §5/§9 of that note should reference §8 here.
- **[[context-continuity/index|axis 6]]** — handoff delivery = the boundary-injector; the durable inbox is
  the `pendingContext` channel.
- **[[freeform-and-borrowed-cards/index|PR1/freeform]]** — the read-only barrier generalizes to the
  3-layer model + `readOnlyEnforcement` levels (§7); the shipped Claude 3-layer barrier is the
  `sandboxed` case.
- **Build order** — confirms the prior **Wave B (provider seam + CodexAdapter)**: do the seam refactor
  (normalized events, capability descriptor, discover-mode session id, registry-vendor, tail-telemetry)
  proven by a running Codex adapter, *before* the report-consuming/restart-shaped features.

---

## 12. Open questions to confirm or push back on

**Resolved 2026-06-29:**
1. ~~Read-only for no-OS-sandbox agents~~ → **`toolGatedOnly` + visible "weak RO" badge** (not
   Orchestra-wrapped). Moot for Claude/Codex (both `sandboxed`). (§7)
2. ~~Build an ACP adapter?~~ → **No.** Kept as a design reference only. (§9)
3. ~~Codex steering — TUI+send-keys vs app-server?~~ → **Refined into the three-function model (§8).** v1 =
   Codex TUI + rollout-tail; F3 push-inbox via Stop-hook; F2 wake via send-keys + detect-and-defer;
   app-server is the upgrade for a `controlChannel` wake. (§8)
5. ~~Stop-hook loop cap~~ → **Both agents expose `stop_hook_active`, neither auto-enforces it** (earlier note
   that Claude lacked it was wrong) → **Orchestra caps consecutive auto-injects** on both. (§8 F3)
9. ~~Replicate the Claude self-wake on Codex — send-keys vs kill+resume?~~ → **send-keys + F3, gated by
   detect-and-defer** (smaller race window than F1 relaunch, content always inbox-protected, keeps the
   persistent TUI). F1 (kill+resume) is reserved for *handoff*, not routine waking. The blocking-MCP `await`
   pull is **dropped** (source-verified: holds the turn, non-interactive, non-durable — fails "stay
   chattable"). (§8)
8. ~~Normalized event schema — ACP/AG-UI verbatim or native?~~ → **Thin Orchestra-native, *two-tier*.**
   `ControlEvent` (reliable: lifecycle + usage + approvals + session id) vs `ContentEvent` (best-effort:
   text/thinking/tool/plan + `raw` passthrough). Borrow ACP's tool-call-lifecycle + permission vocabulary
   and AG-UI's snapshot+delta+raw transport; adopt neither verbatim. **Content is coarse** (complete blocks,
   not streamed deltas) for v1 — the **vendor transcript file is the conversation's source of truth**; a live
   streaming view is a later detail-view render feature. **Approvals deferred** in the first Codex cut
   (read-only `-s read-only -a never` sidesteps `approvalRequested`). (§4, §6)

**Resolved 2026-07-01 (layered-plan grounding pass):**
6. ~~Model registry source~~ → **Per-adapter offline model table** (extends `Adapter.models()`), vendored
   in-repo + PR-updated. **No** models.dev/LiteLLM fetch, no separate `ModelRegistry` component — the app
   stays offline. (§6, D7)
- **Telemetry parse ownership** → parse is the **adapter's** (`adapter.parse`); the daemon owns only the
  transport (push/tail/scrape), keyed by `capabilities.telemetry`. (§6, D6)
- **Conclusion detection (MergeWatch)** → MergeWatch is a **subscriber** of `OrchestraService`'s lifecycle
  event bus (not a git-poller / per-card watcher); it keys on the **settled** terminal state (post
  liveness-reconcile), so a revived crash is not a conclusion. (§8)
- **Authority / SSOT split** → `OrchestraService` + `TaskStore` are authoritative for **lifecycle**
  (ControlEvent — adjudicated via seq-gate + liveness, state-authoritative not event-sourced); the **vendor
  transcript file** stays SSOT for **content** (ContentEvent). `OrchestraService` decomposes into
  action-ingress / event-ingress / event-egress / live-delivery+recovery. (§3, §6)

**All resolved (2026-07-01)** — no open questions remain:
4. **`authMode` UX** → **soft-warn only** on subscription-seat fan-out; **no** concurrency cap (E2 ships
   just the warning). (§9)
10. **Codex `controlChannel` wake** → **send-keys + detect-and-defer for v1** (C4); `codex app-server` +
    the Orchestra-built viewer it requires are **deferred** (drops the native TUI, a non-goal). Watch
    upstream **#29922** (agent-callable `monitor` tool) and **#28144** (durable `waiting`/wake) — either
    merging gives Codex a *native* self-wake; revisit then. (§8.5, §9)

---

## 13. Appendix

Full primary-source research (Codex/Claude/landscape capability sheets, the 14-system precedent survey,
the steering/agent-pull + MCP investigation, and the auth/ToS findings — all with citations) is in
[[agent-provider-research-appendix|the research appendix]].
