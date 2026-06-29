# 5. Command reference

Every action Orchestra exposes lives in **one place** — the `CommandRegistry`
(`Sources/OrchestraCore/Commands.swift`). The CLI dispatches to it, the MCP bridge generates one tool
per entry from it, and the app calls the same methods. This chapter is the canonical list, plus the
server-only built-in methods and the wire protocol.

A `ref` argument is any [card reference](03-data-model.md#identity-and-references): a short id, a full
UUID, or an `orchestra://task/<shortId>-<slug>` URI.

## Registry commands

| Command | Parameters | What it does |
|---------|------------|--------------|
| `list` | `col?` (`plan`/`impl`/`review`) | List cards, optionally filtered by column. Read-only; not logged to the activity feed (it would flood it). |
| `spawn` | `prompt` (required), `repo?`, `branch?`, `model?`, `col?` (`plan`/`impl`), `cwd?`, `access?` (`readWrite`/`readOnly`), `scratch?` (bool) | Spawn a new agent. Worktree mode (`repo`+`branch`), freeform mode (`cwd`), or scratch mode (`scratch:true`). Auto-titles from the prompt; status starts `waiting` if provisional, else `running`. |
| `move` | `ref` (required), `col` (required: `plan`/`impl`/`review`) | Move a card to a column (auto-orders within it). |
| `send` | `ref` (required), `message` (required) | Send text to the agent (typed into its tmux window). |
| `status` | `ref` (required) | Return the card plus its derived tmux liveness. |
| `archive` | `ref` (required) | Finish a card: kill the session, clean the run dir per origin, set `done`/`archived`. |
| `restart` | `ref` (required) | Fresh blank session in the same worktree (new session id; no prompt re-handed). |
| `resume` | `ref` (required) | Re-attempt `claude --resume` of the card's existing session. |
| `shell` | `ref` (required) | Open a shell window in the card's `cwd`; returns the tmux target to attach to. |
| `inspect` | `ref` (required) | Open a throwaway **read-only** `claude` in the card's `cwd` (locked-down sandbox, edit tools denied, no hooks). |
| `closeShell` | `ref` (required), `window` (required, e.g. `shell-1`) | Close a shell window opened via `shell`. |
| `exec` | `ref` (required), `cmd` (required), `timeout?` (seconds) | Run one shell command in the card's `cwd` via `/bin/sh -c`; returns stdout/stderr/exit. Worktree cards are allowlist-gated; borrowed/scratch are sandbox-trusted. Default timeout 120 s. |
| `sessions` | `ref` (required) | Debug handles: every tmux target (socket/session/windows with attach lines), the agent-native session id, transcript path, prior ids, and the resume argv. |
| `batch-spawn` | `tasks` (required: array of `{prompt, repo, branch, model?, col?}`) | Spawn many agents at once; failed entries are reported, the rest still spawn. |

### Notes on key commands

- **`spawn` picks the mode from its params.** `scratch:true` → a scratch card; a `cwd` → a borrowed/
  freeform card; `repo`+`branch` → a worktree card. `access:"readOnly"` makes any of them read-only.
- **`archive` cleans up by origin.** Worktree: `git worktree remove` (kept if dirty, and only if no
  other live worktree card shares it). Scratch: unconditional `rm -rf` (double-gated). Borrowed: nothing
  is deleted.
- **`exec` vs `shell`.** `exec` is a one-shot non-interactive command with a captured result; `shell`
  opens an interactive window you attach a terminal to. `inspect` is `shell` + a read-only agent.

## Server-only built-in methods

These are handled directly by `ControlServer` and are **not** registry commands (so today they are
visible to the app but not auto-exposed as MCP tools — unifying this is part of
[Roadmap axis 3](10-roadmap.md)):

| Method | Purpose |
|--------|---------|
| `ping` | Liveness check. |
| `version` | Daemon version. |
| `subscribe` | Register the connection for the event stream; replays the recent-activity ring buffer. |
| `getConfig` / `setConfig` | Read / patch the daemon `Config` (re-derives the resolver + worktree manager). |
| `models` | List available models for an agent. |
| `archivedList` | The archived (Done) cards, newest first. |
| `openInZed` | Open a card's worktree in Zed, with a branch-vs-base multi-file diff. |
| `report` | The internal endpoint the agent's `_report` helper POSTs `StatusReport`s to. |

## The wire protocol

Clients speak **newline-delimited JSON-RPC 2.0** over the unix-domain socket (default
`~/Library/Application Support/Orchestra/orchestrad.sock`, override `$ORCHESTRA_SOCK`):

```jsonc
// request  (id omitted ⇒ notification, no reply)
{ "jsonrpc": "2.0", "id": 1, "method": "spawn", "params": { … }, "source": "cli" }

// response
{ "jsonrpc": "2.0", "id": 1, "result": { … } }
{ "jsonrpc": "2.0", "id": 1, "error": { "code": -32000, "message": "…" } }

// server → client event (after subscribe)
{ "jsonrpc": "2.0", "method": "event", "params": { "taskUpserted": { … } } }
```

`source` (`app`/`cli`/`mcp`/`agent`) is how the activity feed attributes each action. Error codes:
`-32700` parse error, `-32601` method not found, `-32000` internal/typed `OrchestraError`. Dates are
ISO-8601 on the wire.

For how the CLI and MCP turn these into commands you can run, see [CLI & MCP](06-clients-cli-mcp.md).
