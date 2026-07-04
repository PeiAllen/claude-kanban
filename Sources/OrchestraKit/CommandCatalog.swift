import Foundation

/// The canonical command vocabulary — name + summary + JSON-schema params — with NO execution.
/// The daemon binds handlers to these in `CommandRegistry` (OrchestraCore); the MCP bridge builds
/// tools from them; a phone client builds/validates requests from them. Single source of truth for
/// command *shape* (the execution half lives in `OrchestraCore/CommandRegistry.swift`).
public struct CommandSchema: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let params: JSONValue
    public init(name: String, summary: String, params: JSONValue) {
        self.name = name; self.summary = summary; self.params = params
    }
}

public enum CommandCatalog {
    public static func schema(_ name: String) -> CommandSchema? { byName[name] }
    private static let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

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
                      summary: "Block until one of the watched cards concludes (Done or clean exit). "
                          + "For the reactive fan-out — the caller re-issues on the cards that remain.",
                      params: schema([
                          "refs": .object([
                              "type": .string("array"),
                              "items": .object(["type": .string("string")]),
                              "description": .string("Card refs to watch — UUID/shortId/orchestra:// URI"),
                          ]),
                          "watcher": strProp("The watching card's ref; its inbox coalesces each conclusion "
                              + "and it is woken (F2/F3). Omit for a bare block-and-return."),
                      ], required: ["refs"])),

        CommandSchema(name: "handoff",
                      summary: "Clean-context handoff (F1): kill + resume THIS card in a fresh process, "
                          + "same session id, seeded with `context` folded together with its pending inbox.",
                      params: schema([
                          "ref": refProp(),
                          "context": strProp("Handoff context — the summary/instructions the resumed, "
                              + "clean-context session opens on (folded ahead of any queued inbox messages)."),
                      ], required: ["ref", "context"])),

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
                      params: schema(["ref": refProp()], required: ["ref"])),

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

        CommandSchema(name: "trustState",
                      summary: "Is a directory already trusted? Read-only ledger query for the spawn "
                          + "sheet's trust indicator — never grants (granting is a human-only surface).",
                      params: schema(["path": strProp("Absolute directory path to check")],
                                     required: ["path"])),

        CommandSchema(name: "batch-spawn", summary: "Spawn many agents at once (one per entry).",
                      params: schema(["tasks": .object([
                          "type": .string("array"),
                          "description": .string("Array of spawn params {prompt, repo, branch, model?, col?}"),
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
