import Foundation

/// The canonical command vocabulary — name + summary + JSON-schema params — with NO execution.
/// The daemon binds handlers to these in `CommandRegistry` (OrchestraCore); the MCP bridge builds
/// tools from them; a phone client builds/validates requests from them. Single source of truth for
/// command *shape* (the execution half lives in `OrchestraCore/CommandRegistry.swift`).
/// Who a command is exposed to. `.all` = the daemon dispatches it AND the MCP bridge advertises it as a
/// tool to agents. `.appOnly` = the daemon still dispatches it (the app uses it), but the MCP bridge does
/// NOT advertise it — an agent's normal tool-use can't reach it. Used for the human-only primitives that
/// must not be agent-drivable: `send-keys` (an agent could Enter-approve its own permission gate) and
/// `capture` — the same boundary the app-only `listDir`/takeover methods keep by not being catalog commands.
public enum CommandExposure: Sendable, Equatable { case all, appOnly }

public struct CommandSchema: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let params: JSONValue
    public let exposure: CommandExposure
    public init(name: String, summary: String, params: JSONValue, exposure: CommandExposure = .all) {
        self.name = name; self.summary = summary; self.params = params; self.exposure = exposure
    }
}

public enum CommandCatalog {
    /// The commands the MCP bridge advertises as tools to agents — the `.appOnly` primitives (`send-keys`,
    /// `capture`) are withheld so an agent's tool-use can't drive the human-only gates. See `CommandExposure`.
    public static var mcpExposed: [CommandSchema] { all.filter { $0.exposure == .all } }

    // The canonical set. name/summary/params are copied verbatim from the original Commands.swift;
    // the handler bodies live alongside in OrchestraCore/CommandRegistry.swift, paired by name.
    public static let all: [CommandSchema] = [
        CommandSchema(name: "list", summary: "List cards (optionally by column).",
                      params: schema(["col": colProp()], required: [])),

        CommandSchema(name: "spawn",
                      summary: "Spawn a new agent. Only `prompt` is free text — no title/desc.",
                      params: schema([
                          "prompt": strProp("Initial prompt — what the agent should start working on"),
                          "repo": strProp("Repository root (allowlisted). Omit for a freeform (cwd) card."),
                          "branch": strProp("Working branch. Omit for a freeform (cwd) card."),
                          "cwd": strProp("Freeform: run in this existing directory — no worktree is cut and "
                              + "the path is trusted via the sandbox (not the allowlist). Omit repo/branch when set."),
                          "access": strProp("'readWrite' (default) or 'readOnly' (agent cannot edit/write/commit)."),
                          "scratch": boolProp("Scratch: create a fresh throwaway ~/.orchestra/scratch/<id> dir, "
                              + "run there, and rm -rf it on archive. Omit repo/branch/cwd when set."),
                          "model": strProp("Model id (from the adapter's list)"),
                          "agent": strProp("Agent adapter to run: 'claude-code' (default) or 'codex'. Omit to "
                              + "infer from `model`, else use the configured default agent."),
                          "col": colProp(startInOnly: true),
                          "seed": strProp("Fork/fan-out context (the parent slice / handoff summary) the "
                              + "fresh card opens on — folded ahead of `prompt` into the launch turn."),
                          "base": strProp("Parent branch to create this card's branch ON TOP OF (an "
                              + "existing local branch). The new branch starts at the base's tip and its "
                              + "parent link is recorded. Ignored when the branch already exists. Omit for "
                              + "today's HEAD behavior."),
                      ], required: ["prompt"])),

        CommandSchema(name: "move", summary: "Move a card to a column (plan/impl/review).",
                      params: schema(["ref": refProp(), "col": colProp()], required: ["ref", "col"])),

        CommandSchema(name: "send", summary: "Queue a message to the agent's inbox (drained at its next turn-end).",
                      params: schema(["ref": refProp(), "message": strProp("Text to send")],
                                     required: ["ref", "message"])),

        CommandSchema(name: "inbox",
                      summary: "List a card's pending inbox messages (id, text, createdAt) in FIFO order.",
                      params: schema(["ref": refProp()], required: ["ref"])),

        CommandSchema(name: "inbox-edit", summary: "Edit the text of a queued inbox message.",
                      params: schema(["ref": refProp(),
                                      "id": strProp("Inbox message id (a UUID from `inbox`)"),
                                      "text": strProp("New message text")],
                                     required: ["ref", "id", "text"])),

        CommandSchema(name: "inbox-remove", summary: "Remove a queued inbox message by id.",
                      params: schema(["ref": refProp(),
                                      "id": strProp("Inbox message id (a UUID from `inbox`)")],
                                     required: ["ref", "id"])),

        CommandSchema(name: "inbox-reorder",
                      summary: "Reorder a card's pending inbox messages (`ids` = the full new order).",
                      params: schema(["ref": refProp(),
                                      "ids": .object([
                                          "type": .string("array"),
                                          "items": .object(["type": .string("string")]),
                                          "description": .string("The card's message ids in the desired new order"),
                                      ])],
                                     required: ["ref", "ids"])),

        CommandSchema(name: "wait",
                      summary: "Subscribe to watched card conclusions (Done or clean exit) and wake/remind "
                          + "the watcher when one fires. For reactive fan-out, re-issue on cards that remain.",
                      params: schema([
                          "refs": .object([
                              "type": .string("array"),
                              "items": .object(["type": .string("string")]),
                              "description": .string("Card refs to watch — UUID/shortId/orchestra:// URI"),
                          ]),
                          "watcher": strProp("The watching card's ref; its inbox coalesces each conclusion "
                              + "and it is woken (F2/F3). Omit for a CLI-style wait-and-return."),
                      ], required: ["refs"])),

        CommandSchema(name: "handoff",
                      summary: "Clean-context handoff (F1): kill + resume THIS card in a fresh process, "
                          + "same session id, seeded with `context` folded together with its pending inbox.",
                      params: schema([
                          "ref": refProp(),
                          "context": strProp("Handoff context — the summary/instructions the resumed, "
                              + "clean-context session opens on (folded ahead of any queued inbox messages)."),
                      ], required: ["ref", "context"])),

        CommandSchema(name: "set-parent",
                      summary: "Set or clear a card branch's parent link. With `parent`: adopt it "
                          + "(records parent + merge-base, history untouched). Omit `parent` to clear.",
                      params: schema([
                          "ref": refProp(),
                          "parent": strProp("Parent branch ref to adopt (local name). Omit to clear the link."),
                          "mode": strProp("'adopt' (default): metadata-only relink; base = merge-base."),
                      ], required: ["ref"])),

        CommandSchema(name: "tree",
                      summary: "Lineage snapshot — parent/children per card. Scope by `ref` or `repo`; "
                          + "omit both for all active cards.",
                      params: schema([
                          "ref": refProp(),
                          "repo": strProp("Limit to cards in this repo root."),
                      ], required: [])),

        CommandSchema(name: "synced",
                      summary: "Report that this card merged/restacked its parent down: record the "
                          + "parent's current tip as the sync base and clear the stale/behind signal.",
                      params: schema(["ref": refProp()], required: ["ref"])),

        CommandSchema(name: "status", summary: "Current state of a card (incl. derived running).",
                      params: schema(["ref": refProp()], required: ["ref"])),

        CommandSchema(name: "archive", summary: "Archive a card (done + off the board).",
                      params: schema(["ref": refProp()], required: ["ref"])),

        CommandSchema(name: "reopen", summary: "Reopen an archived card (recreate its worktree + resume the agent).",
                      params: schema(["ref": refProp()], required: ["ref"])),

        CommandSchema(name: "restart", summary: "Start a new blank session in the same worktree (no prompt re-handed).",
                      params: schema(["ref": refProp()], required: ["ref"])),

        CommandSchema(name: "resume", summary: "Re-attempt claude --resume of the card's existing session.",
                      params: schema(["ref": refProp()], required: ["ref"])),

        CommandSchema(name: "shell", summary: "Open a shell window in the worktree; returns its tmux target.",
                      params: schema(["ref": refProp(),
                                      "window": strProp("Reuse/create this exact window (idempotent, e.g. a phone-owned `phone-<client>`); omit for a fresh shell-N")],
                                     required: ["ref"])),

        CommandSchema(name: "inspect", summary: "Open a read-only claude in the card's worktree shell.",
                      params: schema(["ref": refProp()], required: ["ref"])),

        CommandSchema(name: "closeShell", summary: "Close a shell window opened via `shell`.",
                      params: schema(["ref": refProp(), "window": strProp("Shell window name, e.g. shell-1")],
                                     required: ["ref", "window"])),

        CommandSchema(name: "exec", summary: "Run a one-shot command in the worktree.",
                      params: schema(["ref": refProp(), "cmd": strProp("Command to run (/bin/sh -c)"),
                                      "timeout": intProp("Seconds")],
                                     required: ["ref", "cmd"])),

        CommandSchema(name: "sessions", summary: "Debug handles for a card: tmux targets + agent session id.",
                      params: schema(["ref": refProp()], required: ["ref"])),

        CommandSchema(name: "capture",
                      summary: "Read-only snapshot of a card's tmux pane (agent or a shell window). "
                          + "No attach, no resize.",
                      params: schema(["ref": refProp(),
                                      "window": strProp("Window to read: 'agent' (default) or a shell "
                                          + "window like 'shell-1'")],
                                     required: ["ref"]),
                      exposure: .appOnly),

        CommandSchema(name: "send-keys",
                      summary: "Send live keystrokes to a card's tmux window — an ordered chord of named "
                          + "keys (Esc, Up/Down/Left/Right, Tab, Enter, C-c, PgUp/PgDn, Home/End) and/or "
                          + "literal text. Distinct from `send` (inbox queue): no implicit Enter.",
                      params: schema([
                          "ref": refProp(),
                          "keys": .object([
                              "type": .string("array"),
                              "description": .string(
                                  "Ordered chord elements; each is {\"key\": <name>} (Esc, Up, Down, Left, "
                                  + "Right, Tab, Enter, C-c, PgUp, PgDn, Home, End) or {\"text\": <literal>}."),
                          ]),
                          "window": strProp("Target window (default 'agent')"),
                      ], required: ["ref", "keys"]),
                      exposure: .appOnly),

        CommandSchema(name: "trustState",
                      summary: "Is a directory already trusted? Read-only ledger query for the spawn "
                          + "sheet's trust indicator — never grants (granting is a human-only surface).",
                      params: schema(["path": strProp("Absolute directory path to check")],
                                     required: ["path"])),

        CommandSchema(name: "batch-spawn", summary: "Spawn many agents at once (one per entry).",
                      params: schema(["tasks": .object([
                          "type": .string("array"),
                          "description": .string("Array of spawn params {prompt, repo, branch, model?, col?, base?}"),
                      ])], required: ["tasks"])),

        CommandSchema(name: "trust",
                      summary: "Grant a human's trust for a directory so agents may run there with write "
                          + "access. Requires a human to approve (MCP elicitation / interactive CLI); an "
                          + "agent can only trigger it, never self-grant.",
                      params: schema(["path": strProp("Directory to trust (the card's cwd / repo root)")],
                                     required: ["path"])),
    ]

    // MARK: - schema builders (moved verbatim from Commands.swift; now public for Kit consumers)

    public static func schema(_ props: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { .string($0) }),
        ])
    }
    // Required-ness is driven by the `required:` array in `schema(...)`, so these just describe shape.
    public static func strProp(_ desc: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(desc)])
    }
    public static func intProp(_ desc: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(desc)])
    }
    public static func boolProp(_ desc: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(desc)])
    }
    public static func refProp() -> JSONValue {
        strProp("Card ref — UUID, shortId, or orchestra://task/<ref> URI")
    }
    /// Column enum prop. `startInOnly` restricts it to the two spawn-start columns (plan/impl).
    public static func colProp(startInOnly: Bool = false) -> JSONValue {
        let cols = startInOnly ? ["plan", "impl"] : Column.allCases.map(\.rawValue)
        return .object([
            "type": .string("string"),
            "enum": .array(cols.map { .string($0) }),
            "description": .string(startInOnly ? "Start in: plan or impl" : "Column"),
        ])
    }
}
