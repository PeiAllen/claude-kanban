import Foundation

/// One executable command: a `CommandSchema` (the vocabulary half, from OrchestraKit) bound to a
/// daemon handler. Both the MCP bridge and the CLI read the *schema* from `CommandCatalog`; the
/// daemon reads the *handler* from here. The two halves are paired by name in `build()`.
public struct Command: Sendable {
    public let schema: CommandSchema
    public let run: @Sendable (OrchestraService, JSONValue, ActivitySource) async throws -> JSONValue
    public var name: String { schema.name }
}

public struct CommandRegistry: Sendable {
    public let commands: [Command]
    private let byName: [String: Command]

    public init() {
        self.commands = CommandRegistry.build()
        self.byName = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
    }

    public func command(_ name: String) -> Command? { byName[name] }

    // MARK: - the single gate-enforcement chokepoint

    /// The single dispatch chokepoint. Resolves the verb's target card (if it names one) and enforces its
    /// `phaseGate` against the card's current `Phase.Kind` BEFORE the handler runs — a gated-out call never
    /// reaches its handler. Deny-by-default: a kind absent from the allow-set is denied. Query verbs and
    /// verbs with no single pre-existing target card (spawn/batch-spawn/trust/wait) are not phase-gated here.
    ///
    /// Double-resolve + snapshot contract: gated verbs resolve `resolveRef` twice (gate + handler). This is
    /// a snapshot-at-dispatch COARSE pre-filter, not a lock — a concurrent transition can land between the
    /// two resolves. That is sufficient for PR4a (declare + enforce the policy under single-actor
    /// serialization); the airtight session-claim guard (never claim mid-launch even under a race) is the
    /// launch/relaunch steppers' `created`-check + the reconciler's orphan sweep (PR4b).
    public func dispatch(_ cmd: Command, _ service: OrchestraService,
                         _ params: JSONValue, _ source: ActivitySource) async throws -> JSONValue {
        if cmd.schema.kind != .query,
           let paramName = Self.targetCardParam(for: cmd.name),
           let raw = params.optString(paramName) {
            let card = try await service.resolveRef(raw)   // throws .unknownTask (fail fast, same as the handler)
            let kind = Self.gatedKind(of: card)
            guard cmd.schema.phaseGate.contains(kind) else {
                throw OrchestraError.phaseGated(verb: cmd.name, phase: kind.rawValue)
            }
        }
        return try await cmd.run(service, params, source)
    }

    /// Which param names the single existing card a verb's `phaseGate` applies to. `nil` ⇒ the verb has no
    /// single pre-existing target: `spawn`/`batch-spawn` create, `trust`/`trustState` are path-scoped,
    /// `wait` is multi-target + all-phase, `list` has no ref. Everything else targets `"ref"`.
    static func targetCardParam(for verb: String) -> String? {
        switch verb {
        case "spawn", "batch-spawn", "trust", "trustState", "wait", "list", "shared-policy": return nil
        default: return "ref"
        }
    }

    /// The card's EFFECTIVE lifecycle kind for gating. PR4b (Task 4): `phase == .archived(_)` is now the
    /// SOLE archived representation — `archive` is intent-only (`→ archivedPending`) + the TeardownStepper
    /// flips to `archivedComplete`, and the migration seeds legacy archived records as `.archived(_)`. So the
    /// PR4a Bool-bridge is retired: the gate reads `phase.kind` directly (the gate SETS never changed).
    static func gatedKind(of card: Task) -> Phase.Kind { card.phase.kind }

    // MARK: - the handler table

    private typealias Handler = @Sendable (OrchestraService, JSONValue, ActivitySource) async throws -> JSONValue

    private static func build() -> [Command] {
        let handlers: [String: Handler] = [
            "list": { svc, p, src in
                let col = p.optString("col").flatMap(Column.init(rawValue:))
                let tasks = await svc.list(col, includeArchived: p["includeArchived"]?.boolValue ?? false)
                // `list` is a read-only poll (app refresh + MCP clients hit it constantly) —
                // logging it would flood the activity feed and bury real events.
                return try JSONValue(encodable: tasks)
            },

            "spawn": { svc, p, src in
                let input = SpawnInput(
                    id: try p.uuid("id"),           // required wire field — clients mint/forward it
                    prompt: try p.string("prompt"),
                    title: p.optString("title"),
                    note: p.optString("note"),
                    repo: p.optString("repo") ?? "", branch: p.optString("branch") ?? "",
                    model: p.optString("model"),
                    startIn: p.optString("col").flatMap(StartIn.init(rawValue:)),
                    agentId: p.optString("agent"),
                    cwd: p.optString("cwd"),
                    access: p.optString("access").flatMap(CardAccess.init(rawValue:)) ?? .readWrite,
                    scratch: p["scratch"]?.boolValue ?? false,
                    seed: p.optString("seed"),
                    base: p.optString("base"))
                let task = try await svc.spawn(input, source: src)
                return try JSONValue(encodable: task)
            },

            "move": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                guard let col = Column(rawValue: try p.string("col")) else {
                    throw OrchestraError.invalidParams("col must be plan/impl/review")
                }
                let updated = try await svc.move(t.id, to: col, source: src)
                return try JSONValue(encodable: updated)
            },

            "send": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let sender: InboxMessageSource
                if let senderRef = p.optString("senderCard") {
                    let senderTask = try await svc.resolveRef(senderRef)
                    sender = .card(id: senderTask.id, title: senderTask.title)
                } else {
                    sender = .human
                }
                // `id` is REQUIRED at this boundary (throws if absent) though advertised optional in the
                // catalog — every client seam (CLI --id / MCP bridge / BoardStore) stamps one if the caller
                // omitted it, exactly like `spawn`. Required-here makes a seam that forgets fail loudly.
                let messageId = try p.uuid("id")
                let result = try await svc.send(t.id, try p.string("message"),
                                                messageId: messageId, sender: sender)
                await svc.logCommand("send", ref: t, source: src)
                return try JSONValue(encodable: result)
            },

            "inbox": { svc, p, _ in
                let t = try await svc.resolveRef(try p.string("ref"))
                let includeHistory = p["includeHistory"]?.boolValue ?? false
                return try JSONValue(encodable: await svc.inboxPeek(t.id, includeHistory: includeHistory))
            },

            "inbox-edit": { svc, p, _ in
                let t = try await svc.resolveRef(try p.string("ref"))
                guard let mid = UUID(uuidString: try p.string("id")) else {
                    throw OrchestraError.invalidParams("id must be a message UUID")
                }
                try await svc.inboxUpdate(t.id, messageId: mid, text: try p.string("text"))
                return .ok()
            },

            "inbox-remove": { svc, p, _ in
                let t = try await svc.resolveRef(try p.string("ref"))
                guard let mid = UUID(uuidString: try p.string("id")) else {
                    throw OrchestraError.invalidParams("id must be a message UUID")
                }
                try await svc.inboxRemove(t.id, messageId: mid)
                return .ok()
            },

            "inbox-retry": { svc, p, _ in
                let t = try await svc.resolveRef(try p.string("ref"))
                guard let mid = UUID(uuidString: try p.string("id")) else {
                    throw OrchestraError.invalidParams("id must be a message UUID")
                }
                try await svc.inboxRetry(t.id, messageId: mid)
                return .ok()
            },

            "inbox-reorder": { svc, p, _ in
                let t = try await svc.resolveRef(try p.string("ref"))
                guard let arr = p["ids"]?.arrayValue else {
                    throw OrchestraError.invalidParams("ids must be an array")
                }
                var ordered: [UUID] = []
                for e in arr {
                    guard let s = e.stringValue, let u = UUID(uuidString: s) else {
                        throw OrchestraError.invalidParams("each id must be a UUID string")
                    }
                    ordered.append(u)
                }
                try await svc.inboxReorder(t.id, orderedIds: ordered)
                return .ok()
            },

            "wait": { svc, p, src in
                guard let arr = p["refs"]?.arrayValue, !arr.isEmpty else {
                    throw OrchestraError.invalidParams("refs must be a non-empty array")
                }
                var ids: [UUID] = []
                for r in arr {
                    guard let raw = r.stringValue else { throw OrchestraError.invalidParams("each ref must be a string") }
                    ids.append(try await svc.resolveRef(raw).id)
                }
                var watcher: UUID? = nil
                if let w = p.optString("watcher") { watcher = try await svc.resolveRef(w).id }
                // MCP/tool watchers must NOT block their turn: register a durable watch and return
                // immediately (an already-settled child returns inline). Only the CLI `wait` path suspends.
                if src == .mcp, let watcher {
                    if let conc = await svc.watch(watcher: watcher, refs: ids) {
                        return try JSONValue(encodable: conc)
                    }
                    return .object(["watching": .bool(true)])
                }
                guard let conc = await svc.wait(watcher: watcher, refs: ids) else {
                    return .object(["cancelled": .bool(true)])
                }
                return try JSONValue(encodable: conc)
            },

            "handoff": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let updated = try await svc.resumeInCard(t.id, seed: try p.string("context"),
                                                         model: p.optString("model"), source: src)
                return try JSONValue(encodable: updated)
            },

            "set-title": { svc, p, src in
                let updated = try await svc.setTitle(ref: try p.string("ref"),
                                                     title: try p.string("title"), source: src)
                return try JSONValue(encodable: updated)
            },

            "set-note": { svc, p, src in
                let updated = try await svc.setNote(ref: try p.string("ref"),
                                                    note: try p.string("note"), source: src)
                return try JSONValue(encodable: updated)
            },

            "needs-input": { svc, p, src in
                let updated = try await svc.needsInput(ref: try p.string("ref"),
                                                       question: try p.string("question"), source: src)
                return try JSONValue(encodable: updated)
            },

            "set-planned": { svc, p, src in
                let updated = try await svc.setPlanned(ref: try p.string("ref"),
                                                       n: p.optInt("n") ?? 0, source: src)
                return try JSONValue(encodable: updated)
            },

            "set-parent": { svc, p, src in
                let updated = try await svc.setParent(
                    ref: try p.string("ref"),
                    parent: p.optString("parent"),
                    mode: p.optString("mode") ?? "adopt",
                    watch: p.optBool("watch") ?? false,
                    source: src)
                return try JSONValue(encodable: updated)
            },

            "tree": { svc, p, _ in
                // Read-only lineage query (like `list`): not logged, to keep the activity feed clean.
                let snap = try await svc.tree(ref: p.optString("ref"), repo: p.optString("repo"))
                return try JSONValue(encodable: snap)
            },

            "synced": { svc, p, src in
                let updated = try await svc.synced(ref: try p.string("ref"), source: src)
                return try JSONValue(encodable: updated)
            },

            "shipped": { svc, p, src in
                let updated = try await svc.shipped(ref: try p.string("ref"), by: p.optString("by"),
                                                    force: p.optBool("force") ?? false, source: src)
                return try JSONValue(encodable: updated)
            },

            "merge-request": { svc, p, src in
                let updated = try await svc.mergeRequest(ref: try p.string("ref"), source: src)
                return try JSONValue(encodable: updated)
            },

            "borrow": { svc, p, src in
                let path = try await svc.borrow(ref: try p.string("ref"), source: src)
                return .object(["worktree": .string(path)])
            },

            "release": { svc, p, src in
                try await svc.release(ref: try p.string("ref"), source: src)
                return .object(["released": .bool(true)])
            },

            "status": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let st = try await svc.status(t.id)
                await svc.logCommand("status", ref: t, source: src)
                return try JSONValue(encodable: st)
            },

            "archive": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                try await svc.archive(t.id, source: src)
                return .ok()
            },

            "reopen": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let updated = try await svc.reopen(t.id, source: src)
                return try JSONValue(encodable: updated)
            },

            "restart": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let updated = try await svc.restart(t.id, model: p.optString("model"), source: src)
                return try JSONValue(encodable: updated)
            },

            "resume": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let updated = try await svc.resume(t.id, model: p.optString("model"), source: src)
                return try JSONValue(encodable: updated)
            },

            "shell": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                // Optional `window`: a phone client passes a deterministic `phone-<client>` name so the
                // window is reused across reconnects (idempotent); omit it for the desktop's `shell-N`.
                let tab = try await svc.openShell(t.id, window: p.optString("window"))
                await svc.logCommand("shell", ref: t, source: src)
                // `socket` lets a client build the full tmux attach target without a second round-trip.
                return .object(["session": .string(t.tmuxSession), "window": .string(tab.window),
                                "socket": .string(Config.tmuxSocket)])
            },

            "inspect": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let tab = try await svc.inspect(t.id)
                await svc.logCommand("inspect", ref: t, source: src)
                return .object(["session": .string(t.tmuxSession), "window": .string(tab.window)])
            },

            "closeShell": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                try await svc.closeShell(t.id, window: try p.string("window"))
                await svc.logCommand("closeShell", ref: t, source: src)
                return .object(["ok": .bool(true)])
            },

            "exec": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let timeout = p.optInt("timeout").map { Duration.seconds($0) }
                let res = try await svc.exec(t.id, try p.string("cmd"), timeout: timeout)
                await svc.logCommand("exec", ref: t, source: src)
                return try JSONValue(encodable: res)
            },

            "sessions": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let cs = try await svc.sessions(t.id)
                await svc.logCommand("sessions", ref: t, source: src)
                return try JSONValue(encodable: cs)
            },

            "capture": { svc, p, _ in
                let t = try await svc.resolveRef(try p.string("ref"))
                let cap = try await svc.capture(t.id, window: p.optString("window") ?? "agent")
                // NOT logged: the phone Agent tab polls `capture` on a timer (like `list`), so
                // logging each read would flood the activity feed and bury real events.
                return try JSONValue(encodable: cap)
            },

            "publish-image": { svc, p, _ in
                let t = try await svc.resolveRef(try p.string("ref"))
                let path = try p.string("path")
                guard (path as NSString).isAbsolutePath else {
                    throw OrchestraError.invalidParams("image path must be absolute")
                }
                // Enforce the caption shape the schema advertises: the registry validates params against
                // no schema, so this is the only place every client path converges. Reject, never munge —
                // a rewritten caption would desync the label the agent thinks it published from the
                // filename the human ends up saving.
                let caption: String?
                do { caption = try TranscriptImageCaption.validated(p.optString("caption")) } catch {
                    throw OrchestraError.invalidParams(
                        "image caption must be \(TranscriptImageCaption.rule) — it is also the filename "
                            + "shown when a human saves or copies the image")
                }
                return try JSONValue(encodable: try await svc.publishImage(
                    t.id, sourcePath: path, caption: caption))
            },

            "send-keys": { svc, p, src in
                // Decode + validate the chord BEFORE any session work so a bad request fails cleanly.
                guard let arr = p["keys"]?.arrayValue, !arr.isEmpty else {
                    throw OrchestraError.invalidParams("keys must be a non-empty array")
                }
                let tokens = try (p["keys"] ?? .array([])).decode([KeyToken].self)
                for token in tokens {
                    if case .text(let s) = token, s.isEmpty {
                        throw OrchestraError.invalidParams("keys text elements must be non-empty")
                    }
                }
                let t = try await svc.resolveRef(try p.string("ref"))
                try await svc.sendChord(t.id, tokens: tokens, window: p.optString("window") ?? "agent")
                await svc.logCommand("send-keys", ref: t, source: src)
                return .ok()
            },

            "trustState": { svc, p, _ in
                let trusted = await svc.isPathTrusted(try p.string("path"))
                return .object(["trusted": .bool(trusted)])
            },

            "batch-spawn": { svc, p, src in
                guard let arr = p["tasks"]?.arrayValue else {
                    throw OrchestraError.invalidParams("tasks must be an array")
                }
                var inputs: [SpawnInput] = []
                for item in arr {
                    inputs.append(SpawnInput(
                        id: try item.uuid("id"),    // required per-item wire field (client stamps when absent)
                        prompt: try item.string("prompt"),
                        title: item.optString("title"),   // this loop rebuilds SpawnInput by hand — a field
                        note: item.optString("note"),    // missed here is advertised but silently dropped
                        repo: try item.string("repo"),
                        branch: try item.string("branch"), model: item.optString("model"),
                        startIn: item.optString("col").flatMap(StartIn.init(rawValue:)),
                        seed: item.optString("seed"),
                        base: item.optString("base")))
                }
                let result = await svc.batchSpawn(inputs, source: src)
                return try JSONValue(encodable: result)
            },

            "shared": { svc, p, src in
                let t = try await svc.resolveRef(try p.string("ref"))
                let paths = p["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
                return try await svc.shared(op: try p.string("op"), card: t, paths: paths, source: src)
            },

            "shared-policy": { svc, p, src in
                try await svc.sharedPolicy(repo: try p.string("repo"), item: p.optString("item"),
                                           policy: p.optString("policy"))
            },

            "trust": { svc, p, src in
                let res = try await svc.grantTrust(try p.string("path"), source: src)
                return try JSONValue(encodable: res)
            },
        ]

        // Pair each catalog schema with its handler; a missing/extra handler is a programmer error
        // caught here (and by CommandRegistryCatalogTests's 1:1 assertion).
        return CommandCatalog.all.map { schema in
            guard let run = handlers[schema.name] else {
                fatalError("F1: no handler bound for command '\(schema.name)'")
            }
            return Command(schema: schema, run: run)
        }
    }
}
