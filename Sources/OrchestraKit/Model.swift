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

/// Why a card is `.waiting` — set with `status = .waiting`, cleared when status leaves `.waiting`.
/// Drives which notification trigger the app fires. `.dead` is a separate transition (see `deadReason`).
public enum WaitReason: String, Codable, Sendable {
    case permission   // agent blocked on tool approval (Claude Notification/permission_prompt)
    case humanTurn    // agent genuinely finished its turn / idle, waiting on the human
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
/// Per-model capability flags from the offline model table (models.dev-shaped). All default false
/// so an absent/partial table entry is safe.
public struct ModelFlags: Codable, Sendable, Equatable, Hashable {
    public var toolCall: Bool
    public var reasoning: Bool
    public var vision: Bool
    public init(toolCall: Bool = false, reasoning: Bool = false, vision: Bool = false) {
        self.toolCall = toolCall; self.reasoning = reasoning; self.vision = vision
    }
}

public struct AgentModel: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String          // launch id, passed to the adapter
    public var displayName: String // human label
    public var family: String      // "claude" | "gpt" | "gemini" | "other"
    public var contextWindow: Int? // max context tokens (offline table); nil = unknown → gauge hidden
    public var flags: ModelFlags?  // capability flags (offline table); nil = unknown

    public init(id: String, displayName: String, family: String,
                contextWindow: Int? = nil, flags: ModelFlags? = nil) {
        self.id = id; self.displayName = displayName; self.family = family
        self.contextWindow = contextWindow; self.flags = flags
    }

    /// Derive a sensible label + family from a bare id (used for un-cataloged ids + legacy data).
    /// This is the UNKNOWN-MODEL FALLBACK: no contextWindow, no flags.
    public init(id: String) {
        self.init(id: id, displayName: AgentModel.humanize(id), family: AgentModel.detectFamily(id))
    }

    /// Context-window usage percent (0…100) for a token count, using this model's OFFLINE
    /// `contextWindow` as the denominator (the token-reporting agents' ctxPct path — D7/§6).
    /// nil when the window is unknown so the caller hides the gauge rather than dividing by a guess.
    public func ctxPct(usedTokens: Int) -> Double? {
        guard let cw = contextWindow, cw > 0 else { return nil }
        return min(100, max(0, Double(usedTokens) / Double(cw) * 100))
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

/// A selectable agent adapter surfaced to clients (the app's Spawn sheet agent picker). Carries the
/// adapter's identity + its own model catalog so the UI can offer "which agent, then which of its
/// models" without a second round-trip. Built from the registry — never invents agents that aren't wired up.
public struct AgentInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String            // adapter id (-> spawn `agent` param)
    public let name: String          // human label
    public let icon: String          // SF Symbol name
    public let models: [AgentModel]  // this agent's selectable models
    public let capabilities: AgentCapabilities

    // No default for `capabilities`: the `.claudeCode` preset is an adapter extension that lives in
    // OrchestraCore (client-safe Kit cannot reference it). Every call site passes the adapter's own
    // `capabilities` explicitly, so this is behavior-neutral.
    public init(id: String, name: String, icon: String, models: [AgentModel],
                capabilities: AgentCapabilities) {
        self.id = id; self.name = name; self.icon = icon; self.models = models
        self.capabilities = capabilities
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

// MARK: - Diff (code review on the board)

/// A card's branch diffstat for the footer (`k files · +N −M`). Small + persisted on `Task`.
public struct DiffStat: Codable, Sendable, Equatable {
    public var filesChanged: Int
    public var insertions: Int
    public var deletions: Int
    public init(filesChanged: Int, insertions: Int, deletions: Int) {
        self.filesChanged = filesChanged; self.insertions = insertions; self.deletions = deletions
    }
}

/// Which baseline a diff is computed against. `.working` = vs `HEAD`; `.branch` = vs the base branch
/// (merge-base); `.parent` = vs the card's parent branch for a stacked card — falls back to `.branch`
/// until `Task.parentBranch` is set. See `notes/designs/code-review-on-board`.
public enum DiffBase: String, Codable, Sendable { case working, branch, parent }

// MARK: - Tree (branch-tree lineage)

/// A child card's lineage state relative to its parent branch. Daemon-maintained like `DiffStat`;
/// nil until the parent-tree machinery (BT4) computes it. `inSync` = recorded base == parent tip;
/// `stale` = parent advanced (the `↓N` badge); `restackNeeded` = recorded base is no longer the
/// parent tip's ancestor (parent rewrote/shipped); `parentMerged` = parent landed, awaiting restack.
public enum TreeState: String, Codable, Sendable { case inSync, stale, restackNeeded, parentMerged }

/// Per-child tree status for the card face (the `↓N` badge + restack signal). Small + persisted on
/// `Task`, exactly like `DiffStat`.
public struct TreeStat: Codable, Sendable, Equatable {
    public var state: TreeState
    public var behind: Int            // commits the parent is ahead of the recorded base (the ↓N badge)
    public var parentIsRemote: Bool
    public init(state: TreeState, behind: Int = 0, parentIsRemote: Bool = false) {
        self.state = state; self.behind = behind; self.parentIsRemote = parentIsRemote
    }
}

// MARK: - Notes (the phone's Notes page)

/// Whether a changed note is modified vs the branch base (`M`) or newly added (`A`). Deletions never
/// appear — a deleted note has nothing to render. Wire form is the bare git status letter.
public enum NoteStatus: String, Codable, Sendable { case modified = "M", added = "A" }

/// One markdown note a card's branch changed/added vs its base, WITH its current content — the payload
/// of the `changedNotes` RPC. The phone's Notes page renders these in-app (it has no Obsidian, which is
/// what the desktop's "Open notes" opens the same file set in). `path` is worktree-relative. Mirrors the
/// desktop changed-notes computation; see mobile spec §3 "Notes page".
public struct NoteFile: Codable, Sendable, Equatable {
    public let path: String        // worktree-relative, e.g. "notes/designs/foo.md"
    public let status: NoteStatus  // M = modified vs base, A = added
    public let content: String     // full file content (UTF-8), size-capped by the daemon
    public init(path: String, status: NoteStatus, content: String) {
        self.path = path; self.status = status; self.content = content
    }
}

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
    public var parentBranch: String?  // stacked-branch parent (stub; nil until stacked-branches sets it) — the `.parent` diff baseline
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
    public var waitReason: WaitReason?  // set with `status = .waiting`; cleared when status leaves `.waiting`
    public var ctxPct: Double      // context-window usage 0...100 (gauge); 0/absent => gauge hidden
    public var diffStat: DiffStat? // daemon-maintained branch diffstat for the footer; nil = none / non-git / uncomputed
    public var treeStat: TreeStat? // daemon-maintained child lineage status (BT4+); nil = none / uncomputed
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
        waitReason: WaitReason? = nil,
        ctxPct: Double = 0,
        agentSessionId: String? = nil,
        priorSessionIds: [String] = [],
        initialPrompt: String,
        parentBranch: String? = nil,
        diffStat: DiffStat? = nil,
        treeStat: TreeStat? = nil,
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
        self.waitReason = waitReason
        self.ctxPct = ctxPct
        self.agentSessionId = agentSessionId
        self.priorSessionIds = priorSessionIds
        self.initialPrompt = initialPrompt
        self.parentBranch = parentBranch
        self.diffStat = diffStat
        self.treeStat = treeStat
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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

/// A read-only pane snapshot (the `capture` command). Provider-neutral: just the pane's text,
/// size-capped. `truncated` is true when `text` was cut to the cap. No attach, no resize.
public struct CaptureResult: Codable, Sendable, Equatable {
    public let window: String    // "agent" | "shell-1" | ...
    public let text: String      // captured *visible* pane text, size-capped
    public let truncated: Bool   // true if `text` was cut to the cap
    public init(window: String, text: String, truncated: Bool) {
        self.window = window; self.text = text; self.truncated = truncated
    }
}

public struct ShellTab: Codable, Sendable, Equatable {
    public let window: String
    public let label: String
    public let pwd: String
    public init(window: String, label: String, pwd: String) {
        self.window = window; self.label = label; self.pwd = pwd
    }
    /// Which surface owns this shell — derived purely from its window name.
    public var owner: ShellOwner { ShellOwner(window: window) }
}

/// Which surface owns a shell window, derived purely from its tmux window name — no stored state, so
/// it survives a daemon restart. The phone opens a deterministic `phone-<client8>` window
/// (`BoardModel.phoneShellWindow`); every other shell window (`shell-N`, an inspect shell) is
/// desktop-owned. `agent` is never a shell. This is what lets both surfaces render one shared list
/// while each still live-attaches only the windows it owns (per-client PTY size + stdin — see the
/// shell-sync design note).
public enum ShellOwner: Sendable, Equatable {
    case desktop
    case phone(clientPrefix: String)

    public init(window: String) {
        let prefix = "phone-"
        if window.hasPrefix(prefix) {
            self = .phone(clientPrefix: String(window.dropFirst(prefix.count)))
        } else {
            self = .desktop
        }
    }
    public var isPhone: Bool { if case .phone = self { return true } else { return false } }
}

public struct ShellPanelState: Sendable, Equatable {
    public let windows: [String]
    public let selected: String?
    public var isOpen: Bool { !windows.isEmpty }

    public init(targets: [TmuxTarget], previousSelection: String?) {
        self.init(windows: targets.filter { $0.kind == .shell }.map(\.window),
                  previousSelection: previousSelection)
    }

    /// From a broadcast `ShellTab` set (the `shellsChanged` event) rather than a `sessions` poll.
    public init(shells: [ShellTab], previousSelection: String?) {
        self.init(windows: shells.map(\.window), previousSelection: previousSelection)
    }

    public init(windows: [String], previousSelection: String?) {
        self.windows = windows
        if let previousSelection, windows.contains(previousSelection) {
            self.selected = previousSelection
        } else {
            self.selected = windows.first
        }
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

// MARK: - Tree snapshot (the `tree` command payload)

/// One card's lineage view: its parent ref (from git config), the derived parent *card* id (active
/// card on that branch, if any), and its child branch names. `treeStat` is nil until BT4 computes it.
public struct TreeNode: Codable, Sendable, Equatable {
    public let ref: String
    public let cardId: UUID
    public let repo: String
    public let branch: String
    public let parent: String?         // parent ref string from lineage config; nil = no parent link
    public let parentCardId: UUID?     // derived: active card whose repo+branch == this parent ref
    public let base: String?           // S2-4: recorded rebase anchor OID (from ParentLink.base); nil = no link
    public let children: [String]      // child branch names (durable, card-optional)
    public let treeStat: TreeStat?     // nil in BT1
    public init(ref: String, cardId: UUID, repo: String, branch: String, parent: String?,
                parentCardId: UUID?, base: String? = nil, children: [String], treeStat: TreeStat?) {
        self.ref = ref; self.cardId = cardId; self.repo = repo; self.branch = branch
        self.parent = parent; self.parentCardId = parentCardId; self.base = base
        self.children = children; self.treeStat = treeStat
    }
}

/// The `tree` command result — a lineage snapshot over the requested scope.
public struct TreeSnapshot: Codable, Sendable, Equatable {
    public let nodes: [TreeNode]
    public init(nodes: [TreeNode]) { self.nodes = nodes }
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

// MARK: - Agent-terminal ownership (ephemeral UI coordination — NOT durable card state)

/// Which surface currently owns a card's live `agent` terminal.
public enum AgentTerminalOwnerKind: String, Codable, Sendable, Equatable {
    case desktop, phone
}

/// The ephemeral owner of one card's `agent` window. `epoch` is a monotonic per-card counter that
/// makes stale releases/heartbeats safe: only the holder of the *current* epoch may release or refresh.
public struct AgentTerminalOwner: Codable, Sendable, Equatable {
    public let ownerKind: AgentTerminalOwnerKind
    public let clientId: String       // D3's per-install client id; the owning surface
    public let epoch: Int
    public let cardId: UUID
    public let window: String          // always "agent" in v1; keyed for future windows
    public let updatedAt: Date
    public init(ownerKind: AgentTerminalOwnerKind, clientId: String, epoch: Int,
                cardId: UUID, window: String, updatedAt: Date) {
        self.ownerKind = ownerKind; self.clientId = clientId; self.epoch = epoch
        self.cardId = cardId; self.window = window; self.updatedAt = updatedAt
    }
}

/// Snapshot returned by `agentTerminalOwner` and broadcast on the event stream. `owner == nil` means
/// *available*. `epoch` is the current per-card epoch even when available (monotonic). `stale` is true
/// when an owner exists but hasn't heartbeated within the timeout.
public struct AgentTerminalOwnerState: Codable, Sendable, Equatable {
    public let ref: String
    public let cardId: UUID
    public let window: String
    public let owner: AgentTerminalOwner?
    public let epoch: Int
    public let stale: Bool
    public init(ref: String, cardId: UUID, window: String,
                owner: AgentTerminalOwner?, epoch: Int, stale: Bool) {
        self.ref = ref; self.cardId = cardId; self.window = window
        self.owner = owner; self.epoch = epoch; self.stale = stale
    }
}

/// `takeOverAgentTerminal` result: the new ownership state + the tmux attach target for the caller
/// (the card's `agent` window, reusing the shipped `sessions`→`TmuxTarget` discovery).
public struct TakeOverResult: Codable, Sendable, Equatable {
    public let state: AgentTerminalOwnerState
    public let target: TmuxTarget
    public init(state: AgentTerminalOwnerState, target: TmuxTarget) {
        self.state = state; self.target = target
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
    /// Why the card is waiting (permission vs human-turn) — set alongside `status = .waiting`.
    public var waitReason: WaitReason?
    /// The agent reported a natural turn/task completion, not just an idle notification.
    public var turnCompleted: Bool?
    /// A `/rename` mirror — applied only on a genuine change (see report) so it can't clobber the
    /// re-title-after-restart flow.
    public var sessionName: String?
    public init(seq: UInt64 = 0, ctxPct: Double? = nil, modelId: String? = nil,
                modelDisplay: String? = nil, status: AgentStatus? = nil, desc: String? = nil,
                waitReason: WaitReason? = nil, turnCompleted: Bool? = nil, sessionName: String? = nil) {
        self.seq = seq; self.ctxPct = ctxPct; self.modelId = modelId
        self.modelDisplay = modelDisplay; self.status = status; self.desc = desc
        self.waitReason = waitReason; self.turnCompleted = turnCompleted; self.sessionName = sessionName
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
                waitReason: WaitReason? = nil,
                turnCompleted: Bool? = nil,
                promptText: String? = nil, sessionSource: String? = nil, endReason: String? = nil) {
        let hasSnapshot = seq != 0 || ctxPct != nil || modelId != nil || modelDisplay != nil
            || sessionName != nil || desc != nil || status != nil || waitReason != nil || turnCompleted != nil
        let hasEvent = sessionId != nil || transcriptPath != nil || promptText != nil
            || sessionSource != nil || endReason != nil
        self.init(
            event: hasEvent ? EventReport(sessionId: sessionId, transcriptPath: transcriptPath,
                                          sessionSource: sessionSource, endReason: endReason,
                                          promptText: promptText) : nil,
            snapshot: hasSnapshot ? SnapshotReport(seq: seq, ctxPct: ctxPct, modelId: modelId,
                                                   modelDisplay: modelDisplay, status: status,
                                                   desc: desc, waitReason: waitReason, turnCompleted: turnCompleted,
                                                   sessionName: sessionName) : nil)
    }
}

// MARK: - Activity feed

public enum ActivitySource: String, Codable, Sendable {
    case app, cli, mcp, agent, daemon
}

public enum ActivityKind: String, Codable, Sendable {
    case spawned, moved, archived, statusChanged, dead, recovered, command, warning
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
    /// Ephemeral agent-terminal ownership change. Live-only — NOT ring-replayed (only `.activity`
    /// is). A (re)connecting client reconciles via `agentTerminalOwner(ref)`.
    case agentTerminalOwner(AgentTerminalOwnerState)
    /// Ephemeral shell-window set for one card — broadcast whenever a shell opens/closes on any
    /// surface so every client renders the same set (the shell-sync design). Live-only — NOT
    /// ring-replayed; a (re)connecting client reconciles via the `sessions` RPC in
    /// `refreshShellPanels`. NOT durable card state (`Task` is untouched).
    case shellsChanged(ShellWindowsState)
}

/// The full set of a card's shell windows (excludes `agent`), carried by `Event.shellsChanged`. The
/// daemon recomputes it from tmux (authoritative) after every shell open/close. Each `ShellTab`'s
/// `owner` tells a client which surface owns it.
public struct ShellWindowsState: Codable, Sendable, Equatable {
    public let cardId: UUID
    public let shells: [ShellTab]
    public init(cardId: UUID, shells: [ShellTab]) {
        self.cardId = cardId; self.shells = shells
    }
}

/// One atomic snapshot of everything a client needs to (re)paint the board — collapsing the old
/// `list` + `archivedList` + `getConfig` + `models` + `agents` calls PLUS the per-card `sessions` +
/// `agentTerminalOwner` fan-out (the N+1 that put ~2N round trips on every (re)connect, each shelling
/// to tmux) into a SINGLE round trip. Taken server-side under one pass so shell/owner state is
/// consistent with the task list, and — issued right after `subscribe` — it also closes the
/// snapshot-then-subscribe gap: any event racing the snapshot is either reflected in it or delivered
/// live (apply is idempotent).
public struct BoardSnapshot: Codable, Sendable, Equatable {
    public let tasks: [Task]
    public let archived: [Task]
    public let config: Config
    public let models: [AgentModel]
    public let agents: [AgentInfo]
    /// Per active (non-archived) card, its shell/session snapshot — the bulk form of the `sessions` RPC.
    public let sessions: [CardSessions]
    /// Per active card, its current agent-terminal owner — the bulk form of `agentTerminalOwner`.
    public let owners: [AgentTerminalOwnerState]
    public init(tasks: [Task], archived: [Task], config: Config, models: [AgentModel],
                agents: [AgentInfo], sessions: [CardSessions], owners: [AgentTerminalOwnerState]) {
        self.tasks = tasks; self.archived = archived; self.config = config
        self.models = models; self.agents = agents; self.sessions = sessions; self.owners = owners
    }
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
    /// Scratch spawn: create a fresh throwaway `~/.orchestra/scratch/<id>` dir, set `cwd` to it, and
    /// mark `origin = .scratch`. Takes precedence over `cwd`/worktree. nil/false ⇒ borrowed-or-worktree.
    public var scratch: Bool
    /// Authored fork/fan-out context (the parent slice / handoff summary) for a FRESH spawn. Folded
    /// ahead of `prompt` into the single launch positional in `OrchestraService.spawn` (F1's `ctx.seed`
    /// is the resume-only carrier; a fresh start delivers the seed as the initial prompt). nil ⇒ no seed.
    public var seed: String?
    /// Parent ref to branch from when the card's branch is *created* (BT2 threads it into
    /// `WorktreeManager.ensure`, recording lineage at spawn). nil ⇒ today's HEAD behavior. BT1 only
    /// carries the field on the model; the spawn threading lands in BT2.
    public var base: String?
    public init(prompt: String, repo: String = "", branch: String = "", model: String? = nil,
                startIn: StartIn? = nil, agentId: String? = nil,
                cwd: String? = nil, access: CardAccess = .readWrite, scratch: Bool = false,
                seed: String? = nil, base: String? = nil) {
        self.prompt = prompt; self.repo = repo; self.branch = branch
        self.model = model; self.startIn = startIn; self.agentId = agentId
        self.cwd = cwd; self.access = access; self.scratch = scratch; self.seed = seed
        self.base = base
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
        self.scratch = try c.decodeIfPresent(Bool.self, forKey: .scratch) ?? false
        self.seed = try c.decodeIfPresent(String.self, forKey: .seed)
        self.base = try c.decodeIfPresent(String.self, forKey: .base)
    }
}
