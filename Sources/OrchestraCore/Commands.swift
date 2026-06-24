import Foundation

/// One command in the canonical set — name + JSON-schema params + a handler delegating to
/// `OrchestraService`. Both the MCP bridge and the CLI are generated from this one registry.
public struct Command: Sendable {
    public let name: String
    public let summary: String
    public let params: JSONValue          // JSON schema (MCP inputSchema + CLI help)
    public let run: @Sendable (OrchestraService, JSONValue, ActivitySource) async throws -> JSONValue
}

public struct CommandRegistry: Sendable {
    public let commands: [Command]
    private let byName: [String: Command]

    public init() {
        self.commands = CommandRegistry.build()
        self.byName = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
    }

    public func command(_ name: String) -> Command? { byName[name] }
    public var names: [String] { commands.map(\.name) }

    // MARK: - the canonical set

    private static func build() -> [Command] {
        [
            Command(name: "list", summary: "List cards (optionally by column).",
                    params: schema(["col": colProp()], required: [])) { svc, p, src in
                let col = p.optString("col").flatMap(Column.init(rawValue:))
                let tasks = await svc.list(col)
                await svc.logCommand("list", ref: nil, source: src)
                return try JSONValue(encodable: tasks)
            },

            Command(name: "spawn",
                    summary: "Spawn a new agent. Only `prompt` is free text — no title/desc.",
                    params: schema([
                        "prompt": strProp("Initial prompt — what the agent should start working on"),
                        "repo": strProp("Repository root (allowlisted)"),
                        "branch": strProp("Working branch"),
                        "model": strProp("Model id (from the adapter's list)"),
                        "col": colProp(startInOnly: true),
                    ], required: ["prompt", "repo", "branch"])) { svc, p, src in
                let input = SpawnInput(
                    prompt: try p.string("prompt"), repo: try p.string("repo"),
                    branch: try p.string("branch"), model: p.optString("model"),
                    startIn: p.optString("col").flatMap(StartIn.init(rawValue:)))
                let task = try await svc.spawn(input, source: src)
                return try JSONValue(encodable: task)
            },

            Command(name: "move", summary: "Move a card to a column (plan/impl/review).",
                    params: schema(["ref": refProp(), "col": colProp()], required: ["ref", "col"])) { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                guard let col = Column(rawValue: try p.string("col")) else {
                    throw OrchestraError.invalidParams("col must be plan/impl/review")
                }
                let updated = try await svc.move(t.id, to: col, source: src)
                return try JSONValue(encodable: updated)
            },

            Command(name: "send", summary: "Send a message to the agent (write to its tmux window).",
                    params: schema(["ref": refProp(), "message": strProp("Text to send")],
                                   required: ["ref", "message"])) { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                try await svc.send(t.id, try p.string("message"))
                await svc.logCommand("send", ref: t, source: src)
                return .ok()
            },

            Command(name: "status", summary: "Current state of a card (incl. derived running).",
                    params: schema(["ref": refProp()], required: ["ref"])) { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let st = try await svc.status(t.id)
                await svc.logCommand("status", ref: t, source: src)
                return try JSONValue(encodable: st)
            },

            Command(name: "archive", summary: "Archive a card (done + off the board).",
                    params: schema(["ref": refProp()], required: ["ref"])) { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                try await svc.archive(t.id, source: src)
                return .ok()
            },

            Command(name: "restart", summary: "Start a new blank session in the same worktree (no prompt re-handed).",
                    params: schema(["ref": refProp()], required: ["ref"])) { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let updated = try await svc.restart(t.id, source: src)
                return try JSONValue(encodable: updated)
            },

            Command(name: "resume", summary: "Re-attempt claude --resume of the card's existing session.",
                    params: schema(["ref": refProp()], required: ["ref"])) { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let updated = try await svc.resume(t.id, source: src)
                return try JSONValue(encodable: updated)
            },

            Command(name: "shell", summary: "Open a shell window in the worktree; returns its tmux target.",
                    params: schema(["ref": refProp()], required: ["ref"])) { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let tab = try await svc.openShell(t.id)
                await svc.logCommand("shell", ref: t, source: src)
                return .object(["session": .string(t.tmuxSession), "window": .string(tab.window)])
            },

            Command(name: "exec", summary: "Run a one-shot command in the worktree.",
                    params: schema(["ref": refProp(), "cmd": strProp("Command to run (/bin/sh -c)"),
                                    "timeout": intProp("Seconds")],
                                   required: ["ref", "cmd"])) { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let timeout = p.optInt("timeout").map { Duration.seconds($0) }
                let res = try await svc.exec(t.id, try p.string("cmd"), timeout: timeout)
                await svc.logCommand("exec", ref: t, source: src)
                return try JSONValue(encodable: res)
            },

            Command(name: "sessions", summary: "Debug handles for a card: tmux targets + agent session id.",
                    params: schema(["ref": refProp()], required: ["ref"])) { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let cs = try await svc.sessions(t.id)
                await svc.logCommand("sessions", ref: t, source: src)
                return try JSONValue(encodable: cs)
            },

            Command(name: "batch-spawn", summary: "Spawn many agents at once (one per entry).",
                    params: schema(["tasks": .object([
                        "type": .string("array"),
                        "description": .string("Array of spawn params {prompt, repo, branch, model?, col?}"),
                    ])], required: ["tasks"])) { svc, p, src in
                guard let arr = p["tasks"]?.arrayValue else {
                    throw OrchestraError.invalidParams("tasks must be an array")
                }
                var inputs: [SpawnInput] = []
                for item in arr {
                    inputs.append(SpawnInput(
                        prompt: try item.string("prompt"), repo: try item.string("repo"),
                        branch: try item.string("branch"), model: item.optString("model"),
                        startIn: item.optString("col").flatMap(StartIn.init(rawValue:))))
                }
                let tasks = try await svc.batchSpawn(inputs, source: src)
                return try JSONValue(encodable: tasks)
            },
        ]
    }

    // MARK: - schema builders

    static func schema(_ props: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { .string($0) }),
        ])
    }
    // Required-ness is driven by the `required:` array in `schema(...)`, so these just describe shape.
    static func strProp(_ desc: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(desc)])
    }
    static func intProp(_ desc: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(desc)])
    }
    static func refProp() -> JSONValue {
        strProp("Card ref — UUID, shortId, or orchestra://task/<ref> URI")
    }
    /// Column enum prop. `startInOnly` restricts it to the two spawn-start columns (plan/impl).
    static func colProp(startInOnly: Bool = false) -> JSONValue {
        let cols = startInOnly ? ["plan", "impl"] : Column.allCases.map(\.rawValue)
        return .object([
            "type": .string("string"),
            "enum": .array(cols.map { .string($0) }),
            "description": .string(startInOnly ? "Start in: plan or impl" : "Column"),
        ])
    }
}
