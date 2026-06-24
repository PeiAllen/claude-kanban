import Foundation

// MARK: - Board enums

/// Board columns. There is intentionally no `done` case — finishing sets `status = .done` +
/// `archived = true`, removing the card from the board into the Done popover.
public enum Column: String, Codable, Sendable, CaseIterable {
    case plan, impl, review
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

    var column: Column { self == .plan ? .plan : .impl }
}

// MARK: - Task (the card)

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
    public var worktree: String    // abs path to the git worktree (derived: repo + branch)
    public var agentId: String     // -> AgentRegistry (default "claude-code")
    public var model: String       // selected model (from the adapter's list)
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
        worktree: String,
        agentId: String = "claude-code",
        model: String,
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
        self.worktree = worktree
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

    // Card reference — the agent-facing handle ("Copy chat link" copies `ref`).
    public var shortId: String { String(id.uuidString.prefix(6)).lowercased() }

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

/// A live patch the agent pushes to the daemon. All fields optional — only present ones are merged.
public struct StatusReport: Codable, Sendable, Equatable {
    public var seq: UInt64
    public var sessionId: String?
    public var transcriptPath: String?
    public var ctxPct: Double?
    public var model: String?
    public var sessionName: String?
    public var desc: String?
    public var status: AgentStatus?
    public var promptText: String?
    /// SessionStart source / SessionEnd reason carrier — drives waiting/clear/dead transitions.
    public var sessionSource: String?
    public init(seq: UInt64 = 0, sessionId: String? = nil, transcriptPath: String? = nil,
                ctxPct: Double? = nil, model: String? = nil, sessionName: String? = nil,
                desc: String? = nil, status: AgentStatus? = nil, promptText: String? = nil,
                sessionSource: String? = nil) {
        self.seq = seq; self.sessionId = sessionId; self.transcriptPath = transcriptPath
        self.ctxPct = ctxPct; self.model = model; self.sessionName = sessionName
        self.desc = desc; self.status = status; self.promptText = promptText
        self.sessionSource = sessionSource
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
    public init(prompt: String, repo: String, branch: String, model: String? = nil, startIn: StartIn? = nil) {
        self.prompt = prompt; self.repo = repo; self.branch = branch
        self.model = model; self.startIn = startIn
    }
}
