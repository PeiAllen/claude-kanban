---
project: claude-kanban
feature: agent-provider-interface
type: design-note
status: draft-for-review
created: 2026-06-29
updated: 2026-06-29
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
| D1 | Adapter shape | **Process-adapter over PTY/tmux** (not a server/HTTP adapter, not an in-proc SDK) | Recommend |
| D2 | How a backend is added | **Runtime registry of ~5-method adapters** (not a recompiled enum) | Recommend |
| D3 | Output handling | **One normalized event type** every adapter parses into | Recommend |
| D4 | Variation handling | **Capability descriptor** (flags) + per-adapter native mapping | Recommend |
| D5 | Session identity | **Discover-by-default** (store the id the backend emits); seeding is an optimization | Recommend |
| D6 | Telemetry | **Structured-stream parse** where available (Claude hooks-push, Codex rollout-tail), **PTY-scrape** fallback; turn-done detected **out-of-band** | Recommend |
| D7 | Context window / cost | **Vendor a model registry** (models.dev / LiteLLM JSON) → `contextWindow` + capability flags | Recommend |
| D8 | Permissions | **3 orthogonal layers** (tool-gating · approval-policy · OS-sandbox); read-only is a **preset** | **Confirmed** — no-sandbox agents → `toolGatedOnly` + a visible **weak-RO badge** |
| D9 | Steering / merge-back | **All input to a running agent — user follow-ups AND merge-back — rides the durable inbox**, drained at the turn boundary by the capability-keyed injector; `send-keys` only for the idle-wake | **Confirmed** |
| D10 | Transport | **Native Claude (TUI+hooks) + native Codex (TUI+rollout-tail) only.** ACP adapter **not built** (design reference only); Codex `app-server` **not needed for v1** (the inbox covers steering) | **Confirmed** |
| D11 | Auth invariant | **Drive the binary, never the token/API client** | **Hard constraint** |
| D12 | Auth modes | Carry `authMode ∈ {subscription, apiKey}`; warn on heavy parallel subscription use | Recommend |

The **only true constraint** is D11 (a ToS bright line); the rest are recommendations. Items confirmed
2026-06-29 are marked **Confirmed**; remaining open items are in §12.

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

---

## 4. The adapter seam

A backend is admitted by implementing a **small adapter** registered by id (D2). The interface converges
(across Crystal's `AbstractCliManager` and Vibe Kanban's `StandardCodingAgentExecutor`) on ~5
responsibilities:

```mermaid
classDiagram
    class Adapter {
      +id String
      +capabilities AdapterCapabilities
      +buildLaunch(ctx) LaunchSpec
      +parse(source) NormalizedEvent_list
      +resumeHandle(task) Handle
      +prepareToLaunch(ctx) void
    }
    class AdapterCapabilities {
      +sessionId  seeded_or_discovered
      +telemetry  hooksPush_fileTail_ptyScrape
      +contextUsage  percent_tokens_none
      +steering  stopHook_resumeSeed_mcpInbox_sendKeys
      +readOnlyEnforcement  sandboxed_toolGated_orchestraSandboxed
      +osSandbox  native_or_none
      +authMode  subscription_or_apiKey
    }
    class NormalizedEvent {
      +assistantText
      +thinking
      +toolUse_with_status
      +tokenUsage
      +turnEnded
      +needsApproval_with_id
      +sessionId_discovered
    }
    class LaunchSpec {
      +argv String_list
      +env Map
      +files Map
    }
    Adapter --> AdapterCapabilities
    Adapter --> NormalizedEvent
    Adapter --> LaunchSpec
```

> `buildLaunch` returns argv+env+files and covers start/resume/read-only/seed; `parse` is **the
> normalization core**; `resumeHandle` returns the discovered id (resume = fresh process);
> `prepareToLaunch` does trust-grant + isolated config home + the read-only recipe. `AdapterCapabilities`
> values are enums (e.g. `sessionId ∈ {seeded, discovered}`); `NormalizedEvent` is a sum type
> (`toolUse` carries a status, `needsApproval` an id).

**D3 — the normalization core.** The single most important move (how every multi-CLI tool abstracts
Claude-vs-Codex): they do **not** unify wire protocols — each adapter's `parse()` collapses its agent's
output into **one `NormalizedEvent` type**. Claude stream-json/hooks, Codex rollout JSONL, ACP
`session/update`, opencode SSE — all become the same `{assistantText | toolUse{status} | tokenUsage |
turnEnded | needsApproval | …}`. The board, status logic, and inbox only ever see normalized events.

**D4 — capability descriptor.** Everything that varies in *kind* is a flag the adapter advertises
(modeled on ACP's `initialize` handshake and A2A's AgentCard). The daemon and UI **degrade on flags, never
branch on provider identity.** This is what admits Codex without `if claude`.

**D2 — registry, not enum.** Keep `AgentRegistry` keyed by id; resolve the adapter from `Task.agentId` at
every op (already the case). A new provider = a new adapter file + a registry entry.

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
- **D7 — model registry.** Drop hand-maintained context windows; vendor `models.dev/api.json` (or
  LiteLLM's `model_prices_and_context_window.json`). Use `limit.context` as the `ctxPct` denominator and
  the `tool_call/reasoning/vision` booleans as per-model capability flags. (Replaces the absent
  `AgentModel.contextWindow`.)

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
    Pol["abstract AccessPolicy<br/>{readOnly, readWrite, (autonomous|supervised|plan)}"] --> Map2["adapter maps policy → native mechanism"]
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
reject_always}` vocabulary — so the board's approval UI is provider-agnostic.

---

## 8. Steering & merge-back (D9)

The field converged on **queue-until-turn-boundary**, not mid-turn injection. So Orchestra's model is: a
**durable per-card inbox**, drained at the agent's next natural boundary, where the **delivery mechanism is
a capability** (`capabilities.steering`). The only synchronous path is approvals.

> **Decision (2026-06-29) — one inbox for everything.** *All* input to a running agent rides this inbox: a
> user-typed follow-up and a fork merge-back are the **same primitive** — a message queued for the card,
> drained at the next turn boundary by the Stop-hook injector. Consequence: **Codex needs neither the
> app-server nor fragile send-keys-into-a-busy-TUI for v1.** The only residual `send-keys` use is the
> **idle-wake** — typing a queued message into an already-*ready* prompt to start a turn (reliable, not a
> race). The single thing this defers is *true mid-turn interrupt* (a message lands at the next boundary,
> not instantly) — the industry-standard behavior, and exactly where Codex `app-server turn/steer` would
> slot in later if ever wanted. This unifies steering across Claude and Codex on one mechanism.

```mermaid
sequenceDiagram
    participant Fork as Fork (child card)
    participant D as orchestrad (inbox)
    participant Inj as Boundary-injector (capability-keyed)
    participant Parent as Parent agent (live)
    Fork->>D: concludes → push {summary, artifacts-in-git} to parent.inbox
    Note over Parent: busy (mid-turn) — nothing forced
    Parent->>Parent: turn ends (natural boundary)
    alt capabilities.steering == stopHook
        Parent->>Inj: Stop hook fires
        Inj->>D: drain inbox
        Inj-->>Parent: decision:block + additionalContext (Claude) / reason (Codex) → CONTINUE
    else resumeSeed
        D-->>Parent: inject inbox as additionalContext on next resume/follow-up
    else mcpInbox
        Parent->>D: agent calls check_inbox()/await_inbox() (it was told to)
        D-->>Parent: returns pending results
    else sendKeys (fallback)
        Inj-->>Parent: type at detected-idle boundary (fragile)
    end
    Note over Parent,D: idle parent (no turn ending) → one wake (notify/idle-signal → single nudge)
```

- **Stop-hook drain is the primary for Claude+Codex** — at the turn boundary an Orchestra hook drains the
  inbox and **forces continuation with no steering and no restart** (Claude via `decision:block` +
  `additionalContext`; Codex via `decision:block` + `reason`, which *has* a `stop_hook_active` loop guard;
  Claude lacks one, so Orchestra caps consecutive injects).
- **MCP `check_inbox`/`await_inbox`** is the portable cross-agent layer (tools are the only MCP primitive
  both clients support today) — but it requires the agent to *choose* to call it.
- **send-keys** is no longer a steering path for busy agents — it shrinks to the **idle-wake** only:
  delivering a queued message to an *idle* agent at a ready prompt (Stop won't fire when no turn is
  running, so detect idle via Codex `notify` / Claude idle-signal and type the message to start a turn).
  This is the *safe* form of send-keys; the fragile busy-TUI race is eliminated by the inbox.
- **Artifacts ride git, conclusions ride the inbox.** Every precedent keeps the durable result in a branch
  (+ a `parentCardId` pointer); the inbox carries only the lightweight "a fork concluded: …" — your maxim
  *handoff carries intent, artifacts carry facts*, confirmed by Omnigent/A2A/OpenHands/LangGraph.

This **unifies** the steering seam with [[context-passing-topologies]]'s `pendingContext` inbox: the inbox
is provider-agnostic; the injector is capability-keyed.

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
      AS["Codex app-server — optional future<br/>(only for true mid-turn interrupt)"]
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
| ctxPct | `.percent` (reported) | `.tokens` ÷ `model.contextWindow` (registry) |
| Seed (`additionalContext`) | `SessionStart` hook / `--append-system-prompt` | `AGENTS.md` write / `-c model_instructions_file` / hook |
| Read-only | L1+L1.5+L3 (`disallowedTools` + classifier + `denyWrite`) | `--sandbox read-only -a never` |
| Trust | `~/.claude.json hasTrustDialogAccepted` | `-c projects."<cwd>".trust_level="trusted"` / isolated `CODEX_HOME` |
| Config isolation | per-card `--settings` | per-card `CODEX_HOME=<card-dir>` + `--ignore-user-config` |
| Steering / merge-back | `.stopHook` (`decision:block`+`additionalContext`) | `.stopHook` (`decision:block`+`reason`, has loop guard) |
| Resume | `claude --resume <id>` (fresh proc) | `codex resume <id>` / `codex exec resume` (fresh proc) |

---

## 11. What this changes in the existing designs

- **[[model-providers/index|axis 2]]** — this note *is* its L3 deepening (the seam, capabilities,
  telemetry strategies, registry, transport/auth). The index should point here.
- **[[agent-integration/index|axis 3]]** — `additionalContext` stays the keystone; the **report path
  generalizes** to the normalized-event seam (mapping resolved by `agentId`, push *or* tail). The
  `progress`/`note`/`link` verbs ride the same normalized bus.
- **[[context-passing-topologies]]** — the steering/merge-back model is **materially refined** here:
  queue-until-boundary + capability-keyed injector + the idle-wake gap. §5/§9 of that note should reference
  §8 here.
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
3. ~~Codex steering — TUI+send-keys vs app-server?~~ → **Neither — the inbox covers it.** v1 = Codex TUI +
   rollout-tail; all input rides the inbox/Stop-hook; send-keys only for idle-wake; app-server deferred. (§8)

**Still open:**
4. **`authMode` UX** — how hard to warn/limit parallel fan-out on a subscription seat? Soft warning vs a
   configurable concurrency cap per auth mode. (§9)
5. **Stop-hook loop cap** (Claude has no `stop_hook_active`) — max consecutive auto-inject before Orchestra
   forces a real stop? (§8)
6. **Model registry source** — models.dev vs LiteLLM vs both (fallback)? Vendor-at-build vs fetch-and-cache?
   (§6)
7. **Normalized event schema** — adopt ACP `session/update` sub-types / AG-UI's 17 events verbatim, or a
   thinner Orchestra-native set? *(You're reviewing this — left pending.)* (§4, §6)

---

## 13. Appendix

Full primary-source research (Codex/Claude/landscape capability sheets, the 14-system precedent survey,
the steering/agent-pull + MCP investigation, and the auth/ToS findings — all with citations) is in
[[agent-provider-research-appendix|the research appendix]].
