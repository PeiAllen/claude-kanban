import Foundation

// MARK: - Board enums

/// Board columns. There is intentionally no `done` case — finishing sets `status = .done` +
/// `archived = true`, removing the card from the board into the Done popover.
public enum Column: String, Codable, Sendable, CaseIterable {
    case plan, impl, review

    /// Human-readable column name — shared by the daemon, CLI, and app so they never drift.
    public var displayName: String {
        switch self { case .plan: return "Plan"; case .impl: return "Implementation"; case .review: return "Review" }
    }
}

/// Live status pill. `dead` = the session is no longer running and the card awaits user recovery
/// (work in the worktree is intact). Distinct from `done` (finished + archivable).
public enum AgentStatus: String, Codable, Sendable {
    case waiting, running, done, dead
}

/// Why a card went `dead` — set alongside `status = .dead`, surfaced by the Recovery panel + CLI/MCP.
public enum DeadReason: String, Codable, Sendable {
    case agentExited       // SessionEnd reason exit/logout — the agent quit (mid-life, usually resumable)
    case sessionVanished   // poll liveness reconcile: tmux session gone, no SessionEnd (crash / `tmux kill`)
    case rebootUnrevived   // reboot sweep couldn't auto-revive (no id / transcript gone / resume failed at boot)
    case resumeFailed      // a `resume` attempt (auto or user "Try resume") failed — see `deadDetail`
}

/// Spawn sheet "Start in".
public enum StartIn: String, Codable, Sendable {
    case plan, impl

    public var column: Column { self == .plan ? .plan : .impl }
}

// MARK: - Model identity

/// A provider-agnostic model handle. `id` is the launch identifier handed to the adapter (e.g.
/// `claude-opus-4-8`); `displayName` is the human label for the UI; `family` is a coarse provider
/// bucket used for accenting. Adapters catalog their own models; the heuristics here only fill gaps
/// for ids an adapter doesn't know (and for legacy persisted data).
///
/// Decodes from EITHER the structured object OR a bare `"<id>"` string, so existing `tasks.json`
/// files (which stored `model` as a plain string) migrate transparently on first read.
public struct AgentModel: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String          // launch id, passed to the adapter
    public var displayName: String // human label
    public var family: String      // "claude" | "gpt" | "gemini" | "other"

    public init(id: String, displayName: String, family: String) {
        self.id = id; self.displayName = displayName; self.family = family
    }

    /// Derive a sensible label + family from a bare id (used for un-cataloged ids + legacy data).
    public init(id: String) {
        self.init(id: id, displayName: AgentModel.humanize(id), family: AgentModel.detectFamily(id))
    }

    public init(from decoder: Decoder) throws {
        // Legacy form: a bare string id. (Assign members directly — can't delegate to `init(id:)`
        // here because the object branch below assigns the `let id` directly.)
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            self.id = s
            self.displayName = AgentModel.humanize(s)
            self.family = AgentModel.detectFamily(s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        self.id = id
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? AgentModel.humanize(id)
        self.family = try c.decodeIfPresent(String.self, forKey: .family) ?? AgentModel.detectFamily(id)
    }

    /// Coarse provider family from an id — the one place this string-sniffing lives.
    public static func detectFamily(_ id: String) -> String {
        let m = id.lowercased()
        if m.contains("claude") { return "claude" }
        if m.contains("gpt") || m.contains("o1") || m.contains("o3") { return "gpt" }
        if m.contains("gemini") { return "gemini" }
        return "other"
    }

    /// Best-effort label from an id when no catalog entry exists: strip a leading vendor token.
    public static func humanize(_ id: String) -> String {
        let vendors = ["claude-", "anthropic-", "openai-", "google-", "gemini-"]
        for v in vendors where id.hasPrefix(v) { return String(id.dropFirst(v.count)) }
        return id
    }
}

// MARK: - Task (the card)

/// What kind of directory a card runs in. Drives archive cleanup ("Orchestra deletes only dirs it
/// made": `.worktree` + `.scratch`) and board placement (`.worktree` ⇒ workflow column).
public enum CardOrigin: String, Codable, Sendable { case worktree, scratch, borrowed }

/// Whether the agent may edit the directory it runs in. `.readOnly` cards launch with the edit tools
/// denied + a sandbox `denyWrite` (the [[ReadOnlyLaunch]] recipe), but — unlike Mechanism A's
/// untracked shell — KEEP the Orchestra hooks, because a freeform read-only card is a tracked citizen.
public enum CardAccess: String, Codable, Sendable { case readWrite, readOnly }

public struct Task: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID            // tmux session = "orchestra-\(id)"

    /// Short card heading — DERIVED, never typed. Seeded from the prompt's first line at spawn (also
    /// passed to `claude --name`). The card title is display-authoritative; `session_name` is kept in
    /// sync best-effort. Re-titled from the first prompt after a restart/`/clear` when `titleProvisional`.
    public var title: String
    /// true => `title` is a placeholder eligible to be replaced by the next user prompt. Set by
    /// `restart` and `SessionStart(clear)`; cleared by the first re-title or an explicit `/rename` mirror.
    public var titleProvisional: Bool
    /// Live blurb of what the agent is doing now — pushed from Pre/PostToolUse hooks; pane-parse fallback.
    public var desc: String
    public var repo: String        // repo root (allowlisted); shown as repo name
    public var branch: String      // working branch
    public var cwd: String         // the ONE path: where the agent + shells run (== worktree root for .worktree)
    public var origin: CardOrigin  // worktree | scratch | borrowed
    public var access: CardAccess  // readWrite | readOnly — read-only borrowed cards launch locked-down
    public var agentId: String     // -> AgentRegistry (default "claude-code")
    public var model: AgentModel   // selected model (launch id + display label, from the adapter)
    public var startIn: StartIn    // where the agent began
    public var column: Column      // board column
    public var order: Int          // sort within a column
    public var status: AgentStatus // waiting/running/done/dead — pushed from hooks; tmux-liveness fallback
    public var deadReason: DeadReason?  // set with `status = .dead`; cleared when status leaves `.dead`
    public var deadDetail: String?      // optional human detail for `.resumeFailed`
    public var ctxPct: Double      // context-window usage 0...100 (gauge); 0/absent => gauge hidden
    public var agentSessionId: String?  // CURRENT agent-native id; seeded at spawn, maintained across /clear etc.
    public var priorSessionIds: [String]  // superseded ids (e.g. after `/clear`), newest-last
    public var initialPrompt: String  // the spawn prompt, persisted verbatim (title seed + Recovery panel)
    public var archived: Bool      // true => off the board, listed in the Done popover
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        titleProvisional: Bool = false,
        desc: String = "",
        repo: String,
        branch: String,
        cwd: String,
        origin: CardOrigin = .worktree,
        access: CardAccess = .readWrite,
        agentId: String = "claude-code",
        model: AgentModel,
        startIn: StartIn,
        column: Column,
        order: Int,
        status: AgentStatus = .running,
        deadReason: DeadReason? = nil,
        deadDetail: String? = nil,
        ctxPct: Double = 0,
        agentSessionId: String? = nil,
        priorSessionIds: [String] = [],
        initialPrompt: String,
        archived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.titleProvisional = titleProvisional
        self.desc = desc
        self.repo = repo
        self.branch = branch
        self.cwd = cwd
        self.origin = origin
        self.access = access
        self.agentId = agentId
        self.model = model
        self.startIn = startIn
        self.column = column
        self.order = order
        self.status = status
        self.deadReason = deadReason
        self.deadDetail = deadDetail
        self.ctxPct = ctxPct
        self.agentSessionId = agentSessionId
        self.priorSessionIds = priorSessionIds
        self.initialPrompt = initialPrompt
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.titleProvisional = try c.decodeIfPresent(Bool.self, forKey: .titleProvisional) ?? false
        self.desc = try c.decodeIfPresent(String.self, forKey: .desc) ?? ""
        self.repo = try c.decode(String.self, forKey: .repo)
        self.branch = try c.decode(String.self, forKey: .branch)
        // MIGRATION: prefer new `cwd`; fall back to the old `worktree` string.
        let legacyWorktree = try c.decodeIfPresent(String.self, forKey: .worktree)
        self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? legacyWorktree ?? ""
        self.origin = try c.decodeIfPresent(CardOrigin.self, forKey: .origin) ?? .worktree
        self.access = try c.decodeIfPresent(CardAccess.self, forKey: .access) ?? .readWrite
        self.agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? "claude-code"
        self.model = try c.decode(AgentModel.self, forKey: .model)
        self.startIn = try c.decode(StartIn.self, forKey: .startIn)
        self.column = try c.decode(Column.self, forKey: .column)
        self.order = try c.decode(Int.self, forKey: .order)
        self.status = try c.decodeIfPresent(AgentStatus.self, forKey: .status) ?? .running
        self.deadReason = try c.decodeIfPresent(DeadReason.self, forKey: .deadReason)
        self.deadDetail = try c.decodeIfPresent(String.self, forKey: .deadDetail)
        self.ctxPct = try c.decodeIfPresent(Double.self, forKey: .ctxPct) ?? 0
        self.agentSessionId = try c.decodeIfPresent(String.self, forKey: .agentSessionId)
        self.priorSessionIds = try c.decodeIfPresent([String].self, forKey: .priorSessionIds) ?? []
        self.initialPrompt = try c.decodeIfPresent(String.self, forKey: .initialPrompt) ?? ""
        self.archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    // `worktree` stays here as a decode-only key (migration); it is no longer a stored property and is
    // never encoded — `encode(to:)` writes `cwd`/`origin` instead. (An extra CodingKey with no matching
    // property defeats synthesized Encodable, so the encoder is spelled out explicitly.)
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(titleProvisional, forKey: .titleProvisional)
        try c.encode(desc, forKey: .desc)
        try c.encode(repo, forKey: .repo)
        try c.encode(branch, forKey: .branch)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(origin, forKey: .origin)
        try c.encode(access, forKey: .access)
        try c.encode(agentId, forKey: .agentId)
        try c.encode(model, forKey: .model)
        try c.encode(startIn, forKey: .startIn)
        try c.encode(column, forKey: .column)
        try c.encode(order, forKey: .order)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(deadReason, forKey: .deadReason)
        try c.encodeIfPresent(deadDetail, forKey: .deadDetail)
        try c.encode(ctxPct, forKey: .ctxPct)
        try c.encodeIfPresent(agentSessionId, forKey: .agentSessionId)
        try c.encode(priorSessionIds, forKey: .priorSessionIds)
        try c.encode(initialPrompt, forKey: .initialPrompt)
        try c.encode(archived, forKey: .archived)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, titleProvisional, desc, repo, branch, cwd, worktree, origin, access, agentId, model,
             startIn, column, order, status, deadReason, deadDetail, ctxPct, agentSessionId,
             priorSessionIds, initialPrompt, archived, createdAt, updatedAt
    }

    // Card reference — the agent-facing handle ("Copy chat link" copies `ref`).
    public var shortId: String { String(id.uuidString.prefix(6)).lowercased() }

    /// The card's tmux session name (`orchestra-<id>`) — the single definition clients and the
    /// daemon share instead of re-interpolating the literal.
    public var tmuxSession: String { "orchestra-\(id.uuidString.lowercased())" }

    /// orchestra://task/<shortId>-<slug>
    public func ref(slugging slug: Bool = true) -> String {
        "orchestra://task/\(shortId)" + (slug ? "-\(slugify(title))" : "")
    }
}

// MARK: - Command result shapes

public struct ExecResult: Codable, Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
}

public struct ShellTab: Codable, Sendable, Equatable {
    public let window: String
    public let label: String
    public let pwd: String
    public init(window: String, label: String, pwd: String) {
        self.window = window; self.label = label; self.pwd = pwd
    }
}

public struct TaskStatus: Codable, Sendable, Equatable {
    public let task: Task
    public let running: Bool
    public init(task: Task, running: Bool) { self.task = task; self.running = running }
}

/// Outcome of `batch-spawn`: which entries succeeded and which failed, so a mid-batch failure
/// reports partial success instead of aborting and stranding the cards already created.
public struct BatchSpawnResult: Codable, Sendable, Equatable {
    public let spawned: [Task]
    public let failed: [BatchSpawnFailure]
    public init(spawned: [Task], failed: [BatchSpawnFailure]) {
        self.spawned = spawned; self.failed = failed
    }
}

public struct BatchSpawnFailure: Codable, Sendable, Equatable {
    public let index: Int        // position in the submitted batch
    public let prompt: String    // the entry's prompt (for identifying which failed)
    public let error: String
    public init(index: Int, prompt: String, error: String) {
        self.index = index; self.prompt = prompt; self.error = error
    }
}

// MARK: - Debug handles (the `sessions` command)

public enum WindowKind: String, Codable, Sendable {
    case agent, shell
}

/// One attachable tmux window inside the card's session, with a ready-to-run attach line.
public struct TmuxTarget: Codable, Sendable, Equatable {
    public let socket: String     // tmux -L socket (e.g. "orchestra")
    public let session: String    // "orchestra-<id>"
    public let window: String     // "agent" | "shell-1" | ...
    public let kind: WindowKind
    public let target: String     // "orchestra-<id>:agent"
    public let attach: String     // "tmux -L orchestra attach -t orchestra-<id>:agent"
    public init(socket: String, session: String, window: String, kind: WindowKind, target: String, attach: String) {
        self.socket = socket; self.session = session; self.window = window
        self.kind = kind; self.target = target; self.attach = attach
    }
}

/// The agent's own identity for transcript search / resume / debugging — sourced from the Adapter.
public struct AgentSessionInfo: Codable, Sendable, Equatable {
    public let agentId: String
    public let sessionId: String?
    public let transcriptPath: String?
    public let priorSessionIds: [String]
    public let priorTranscripts: [String]
    public let resumeCmd: [String]?
    public init(agentId: String, sessionId: String?, transcriptPath: String?,
                priorSessionIds: [String], priorTranscripts: [String], resumeCmd: [String]?) {
        self.agentId = agentId; self.sessionId = sessionId; self.transcriptPath = transcriptPath
        self.priorSessionIds = priorSessionIds; self.priorTranscripts = priorTranscripts
        self.resumeCmd = resumeCmd
    }
}

/// Everything needed to jump into a card and debug it, resolved from just its ref.
public struct CardSessions: Codable, Sendable, Equatable {
    public let ref: String
    public let id: UUID
    public let worktree: String
    public let tmuxSocket: String
    public let session: String
    public let running: Bool
    public let targets: [TmuxTarget]
    public let agent: AgentSessionInfo
    public init(ref: String, id: UUID, worktree: String, tmuxSocket: String, session: String,
                running: Bool, targets: [TmuxTarget], agent: AgentSessionInfo) {
        self.ref = ref; self.id = id; self.worktree = worktree; self.tmuxSocket = tmuxSocket
        self.session = session; self.running = running; self.targets = targets; self.agent = agent
    }
}

// MARK: - Status channel (agent -> Orchestra)

/// Seq-stamped **snapshot** half of a status patch: fields that describe the agent's *current* state
/// with no ordering guarantee (statusLine + Pre/PostToolUse/Notification hooks). The whole struct is
/// applied as a unit behind the per-card monotonic `seq` guard, so a stale snapshot can never
/// overwrite a fresher one. Putting these together (separate from `EventReport`) makes the
/// seq-gating contract type-level: a field here is *always* gated, a field on `EventReport` never is.
public struct SnapshotReport: Codable, Sendable, Equatable {
    public var seq: UInt64
    public var ctxPct: Double?
    /// Current model *launch id* (e.g. `model.id`). Tracks in-session `/model` switches; resolved to
    /// a full `AgentModel` via the adapter. Never the display label.
    public var modelId: String?
    /// Current model *display label* (e.g. `model.display_name`) — UI only, never used to launch.
    public var modelDisplay: String?
    public var status: AgentStatus?
    public var desc: String?
    /// A `/rename` mirror — applied only on a genuine change (see report) so it can't clobber the
    /// re-title-after-restart flow.
    public var sessionName: String?
    public init(seq: UInt64 = 0, ctxPct: Double? = nil, modelId: String? = nil,
                modelDisplay: String? = nil, status: AgentStatus? = nil, desc: String? = nil,
                sessionName: String? = nil) {
        self.seq = seq; self.ctxPct = ctxPct; self.modelId = modelId
        self.modelDisplay = modelDisplay; self.status = status; self.desc = desc
        self.sessionName = sessionName
    }
}

/// **Event-ordered** half of a status patch: fields from discrete, causally-ordered hooks
/// (SessionStart / UserPromptSubmit / SessionEnd). Applied unconditionally — never seq-gated — so a
/// genuine transition is never dropped as "stale".
public struct EventReport: Codable, Sendable, Equatable {
    public var sessionId: String?
    /// Carried for completeness; re-derived from the live id in `Adapter.sessionInfo`, not persisted.
    public var transcriptPath: String?
    /// SessionStart `source` (startup/resume/clear/compact) — drives waiting/clear transitions + resume confirm.
    public var sessionSource: String?
    /// SessionEnd genuine-termination reason (exit/logout/other) — drives the mid-life `.dead` transition.
    /// Transition reasons (clear/resume/compact) are dropped by the `_report` helper and never reach here.
    public var endReason: String?
    public var promptText: String?
    public init(sessionId: String? = nil, transcriptPath: String? = nil, sessionSource: String? = nil,
                endReason: String? = nil, promptText: String? = nil) {
        self.sessionId = sessionId; self.transcriptPath = transcriptPath
        self.sessionSource = sessionSource; self.endReason = endReason; self.promptText = promptText
    }
}

/// A live patch the agent pushes to the daemon: an optional ordered-`event` part and/or an optional
/// seq-gated `snapshot` part. A single hook can carry both (e.g. UserPromptSubmit → `promptText`
/// event + `status` snapshot). Consumers read `.event` / `.snapshot`; the flat initializer below is
/// the single place that routes a field to its bucket.
public struct StatusReport: Codable, Sendable, Equatable {
    public var event: EventReport?
    public var snapshot: SnapshotReport?

    public init(event: EventReport?, snapshot: SnapshotReport?) {
        self.event = event; self.snapshot = snapshot
    }

    /// Ergonomic flat constructor — routes each field to its bucket. The classification lives here
    /// (and is exercised by the report tests) instead of being re-derived at every call site.
    public init(seq: UInt64 = 0, sessionId: String? = nil, transcriptPath: String? = nil,
                ctxPct: Double? = nil, modelId: String? = nil, modelDisplay: String? = nil,
                sessionName: String? = nil, desc: String? = nil, status: AgentStatus? = nil,
                promptText: String? = nil, sessionSource: String? = nil, endReason: String? = nil) {
        let hasSnapshot = seq != 0 || ctxPct != nil || modelId != nil || modelDisplay != nil
            || sessionName != nil || desc != nil || status != nil
        let hasEvent = sessionId != nil || transcriptPath != nil || promptText != nil
            || sessionSource != nil || endReason != nil
        self.init(
            event: hasEvent ? EventReport(sessionId: sessionId, transcriptPath: transcriptPath,
                                          sessionSource: sessionSource, endReason: endReason,
                                          promptText: promptText) : nil,
            snapshot: hasSnapshot ? SnapshotReport(seq: seq, ctxPct: ctxPct, modelId: modelId,
                                                   modelDisplay: modelDisplay, status: status,
                                                   desc: desc, sessionName: sessionName) : nil)
    }
}

// MARK: - Activity feed

public enum ActivitySource: String, Codable, Sendable {
    case app, cli, mcp, agent, daemon
}

public enum ActivityKind: String, Codable, Sendable {
    case spawned, moved, archived, statusChanged, dead, recovered, command
}

/// One entry in the Activity feed's Live tab: a discrete, human-readable record of a notable event.
public struct ActivityItem: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let at: Date
    public let taskId: UUID?
    public let ref: String?
    public let source: ActivitySource
    public let kind: ActivityKind
    public let text: String
    public init(id: UUID = UUID(), at: Date = Date(), taskId: UUID?, ref: String?,
                source: ActivitySource, kind: ActivityKind, text: String) {
        self.id = id; self.at = at; self.taskId = taskId; self.ref = ref
        self.source = source; self.kind = kind; self.text = text
    }
}

// MARK: - Events (daemon -> clients)

public enum Event: Codable, Sendable, Equatable {
    case taskUpserted(Task)
    case taskRemoved(UUID)
    case activity(ActivityItem)
}

// MARK: - Spawn input

public struct SpawnInput: Codable, Sendable, Equatable {
    public var prompt: String
    public var repo: String
    public var branch: String
    public var model: String?
    public var startIn: StartIn?
    public var agentId: String?   // which adapter to use; nil → Config.defaultAgentId
    /// Freeform (borrowed) spawn: a directory the card runs in WITHOUT cutting a worktree. When set,
    /// spawn skips `worktrees.ensure`, sets `origin = .borrowed`, and trusts the path via the sandbox
    /// (no allowlist gate). `repo`/`branch` may be empty. nil ⇒ the normal worktree spawn.
    public var cwd: String?
    /// Read-only vs read-write (defaults read-write). A `.readOnly` borrowed card launches locked down.
    public var access: CardAccess
    public init(prompt: String, repo: String = "", branch: String = "", model: String? = nil,
                startIn: StartIn? = nil, agentId: String? = nil,
                cwd: String? = nil, access: CardAccess = .readWrite) {
        self.prompt = prompt; self.repo = repo; self.branch = branch
        self.model = model; self.startIn = startIn; self.agentId = agentId
        self.cwd = cwd; self.access = access
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.prompt = try c.decode(String.self, forKey: .prompt)
        self.repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        self.branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.startIn = try c.decodeIfPresent(StartIn.self, forKey: .startIn)
        self.agentId = try c.decodeIfPresent(String.self, forKey: .agentId)
        self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        self.access = try c.decodeIfPresent(CardAccess.self, forKey: .access) ?? .readWrite
    }
}
