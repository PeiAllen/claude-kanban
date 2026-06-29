---
project: claude-kanban
feature: agent-provider-interface
type: research-appendix
status: reference
created: 2026-06-29
updated: 2026-06-29
related:
  - "[[agent-provider-interface|Agent-Agnostic Provider Interface (design)]]"
---

# Agent-Provider Interface — Research Appendix

> Primary-source grounding for [[agent-provider-interface|the provider-interface design]]. Distilled from
> a multi-pass investigation (2026-06-29) across capability sheets, a 14-system precedent survey, the
> steering/agent-pull problem, MCP, and auth/ToS. **Everything here is version-sensitive** (CLIs, specs,
> and billing terms move fast) — re-verify a cited fact before betting the implementation on it. Dates are
> "as researched, late June 2026."

---

## 1. Capability sheets — Claude Code, Codex, the landscape

### Claude Code CLI (dimensions A–L)
- **Session id (B):** caller-**seeds** `--session-id <uuid>`; transcript `~/.claude/projects/<cwd-slug>/<id>.jsonl`.
- **Resume (C):** `--resume/-r <id>`, `--continue/-c`, `--fork-session`; full history restored.
- **Context seed (D):** `--append-system-prompt(-file)`, `SessionStart` hook `additionalContext`, `CLAUDE.md`, `--mcp-config`. No non-TTY mid-turn injection.
- **Telemetry (E):** hooks (`SessionStart/End`, `Pre/PostToolUse`, `UserPromptSubmit`, `Notification`, `Stop`) + `statusLine` + `--output-format stream-json`. No built-in agent API; pull via hooks or tail transcript.
- **Structured (F):** `--output-format json|stream-json`, `--json-schema`. **Permissions (G):** `--permission-mode {default,acceptEdits,plan,…}`, `--allowedTools/--disallowedTools`, sandbox via `--settings`. **Model (H):** `--model`; context sizes not CLI-discoverable. **Config (I):** `--settings` (precedence: managed>cmdline>local>project>user). **Trust (J):** `hasTrustDialogAccepted`. **Steer (L):** `-p --continue/--resume` (new turn); no socket/API.
- Distinctive: **caller-seeded id + hooks side-channel + sandbox-isolates-Bash independent of permission modes.**
- Sources: https://code.claude.com/docs/en/hooks · /mcp · /settings · /cli-reference (June 2026).

### OpenAI Codex CLI (dimensions A–L)
- **Invoke (A):** `codex` TUI · `codex exec` headless · `codex app-server` (JSON-RPC). 
- **Session id (B):** **no caller-supplied id** — UUID auto-generated; discover via `thread.started` (`--json`) or rollout filename `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` (contains token usage).
- **Resume (C):** `codex resume <id>/--last`, `codex exec resume`, `codex fork`; app-server `thread/resume`; full replay.
- **Seed (D):** `AGENTS.md`, `model_instructions_file`, `-c`, stdin; mid-session via hooks `additionalContext` or app-server `turn/start`/`turn/steer`.
- **Telemetry (E):** `--json` event stream (`turn.completed.usage` = tokens) + rollout JSONL; hooks for control (no usage in hook payload); `notify` = turn-complete ping. **Structured (F):** `--json`/`--experimental-json`, `-o`, `--output-schema`. **Permissions (G):** `-s read-only|workspace-write|danger-full-access` × `-a untrusted|on-request|never`; native OS sandbox; RO = `-s read-only -a never`. **Model (H):** `-m`; window via `model_context_window`. **Config (I):** `-c key=value`, `--profile`, `--ignore-user-config` + `CODEX_HOME`. **Trust (J):** one-time prompt, independent of `--yolo`; pre-grant `trust_level="trusted"`. **Steer (L):** `exec` one-shot; live steering only via app-server `turn/steer`/`thread/inject_items`.
- Differs in kind from Claude: **discovered (not seeded) id · usage lives in the event stream/rollout, not hooks · live steering needs the app-server.**
- Sources: https://developers.openai.com/codex/{cli/reference,noninteractive,cli/features,config-reference,config-advanced,hooks,app-server,sdk} (June 2026).

### Landscape (N=6: Aider, Gemini CLI, opencode, Amp, Goose, Cursor CLI)
- **Common denominators (safe to require):** a headless one-shot invocation; resume-by-discovered-id; `AGENTS.md`-class seed file; model-by-string (Amp excepted); a JSON/stream-json event mode (Aider excepted); a "don't prompt me" autonomy knob; MCP (Aider excepted); per-invocation config isolation via env/file.
- **Axes of variation (must be capability-flagged):** session-id ownership · **steering model** {http-server, stdin-stream, resume-only, acp} · telemetry transport {SSE, OTLP, per-proc stream-json, scrape} · token-usage present-vs-absent (Cursor/Aider absent) · OS-sandbox present-vs-absent (opencode/Amp/Goose/Aider absent) · structured-output present-vs-absent · model-selection-vs-hidden (Amp) · MCP native-vs-none · trust gate.
- **Server-API (not process):** opencode (`serve` + OpenAPI + SSE `/event`), Goose (`goosed`). Two adapter shapes: **process** vs **server**.
- Sources: aider.chat/docs · github.com/google-gemini/gemini-cli · opencode.ai/docs · ampcode.com/manual · block.github.io/goose (now goose-docs.ai) · cursor.com/docs/cli.

### Orchestra current seam audit (Claude-isms classified)
- **Already behind the adapter (fine):** argv construction, transcript-path layout, `discover`, trust mirroring, model catalog.
- **Structural Claude assumptions (must change):** (1) **seeded session id** set pre-launch; (2) **hooks-as-single-`--settings`** reporting; (3) **`~/.claude` transcript = resumability oracle**; (4) **ctxPct only from Claude's `context_window.used_percentage`** (no `AgentModel.contextWindow`).
- 7 required seam changes enumerated in the audit → folded into the design's D3–D7.

---

## 2. Steering / agent-pull / MCP

### Claude Code — agent-pull
- **Stop hook (A):** `decision:"block"` (or exit 2) prevents stop + can inject `additionalContext` and force continuation; **no documented loop guard** (`stop_hook_active` not present) → Orchestra must cap. `SubagentStop` too.
- **SessionStart/UserPromptSubmit (B):** inject `additionalContext`; fire every resume / every prompt.
- **MCP pull (C):** tool calls work; **tool-exec timeout undocumented** (`MCP_TOOL_TIMEOUT`; default reportedly ~28h); progress-keepalive best-effort (open bugs). **Elicitation/sampling/subscriptions (D): NOT implemented** in Claude Code.
- Ranked: **#1 Stop-hook + orchestrator block-limit** · #2 UserPromptSubmit · #3 Channels (experimental).
- Sources: code.claude.com/docs/en/{hooks,hooks-guide,mcp,channels-reference,agent-sdk/*}.

### Codex — agent-pull
- **Stop hook (A): SUPPORTED** — `{"decision":"block","reason":"…"}` → *"Codex continues and creates a new continuation prompt using your reason as the prompt text."* **Loop guard exists** (`stop_hook_active` in hook input). Stop uses `reason` (not `additionalContext`).
- **B:** `SessionStart` (startup/resume/clear/compact) + `UserPromptSubmit` inject `additionalContext`. **C:** MCP `tool_timeout_sec` default 60s (raise it). **D:** **elicitation SUPPORTED v0.120.0 (2026-04-11)** but during-tool-flow only; resources read-only; **subscriptions/sampling NOT.** **E:** `notify` on `agent-turn-complete` (observe-only). **G:** app-server `thread/inject_items` = clean queue-for-next-turn (app-server only).
- Ranked: **#1 Stop-hook inbox-drain** (busy parent) + `notify`/`turn-completed` wake (idle parent) · #2 app-server `inject_items` · #3 long-poll MCP tool.
- Sources: developers.openai.com/codex/{hooks,app-server,config-reference,config-advanced,mcp}; PR #11067; issue #6992.

### MCP as the cross-agent channel
- **Current finalized spec `2025-11-25`**; `2026-07-28` is an RC that reworks elicitation/sampling into "Multi-Round-Trip" and moves Tasks to an extension — **expect churn**.
- **The only primitive both Claude Code AND Codex support today is `tools/call` (+ resource read).** Elicitation = Codex-only; sampling = neither; resource-subscriptions auto-act = neither; Tasks = neither.
- Best cross-agent pattern: **blocking/long-poll `check_inbox`/`await_inbox` tool + server-side queue**, the agent instructed to call it. Timeouts: Claude `MCP_TOOL_TIMEOUT` (huge default), Codex `tool_timeout_sec` 60s (raise + progress keepalive best-effort).
- **MCP's inherent limit:** it can deliver context but **cannot force the agent to consume it** — always depends on the agent calling the tool. (Stop-hook *can* force consumption → why it ranks above MCP.)
- Sources: modelcontextprotocol.io/specification/2025-11-25 (tools, elicitation, sampling, resources, progress, cancellation, tasks); apify/mcp-client-capabilities (2026-02-02); Claude #2799/#470/#424; Codex PR #17043, #4929.

---

## 3. Precedent survey (14 systems)

### Protocols
- **ACP (Zed) — agentclientprotocol.com.** LSP-for-agents; JSON-RPC/stdio. `initialize` (capability handshake), `session/new` (returns id — discovered), `session/load`/`resume`, `session/prompt` (blocking, `stopReason`), `session/update` (typed stream: `agent_message_chunk`, `tool_call`, `tool_call_update`, `plan`, `usage_update`), `session/cancel`, `session/request_permission` (`PermissionOption{allow_once/always, reject_once/always}`). **No async steering, no parallelism, no lineage; client-as-executor (`fs/*`, `terminal/*`).** Steal handshake+events+permission vocab; don't adopt the blocking/executor model. Sources: agentclientprotocol.com; zed.dev/docs/ai/external-agents.
- **A2A (Google→Linux Foundation) — a2a-protocol.org.** Agent↔agent. **AgentCard** (capability descriptor), **Task** state machine (`submitted→working→input-required→completed/failed/canceled`), **Message/Part/Artifact** (Artifact = deliverable, streams `append:true`), SSE `TaskStatusUpdateEvent`/`TaskArtifactUpdateEvent`, push-notification webhooks.
- **AG-UI (CopilotKit) — ag-ui-protocol/ag-ui.** Agent↔frontend; 17 typed events; **STATE_SNAPSHOT + STATE_DELTA (RFC-6902 JSON-Patch)** — the board-feed pattern.
- **MCP** — agent↔tools (above).

### Multi-agent coding orchestrators
- **Omnigent (Databricks, omnigent-ai/omnigent, alpha Jun 2026)** — closest analog. Contract *"messages+files in → token-stream+tool-calls out"*, per-agent `executor.harness` selector, native CLIs over **tmux/PTY**. `attach <id>`, `run --fork <id>`, sub-agents as a tool type, **contextual-function policies** (server→agent→session: `ask_on_os_tools`, `max_tool_calls_per_session`, `cost_budget`), per-OS sandbox. *Weak on structured telemetry (no MLflow tracing documented).*
- **Vibe Kanban (BloopAI)** — Rust trait `StandardCodingAgentExecutor` (`spawn`/`spawn_follow_up`/`normalize_logs`) behind enum; **3 transports (Claude stream-json+stdio, Codex app-server JSON-RPC, ACP) normalized into one `NormalizedEntry`**; session id **discovered** (NULL until parsed); `PermissionPolicy{Auto,Supervised,Plan}` mapped per-agent; queue-until-exit steering; turn-done from **process exit**; `parent_workspace_id` + squash-merge.
- **claude-squad / uzi** — opaque command string adapters; **PTY scrape + SHA-256(buffer) + prompt-signature substrings** for status; `send-keys` steering (uzi adds broadcast); auto-yes by scraping+Enter.
- **OpenHands** — three registries (**Agent policy / LLM via litellm / Runtime**); **EventStream** (one append-only typed stream = memory+telemetry+UI); `AgentState` machine; steering = `MessageAction` at next `_step()`; **delegation** = `AgentDelegateAction`→child controller→`AgentDelegateObservation`.
- **opencode** — provider abstraction = **Vercel AI SDK package + models.dev**; HTTP+SSE; `ses_…`; `/session/:id/fork`; `prompt_async`; allow/ask/deny globs.
- **Crystal** — `AbstractCliManager` (~5 methods: `buildCommandArgs`, `parseCliOutput→events`, `continuePanel`, …) — cleanest minimal-interface spec; node-pty capture.
- **Conductor / Sculptor / container-use** — bundled vendor CLIs / container-per-agent / MCP-server-per-agent; message-queue / live-file-sync / `cu merge` steering.

### Cross-tool convergence (strong signals)
1. Wrap the real CLI, never reimplement. 2. One worktree per unit of work (uncapped concurrency). 3. Minimal new-agent interface ≈ build-command + parse-to-events + resume. 4. Two telemetry strategies only (structured-parse vs PTY-scrape). 5. Turn-done out-of-band. 6. Session ids discovered, resume = fresh process. 7. Steering = queue-until-boundary. 8. Permissions normalized to ~3 levels + per-backend mapping + `approval_id`. 9. Merge-back = git branch + parent pointer (no in-memory result bus).
- Model registries: **models.dev/api.json** (`limit.context`, capability booleans), **LiteLLM** `model_prices_and_context_window.json`. Provider-adapter versioning: **Vercel AI SDK** `LanguageModelV2/V4` + `providerOptions`.
- Handoff convergence (OpenAI Agents SDK transfer-as-tool, LangGraph `Command.goto`, Omnigent sub-agent-as-tool, A2A Task delegation): **target id + explicit context slice** — validates the one-`additionalContext`-seed plan; LangGraph's warning: make the slice explicit, never a full-history dump.

---

## 4. Auth & ToS (the landmines)

### Claude (Anthropic) — strict
- **ACP/SDK reject subscription OAuth** (adapter wants `sk-ant-api03-…`, subscription token is `sk-ant-oat01-…`) and **ToS bars routing subscription creds through third-party tools / the Agent SDK** (code.claude.com/docs/en/legal-and-compliance).
- **Native binary in a pane = subscription works** ("ordinary use of Claude Code"). **Never extract the OAuth token** — token-lifting got OpenClaw/OpenCode/Roo/Goose blocked (Jan 2026; The Register 2026-02-20).
- **Paused June-2026 billing split** would move `claude -p` headless + ACP + SDK onto separate API-rate credits; **interactive TUI carved out as first-party** → prefer the TUI. Paused 2026-06-15/16; future uncertain. ACP also caps context to 200K on Max (Zed #51648).
- Sources: code.claude.com/docs/en/legal-and-compliance; zed.dev/blog/anthropic-subscription-changes; claude-code-acp #29; openclaw #53456; anthropic.com/legal/aup.

### Codex (OpenAI) — looser
- **Subscription (ChatGPT login) works on native CLI/`exec`, `app-server`, AND `codex-acp`** (all reuse `~/.codex/auth.json` / spawn the binary). **Only the SDK/Responses API forces a key.**
- The constraint is **ToS gray-zone** (OpenAI: "the right way to authenticate automation is with an API key"; anti-flooding clauses) + **shared 5-hour rate window across all agents** (no per-agent isolation; Plus exhausts fast). Headless OAuth is **browser-bound** (`localhost:1455`; seed `auth.json` / `--device-auth` beta).
- Sources: developers.openai.com/codex/{auth,app-server,auth/ci-cd-auth,pricing}; help.openai.com/articles/11369540; openai.com/policies; codex #6154/#2733/#3820; agentclientprotocol/codex-acp.

### Cross-provider rule
**Drive the official binary (or its own server) and let it authenticate; never reimplement the API client or reuse the login token.** Keeps subscriptions legal on both; matches all precedent orchestrators. Carry `authMode ∈ {subscription, apiKey}`; warn on heavy parallel subscription fan-out.
