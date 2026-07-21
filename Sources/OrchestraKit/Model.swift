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

/// Why a card is `.waiting` — carried inside `RunState.waiting` on the card's `phase`.
/// Drives which notification trigger the app fires. `.dead` is a separate transition (see `deadReason`).
public enum WaitReason: String, Codable, Sendable {
    case permission   // agent blocked on tool approval (Claude Notification/permission_prompt)
    case humanTurn    // agent genuinely finished its turn / idle, waiting on the human
}

/// Why a card went `dead` — set alongside `status = .dead`, surfaced by the Recovery panel + CLI/MCP.
public enum DeadReason: String, Codable, Sendable {
    case agentExited       // SessionEnd reason exit/logout — the agent quit (mid-life, usually resumable)
    case sessionVanished   // poll liveness reconcile: tmux session gone, no SessionEnd (crash / `tmux kill`)
    case spawnExitedImmediately  // the agent exited during its startup grace — a launch abort, not a mid-run
                                 // vanish; the dying pane's final output is captured into `deadDetail`.
    case rebootUnrevived   // reboot sweep couldn't auto-revive (no id / transcript gone / resume failed at boot)
    case resumeFailed      // a `resume` attempt (auto or user "Try resume") failed — see `deadDetail`
    case spawnFailed       // the initial spawn never came up (worktree/launch failure before first life)
    case resourceExhausted // the HOST ran out of a launch resource (PTYs / processes / fds) — nothing could
                           // start a terminal, so this is about the machine, not the card. TRANSIENT: the
                           // card is resumable the moment the resource is reclaimed. See `deadResource`.
}

/// The running sub-state of a `live` card — the mid-life detail that used to live in `status`/`waitReason`.
/// `.running` = the agent is actively working; `.waiting` = blocked, carrying *why* (see `WaitReason`).
public enum RunState: Codable, Equatable, Sendable {
    case running
    case waiting(WaitReason)

    private enum CodingKeys: String, CodingKey { case name, detail }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .running: try c.encode("running", forKey: .name)
        case .waiting(let reason):
            try c.encode("waiting", forKey: .name)
            try c.encode(reason, forKey: .detail)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        switch name {
        case "running": self = .running
        case "waiting": self = .waiting(try c.decode(WaitReason.self, forKey: .detail))
        default:
            throw DecodingError.dataCorruptedError(forKey: .name, in: c,
                debugDescription: "unknown RunState case \"\(name)\"")
        }
    }
}

/// The card's persisted lifecycle phase — the convergence SSOT that replaces the ad-hoc
/// `status`/`waitReason`/`dead` triple (Stage 2). Every spawn enters at `.creatingWorktree`
/// ("materialize cwd"), then `.launching`, then `.live(_)`; `.relaunching` covers a restart/resume in
/// flight; `.dead(_)`/`.archived(_)` are terminal. `.archived(teardownComplete:)` distinguishes an
/// archive whose worktree/session teardown is still pending from one fully torn down.
///
/// Wire form is a `{ "name": <case>, "detail": <associated value> }` object — `detail` present only for
/// the cases that carry a payload (`live`, `dead`, `archived`); nested enums (`RunState`, `WaitReason`)
/// encode recursively, `DeadReason` as its raw `String`, and `archived`'s Bool directly.
public enum Phase: Codable, Equatable, Sendable {
    case creatingWorktree      // materialize the cwd (worktree / scratch / borrow) — ALL spawns enter here
    case launching             // cwd ready, bringing the agent session up
    case live(RunState)        // the agent is up; sub-state in `RunState`
    case relaunching           // a restart/resume is in flight
    case dead(DeadReason)      // terminal-ish: session gone, awaiting recovery (see `DeadReason`)
    case archived(teardownComplete: Bool)  // off the board; `teardownComplete` = worktree/session torn down

    /// Coarse phase discriminant for stepper dispatch (Stage 4) + terminal/bump checks — flattens the
    /// `archived` Bool into two kinds so callers can switch without unpacking associated values.
    public enum Kind: String, Sendable {
        case creatingWorktree, launching, live, relaunching, dead, archivedPending, archivedComplete
    }

    public var kind: Kind {
        switch self {
        case .creatingWorktree: return .creatingWorktree
        case .launching: return .launching
        case .live: return .live
        case .relaunching: return .relaunching
        case .dead: return .dead
        case .archived(let done): return done ? .archivedComplete : .archivedPending
        }
    }

    /// A phase from which the card does not run again on its own — `dead(*)` or `archived(*)`.
    public var isTerminal: Bool {
        switch self {
        case .dead, .archived: return true
        default: return false
        }
    }

    private enum CodingKeys: String, CodingKey { case name, detail }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .creatingWorktree: try c.encode("creatingWorktree", forKey: .name)
        case .launching:        try c.encode("launching", forKey: .name)
        case .relaunching:      try c.encode("relaunching", forKey: .name)
        case .live(let run):
            try c.encode("live", forKey: .name)
            try c.encode(run, forKey: .detail)
        case .dead(let reason):
            try c.encode("dead", forKey: .name)
            try c.encode(reason, forKey: .detail)
        case .archived(let done):
            try c.encode("archived", forKey: .name)
            try c.encode(done, forKey: .detail)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        switch name {
        case "creatingWorktree": self = .creatingWorktree
        case "launching":        self = .launching
        case "relaunching":      self = .relaunching
        case "live":             self = .live(try c.decode(RunState.self, forKey: .detail))
        case "dead":             self = .dead(try c.decode(DeadReason.self, forKey: .detail))
        case "archived":         self = .archived(teardownComplete: try c.decode(Bool.self, forKey: .detail))
        default:
            throw DecodingError.dataCorruptedError(forKey: .name, in: c,
                debugDescription: "unknown Phase case \"\(name)\"")
        }
    }
}

extension Phase {
    /// The coarse UI classification — the single `phase → display` map. `Task.phaseDisplay` delegates here
    /// so a phase with no `Task` (e.g. the `displayState` contract) classifies identically.
    public var displayKey: PhaseDisplayKey {
        switch self {
        case .creatingWorktree:            return .starting
        case .launching:                   return .launching
        case .relaunching:                 return .relaunching
        case .live(.running):              return .running
        case .live(.waiting(.permission)): return .needsPermission
        case .live(.waiting(.humanTurn)):  return .idle
        case .archived:                    return .done
        case .dead:                        return .dead
        }
    }
}

/// A coarse UI label for a card's `phase` — the display-only classification the board cells, detail
/// headers, and status pills render. Deliberately **non-Codable and non-wire**: it is derived from
/// `phase` on demand (`Task.phaseDisplay`) and never persisted, so the display vocabulary can evolve
/// without touching the durable model. The being-born phases are surfaced honestly (a spawning card
/// reads `.starting`/`.launching`, not a fake `.running`).
public enum PhaseDisplayKey: String, Sendable, Equatable, CaseIterable {
    case starting        // .creatingWorktree — materializing the cwd
    case launching       // .launching — bringing the session up
    case relaunching     // .relaunching — a restart/resume in flight
    case running         // .live(.running)
    case idle            // .live(.waiting(.humanTurn)) — finished its turn, waiting on the human
    case needsPermission // .live(.waiting(.permission)) — blocked on tool approval
    case dead            // .dead — needs recovery
    case done            // .archived — finished + retired
}

extension PhaseDisplayKey {
    /// The canonical human label — the ONE place `phaseDisplay → label` text lives, shared by the GUI
    /// (`Theme.statusLabel`), the CLI, and `DisplayState.label`.
    public var label: String {
        switch self {
        case .starting:        return "Starting"
        case .launching:       return "Launching"
        case .relaunching:     return "Relaunching"
        case .running:         return "Running"
        case .idle:            return "Waiting"
        case .needsPermission: return "Waiting"
        case .dead:            return "Dead"
        case .done:            return "Done"
        }
    }
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
    /// Optional because a client can hold an `AgentInfo` it built ITSELF, before the daemon has
    /// answered — and only the daemon knows what an adapter actually advertises. The presets are adapter
    /// extensions living in OrchestraCore, which client-safe Kit cannot reference, so a client has no
    /// honest value to put here: nil means "not told yet", not "no capabilities".
    /// Readers already treat absence as a safe default — see `BoardStore.capabilities(for:)`.
    public let capabilities: AgentCapabilities?

    // Deliberately NOT defaulted: a daemon-side call site builds this FROM an adapter and must pass that
    // adapter's own capabilities, so every site states its intent rather than defaulting to nil by
    // omission.
    public init(id: String, name: String, icon: String, models: [AgentModel],
                capabilities: AgentCapabilities?) {
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
/// until `Task.parentBranch` is set. See `docs/09-design-decisions.md` (§ code review on the board — axis 7).
public enum DiffBase: String, Codable, Sendable { case working, branch, parent }

/// The diff baselines a card offers (design §3 Diff): **Working · Branch · Parent** — `.parent` only for a
/// stacked card that carries a `parentBranch` (falls back to Branch until stacked-branches sets it). Pure
/// so the Diff tab and its tests agree on when Parent appears. Shared by the desktop DiffInspectorView and
/// the phone DiffTab (both used to carry their own copy).
public func diffBaselines(parentBranch: String?) -> [DiffBase] {
    parentBranch != nil ? [.working, .branch, .parent] : [.working, .branch]
}

/// Human label for a diff baseline (segmented control). S3-3: pass `parentBranch` to name the parent
/// branch so a parent-relative diff is legible (two adjacent cards' `+N −M` can baseline against
/// different parents with no other indicator).
public func diffBaselineLabel(_ base: DiffBase, parentBranch: String? = nil) -> String {
    switch base {
    case .working: return "Working"
    case .branch:  return "Branch"
    case .parent:  return parentBranch.map { "Parent (\($0))" } ?? "Parent"
    }
}

// MARK: - Tree (branch-tree lineage)

/// A child card's lineage state relative to its parent branch. Daemon-maintained like `DiffStat`;
/// nil until the parent-tree machinery (BT4) computes it. `inSync` = recorded base == parent tip;
/// `stale` = parent advanced (the `↓N` badge); `restackNeeded` = recorded base is no longer the
/// parent tip's ancestor (parent rewrote/shipped); `mergeRequested` = the child sent a merge-request
/// and is waiting on its (live) parent to squash-merge it (O2 — the "waiting" badge, sticky until
/// `shipped`/`synced`/`set-parent` clears it). (Replaces the never-produced `parentMerged`, S4.)
///
/// Giving up on a merge-request is deliberately NOT a case here — it rides on `TreeStat.mergeStalled`.
/// See that field for why.
public enum TreeState: String, Codable, Sendable { case inSync, stale, restackNeeded, mergeRequested }

/// Per-child tree status for the card face (the `↓N` badge + restack signal). Small + persisted on
/// `Task`, exactly like `DiffStat`.
public struct TreeStat: Codable, Sendable, Equatable {
    public var state: TreeState
    public var behind: Int            // commits the parent is ahead of the recorded base (the ↓N badge)
    public var parentIsRemote: Bool
    /// Reminders sent for a pending merge-request (not counting the t=0 request). Persisted, not held in the
    /// timer Task: `rebuildMergeRequestNudges()` re-arms every pending card at boot, so an in-memory counter
    /// would reset each restart and the give-up cap would never fire.
    public var nudges: Int
    /// The merge-request was given up on — the parent ignored every reminder and the loop stopped. Cleared by
    /// `shipped` / `synced` / `set-parent`, or by re-sending the merge-request.
    ///
    /// A FLAG, not a `TreeState` case, for two reasons — either fatal alone:
    /// 1. It is orthogonal to `state`. As a state it froze the recompute funnel (which skips a card wearing a
    ///    sticky merge badge), so a stalled child stopped tracking its parent entirely — no ↓N, and no
    ///    "parent moved ahead" nudge. As a flag, `state` keeps tracking underneath.
    /// 2. It cannot be an unknown rawValue on disk. `Task` decodes `treeStat` with `decodeIfPresent` (which
    ///    rethrows) and `TaskStore.FailableTask` DROPS a throwing record — so a new `TreeState` rawValue would
    ///    make any older binary silently lose the whole card. An unknown *key* is ignored; a rawValue is fatal.
    public var mergeStalled: Bool

    public init(state: TreeState, behind: Int = 0, parentIsRemote: Bool = false,
                nudges: Int = 0, mergeStalled: Bool = false) {
        self.state = state; self.behind = behind; self.parentIsRemote = parentIsRemote
        self.nudges = nudges; self.mergeStalled = mergeStalled
    }

    // Hand-rolled: a synthesized decode would throw `keyNotFound` on the new fields for every card persisted
    // before them — and `Task`'s `decodeIfPresent` rethrows, so FailableTask would DROP those cards. `state`
    // is `try?`-guarded per the convention in `Task.init(from:)`: a garbage rawValue defaults, never throws.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.state = (try? c.decode(TreeState.self, forKey: .state)) ?? .inSync
        self.behind = try c.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        self.parentIsRemote = try c.decodeIfPresent(Bool.self, forKey: .parentIsRemote) ?? false
        self.nudges = try c.decodeIfPresent(Int.self, forKey: .nudges) ?? 0
        self.mergeStalled = try c.decodeIfPresent(Bool.self, forKey: .mergeStalled) ?? false
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
    public var deadReason: DeadReason?  // set with `phase = .dead(_)`; carries the terminal reason
    public var deadDetail: String?      // optional human detail for `.resumeFailed`
    /// WHICH host resource ran out, sampled on the affected host when `deadReason == .resourceExhausted`.
    /// Structured (not parsed back out of `deadDetail`) so every client — Mac, iOS, CLI — can name the
    /// resource and its numbers, while `deadDetail` keeps the raw tmux/pane evidence for debugging.
    /// Additive-optional Codable (mirrors `pendingSeed`). nil for every other death.
    public var deadResource: HostResourceReport?
    /// Persisted lifecycle phase — the convergence SSOT (Stage 2). The sole source of running/waiting/
    /// dead/archived truth: `status`/`waitReason` were retired into `phase` + `RunState` (Stage 2 flag-day).
    public var phase: Phase
    /// Monotonic per-card session generation — bumped on each (re)launch so stale-session signals
    /// (liveness polls, late hooks) from a superseded generation can be fenced out.
    public var sessionEpoch: Int
    /// When `phase` last changed — drives phase-relative timers (bump/nudge) + terminal dwell checks.
    public var phaseChangedAt: Date
    /// Immutable cutoff for discovering an unseeded agent session. Stamped when a fresh launch begins and
    /// retained if the N=3 fallback reaches live before metadata arrives, so stale cwd rollouts cannot be
    /// mistaken for the delayed session. Cleared when a session id binds. Encoded as fractional Unix seconds
    /// rather than the store's whole-second ISO-8601 dates, because rounding down would widen the bind window.
    public var sessionDiscoverySince: Date?
    /// Fork/fan-out/handoff seed staged for the NEXT (re)launch, delivered once then cleared. nil ⇒ none.
    public var pendingSeed: String?
    /// A `--model` re-seat staged for the NEXT (re)launch (restart/handoff/resume), delivered once then
    /// cleared on the `.live` landing — the launch INTENT, exactly like `pendingSeed`. It is what
    /// `finishLaunch` builds the argv from, and it is deliberately ABSENT from `applyReportFields`: the
    /// report path owns `model` and is not epoch-fenced, so the dying session's last statusline can (and
    /// does) revert `model` in the window between the intent-only verb and the stepper's relaunch. Holding
    /// the request here is what stops that report from silently erasing the override. nil ⇒ no override.
    public var pendingModel: String?
    /// The RAW normalized base string exactly as `spawn` received it (`input.base` after the refs/heads
    /// strip). Carried on the card so a reconciler-driven `materialize` can re-derive the base
    /// classification (`RemoteParentRef.parse`) after a restart — a remote base (`origin/<b>` / `pr#<N>`)
    /// survives deterministically. Set at spawn's `store.create`, read by `materialize`, cleared on the
    /// `→.launching` transition. nil ⇒ HEAD / no base. Additive-optional Codable (mirrors `pendingSeed`).
    public var spawnBase: String?
    /// When a card's queued delivery has been stuck (repeated failed attempts past the age threshold),
    /// stamped by the reconciler arm (B4) and cleared by a confirmed delivery / `send`. Persisted so the
    /// stuck state survives a daemon restart. Additive-optional Codable (mirrors `pendingSeed`); UI-less
    /// until B5b surfaces it — nothing reads it in B2.
    public var deliveryStuckSince: Date?
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
        deadReason: DeadReason? = nil,
        deadDetail: String? = nil,
        deadResource: HostResourceReport? = nil,
        phase: Phase = .live(.running),
        sessionEpoch: Int = 0,
        phaseChangedAt: Date = Date(),
        sessionDiscoverySince: Date? = nil,
        pendingSeed: String? = nil,
        pendingModel: String? = nil,
        spawnBase: String? = nil,
        deliveryStuckSince: Date? = nil,
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
        self.deadReason = deadReason
        self.deadDetail = deadDetail
        self.deadResource = deadResource
        self.phase = phase
        self.sessionEpoch = sessionEpoch
        self.phaseChangedAt = phaseChangedAt
        self.sessionDiscoverySince = sessionDiscoverySince
        self.pendingSeed = pendingSeed
        self.pendingModel = pendingModel
        self.spawnBase = spawnBase
        self.deliveryStuckSince = deliveryStuckSince
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

    // Custom decode that ALSO performs the one-time on-disk migration from the retired
    // `status`/`waitReason`/`archived` triple to `phase` (Stage 2 flag-day). Two properties:
    //   1. Best-effort/lossless: `id` is the ONLY required field — every other field is
    //      `decodeIfPresent` with a safe default, so a partial/garbage legacy record is *kept* (as a
    //      safe-terminal card) rather than throwing and stranding the whole board to `.bak`.
    //   2. Migrating: when the `phase` key is ABSENT (a pre-Stage-2 record) `phase` is seeded from the
    //      legacy `status`/`waitReason`/`deadReason`/`archived` keys (read leniently as `String?` so a
    //      garbage status can never abort the record). A record that already has `phase` decodes it
    //      directly — no migration. Encode stays synthesized (no `status`/`waitReason` on the wire).
    private enum CodingKeys: String, CodingKey {
        case id, title, titleProvisional, desc, repo, branch, parentBranch, cwd, origin, access
        case agentId, model, startIn, column, order, deadReason, deadDetail, deadResource
        case phase, sessionEpoch, phaseChangedAt, sessionDiscoverySince, pendingSeed, pendingModel, spawnBase
        case deliveryStuckSince
        case ctxPct, diffStat, treeStat, agentSessionId, priorSessionIds, initialPrompt, archived
        case createdAt, updatedAt
        // Decode-only legacy keys — read to migrate a pre-Stage-2 record; never encoded.
        case status, waitReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The sole required field: an id-less record is genuinely unrecoverable (the only drop case).
        self.id = try c.decode(UUID.self, forKey: .id)
        // Everything else is best-effort — a missing/partial field falls back to a safe default so the
        // card is kept, not dropped.
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? "(recovered)"
        self.titleProvisional = try c.decodeIfPresent(Bool.self, forKey: .titleProvisional) ?? false
        self.desc = try c.decodeIfPresent(String.self, forKey: .desc) ?? ""
        self.repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        self.branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        self.parentBranch = try c.decodeIfPresent(String.self, forKey: .parentBranch)
        self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        // Enum/decodable fields are `try?`-guarded (not just `decodeIfPresent`): a present-but-garbage
        // rawValue (a renamed/removed case) must DEFAULT to the same safe value the memberwise init uses,
        // never throw — else one garbage field would drop an otherwise-recoverable record. Only `id` (above)
        // is allowed to throw, and its absence is the sole drop case.
        self.origin = (try? c.decodeIfPresent(CardOrigin.self, forKey: .origin)) ?? .worktree
        self.access = (try? c.decodeIfPresent(CardAccess.self, forKey: .access)) ?? .readWrite
        self.agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? "claude-code"
        self.model = (try? c.decodeIfPresent(AgentModel.self, forKey: .model)) ?? AgentModel(id: "unknown")
        self.startIn = (try? c.decodeIfPresent(StartIn.self, forKey: .startIn)) ?? .impl
        self.column = (try? c.decodeIfPresent(Column.self, forKey: .column)) ?? .impl
        self.order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        self.deadReason = (try? c.decodeIfPresent(DeadReason.self, forKey: .deadReason)) ?? nil
        self.deadDetail = try c.decodeIfPresent(String.self, forKey: .deadDetail)
        self.deadResource = (try? c.decodeIfPresent(HostResourceReport.self, forKey: .deadResource)) ?? nil
        self.ctxPct = try c.decodeIfPresent(Double.self, forKey: .ctxPct) ?? 0
        self.diffStat = try c.decodeIfPresent(DiffStat.self, forKey: .diffStat)
        // `try?`-guarded like the enum fields above (it contains one): a garbage `TreeState` rawValue must
        // cost the badge, never the whole record (`decodeIfPresent` rethrows; FailableTask drops the card).
        self.treeStat = (try? c.decodeIfPresent(TreeStat.self, forKey: .treeStat)) ?? nil
        self.agentSessionId = try c.decodeIfPresent(String.self, forKey: .agentSessionId)
        self.priorSessionIds = try c.decodeIfPresent([String].self, forKey: .priorSessionIds) ?? []
        self.initialPrompt = try c.decodeIfPresent(String.self, forKey: .initialPrompt) ?? ""
        let archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        self.archived = archived
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.sessionEpoch = try c.decodeIfPresent(Int.self, forKey: .sessionEpoch) ?? 0
        self.phaseChangedAt = try c.decodeIfPresent(Date.self, forKey: .phaseChangedAt)
            ?? (try c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? Date()
        // This field was introduced after the board's original date shape. A fractional Unix timestamp
        // preserves the exact launch boundary; accept an ISO-8601 string too so an intermediate build that
        // wrote it through the default Date encoder remains recoverable.
        if let seconds = try? c.decode(Double.self, forKey: .sessionDiscoverySince) {
            self.sessionDiscoverySince = Date(timeIntervalSince1970: seconds)
        } else {
            self.sessionDiscoverySince = try? c.decode(Date.self, forKey: .sessionDiscoverySince)
        }
        self.pendingSeed = try c.decodeIfPresent(String.self, forKey: .pendingSeed)
        self.pendingModel = try c.decodeIfPresent(String.self, forKey: .pendingModel)
        self.spawnBase = try c.decodeIfPresent(String.self, forKey: .spawnBase)
        self.deliveryStuckSince = try c.decodeIfPresent(Date.self, forKey: .deliveryStuckSince)
        // Migration: a record with a `phase` key is post-Stage-2 — decode it. Otherwise seed `phase`
        // from the legacy triple (leniently, so a garbage status still decodes to a safe terminal).
        if let phase = try c.decodeIfPresent(Phase.self, forKey: .phase) {
            self.phase = phase
        } else {
            self.phase = Task.migratedPhase(
                status: try? c.decodeIfPresent(String.self, forKey: .status),
                waitReason: try? c.decodeIfPresent(String.self, forKey: .waitReason),
                deadReason: deadReason, archived: archived)
        }
    }

    /// Seed `phase` from a pre-Stage-2 record's legacy fields. Precedence top-to-bottom; a nil/unknown
    /// `waitReason` on a waiting card is common (idle cards) so it maps to `.humanTurn`, never a fake
    /// wait; a nil/unrecognized `status` maps to the safe terminal `.dead(.rebootUnrevived)` (never throws).
    static func migratedPhase(status: String?, waitReason: String?,
                              deadReason: DeadReason?, archived: Bool) -> Phase {
        if archived { return .archived(teardownComplete: true) }
        switch status {
        case "running": return .live(.running)
        case "waiting": return .live(.waiting(WaitReason(rawValue: waitReason ?? "") ?? .humanTurn))
        case "dead":    return .dead(deadReason ?? .agentExited)
        default:        return .dead(.rebootUnrevived)   // nil / legacy "done" / unrecognized → safe recoverable terminal
        }
    }

    // Custom encode (the decode-only legacy keys make Codable synthesis impossible). Emits every
    // stored property to its key — and deliberately NOT `status`/`waitReason`, which no longer exist.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(titleProvisional, forKey: .titleProvisional)
        try c.encode(desc, forKey: .desc)
        try c.encode(repo, forKey: .repo)
        try c.encode(branch, forKey: .branch)
        try c.encodeIfPresent(parentBranch, forKey: .parentBranch)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(origin, forKey: .origin)
        try c.encode(access, forKey: .access)
        try c.encode(agentId, forKey: .agentId)
        try c.encode(model, forKey: .model)
        try c.encode(startIn, forKey: .startIn)
        try c.encode(column, forKey: .column)
        try c.encode(order, forKey: .order)
        try c.encodeIfPresent(deadReason, forKey: .deadReason)
        try c.encodeIfPresent(deadDetail, forKey: .deadDetail)
        try c.encodeIfPresent(deadResource, forKey: .deadResource)
        try c.encode(phase, forKey: .phase)
        try c.encode(sessionEpoch, forKey: .sessionEpoch)
        try c.encode(phaseChangedAt, forKey: .phaseChangedAt)
        try c.encodeIfPresent(sessionDiscoverySince?.timeIntervalSince1970, forKey: .sessionDiscoverySince)
        try c.encodeIfPresent(pendingSeed, forKey: .pendingSeed)
        try c.encodeIfPresent(pendingModel, forKey: .pendingModel)
        try c.encodeIfPresent(spawnBase, forKey: .spawnBase)
        try c.encodeIfPresent(deliveryStuckSince, forKey: .deliveryStuckSince)
        try c.encode(ctxPct, forKey: .ctxPct)
        try c.encodeIfPresent(diffStat, forKey: .diffStat)
        try c.encodeIfPresent(treeStat, forKey: .treeStat)
        try c.encodeIfPresent(agentSessionId, forKey: .agentSessionId)
        try c.encode(priorSessionIds, forKey: .priorSessionIds)
        try c.encode(initialPrompt, forKey: .initialPrompt)
        try c.encode(archived, forKey: .archived)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
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

    /// The `report()` field-delta write: overlay exactly the fields `report()` owns from a
    /// freshly-computed snapshot `s`, leaving every other (possibly concurrently-mutated) field at
    /// self's current value. Centralizes report's ownership so a whole-object write can't clobber.
    /// NOTE: `phase`/`deadReason`/`deadDetail` are deliberately NOT overlaid here — the `transition()`
    /// funnel is the sole writer of those (Stage 2 convergence); `report()` routes the phase change
    /// through it separately, so a whole-object overlay must never clobber a concurrent funnel write.
    public mutating func applyReportFields(from s: Task) {
        let sessionIdChanged = agentSessionId != s.agentSessionId
        agentSessionId = s.agentSessionId
        priorSessionIds = s.priorSessionIds
        // The cutoff belongs to lifecycle transitions, not ordinary telemetry. A report clears it only
        // when it actually binds or rolls the session id; otherwise a stale telemetry snapshot could erase
        // a cutoff a concurrent relaunch just recorded.
        if sessionIdChanged, agentSessionId != nil { sessionDiscoverySince = nil }
        desc = s.desc
        titleProvisional = s.titleProvisional
        title = s.title
        ctxPct = s.ctxPct
        model = s.model
    }

    // MARK: - Derived phase views (non-wire; computed from `phase` on demand)

    /// The coarse UI label for this card, derived from `phase`. The one place `phase → display`
    /// classification lives, so board cells / detail headers / status pills no longer each re-map it.
    public var phaseDisplay: PhaseDisplayKey { phase.displayKey }

    /// Why this card is waiting, derived from `phase` — `nil` unless it is `.live(.waiting(_))`.
    public var waitReason: WaitReason? {
        if case .live(.waiting(let r)) = phase { return r } else { return nil }
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

/// Outcome of the `send` verb (B5a): the message's id (the one the caller minted or that a client seam
/// stamped) and a fresh snapshot of the target card. Returning the id lets a client correlate a retry
/// with its original — the send contract is idempotent on that id — and the card snapshot mirrors how
/// `move`/`spawn` return the affected card.
public struct SendResult: Codable, Sendable, Equatable {
    public let messageId: UUID
    public let card: Task
    public init(messageId: UUID, card: Task) { self.messageId = messageId; self.card = card }
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
    /// The agent's observed run-state — `.running` or `.waiting(reason)`. Replaces the retired
    /// `status`/`waitReason` pair; `report()` maps a present `run` onto a `.live(run)` phase write.
    public var run: RunState?
    public var desc: String?
    /// The agent reported a natural turn/task completion, not just an idle notification.
    public var turnCompleted: Bool?
    /// A `/rename` mirror — applied only on a genuine change (see report) so it can't clobber the
    /// re-title-after-restart flow.
    public var sessionName: String?
    public init(seq: UInt64 = 0, ctxPct: Double? = nil, modelId: String? = nil,
                modelDisplay: String? = nil, run: RunState? = nil, desc: String? = nil,
                turnCompleted: Bool? = nil, sessionName: String? = nil) {
        self.seq = seq; self.ctxPct = ctxPct; self.modelId = modelId
        self.modelDisplay = modelDisplay; self.run = run; self.desc = desc
        self.turnCompleted = turnCompleted; self.sessionName = sessionName
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
                sessionName: String? = nil, desc: String? = nil, run: RunState? = nil,
                turnCompleted: Bool? = nil,
                promptText: String? = nil, sessionSource: String? = nil, endReason: String? = nil) {
        let hasSnapshot = seq != 0 || ctxPct != nil || modelId != nil || modelDisplay != nil
            || sessionName != nil || desc != nil || run != nil || turnCompleted != nil
        let hasEvent = sessionId != nil || transcriptPath != nil || promptText != nil
            || sessionSource != nil || endReason != nil
        self.init(
            event: hasEvent ? EventReport(sessionId: sessionId, transcriptPath: transcriptPath,
                                          sessionSource: sessionSource, endReason: endReason,
                                          promptText: promptText) : nil,
            snapshot: hasSnapshot ? SnapshotReport(seq: seq, ctxPct: ctxPct, modelId: modelId,
                                                   modelDisplay: modelDisplay, run: run,
                                                   desc: desc, turnCompleted: turnCompleted,
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

/// Every event notification to clients is wrapped with the board `rev` at emit, so a client can
/// detect a gap (a missed event) and resync. Ephemeral events carry the current board rev.
public struct EventEnvelope: Codable, Sendable, Equatable {
    public let rev: Int
    public let event: Event
    public init(rev: Int, event: Event) { self.rev = rev; self.event = event }
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
    /// The board's `rev` at the moment this snapshot was taken (`TaskStore.currentRev`) — lets a
    /// (re)connecting client detect a gap between this snapshot and subsequently-received events.
    public let rev: Int
    public let tasks: [Task]
    public let archived: [Task]
    public let config: Config
    public let models: [AgentModel]
    public let agents: [AgentInfo]
    /// Per active (non-archived) card, its shell/session snapshot — the bulk form of the `sessions` RPC.
    public let sessions: [CardSessions]
    /// Per active card, its current agent-terminal owner — the bulk form of `agentTerminalOwner`.
    public let owners: [AgentTerminalOwnerState]
    public init(rev: Int, tasks: [Task], archived: [Task], config: Config, models: [AgentModel],
                agents: [AgentInfo], sessions: [CardSessions], owners: [AgentTerminalOwnerState]) {
        self.rev = rev
        self.tasks = tasks; self.archived = archived; self.config = config
        self.models = models; self.agents = agents; self.sessions = sessions; self.owners = owners
    }
}

// MARK: - Worktree registry result

/// The result of `WorktreeRegistry.ensure`/`ensureBorrow`: the materialized worktree path plus the two
/// signals spawn/recovery still need (`created` = a fresh checkout was cut this call; `branchExisted` =
/// the branch pre-existed so lineage config may carry).
public struct Worktree: Sendable, Equatable {
    public let path: String
    public let created: Bool
    public let branchExisted: Bool
    public init(path: String, created: Bool, branchExisted: Bool) {
        self.path = path; self.created = created; self.branchExisted = branchExisted
    }
}

// MARK: - Spawn input

public struct SpawnInput: Codable, Sendable, Equatable {
    /// Client-minted card id — a REQUIRED wire field (no back-compat for id-less spawns). Every client
    /// (BoardStore / CLI / MCP bridge) mints or forwards it; the daemon dedups atomically on it
    /// (`TaskStore.createIfAbsent`), so reusing the SAME id on a manual retry is idempotent. No default:
    /// each construction site must supply an id explicitly (a bare per-call mint isn't retry-safe).
    public var id: UUID
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
    /// `WorktreeRegistry.ensure`, recording lineage at spawn). nil ⇒ today's HEAD behavior. BT1 only
    /// carries the field on the model; the spawn threading lands in BT2.
    public var base: String?
    public init(id: UUID, prompt: String, repo: String = "", branch: String = "", model: String? = nil,
                startIn: StartIn? = nil, agentId: String? = nil,
                cwd: String? = nil, access: CardAccess = .readWrite, scratch: Bool = false,
                seed: String? = nil, base: String? = nil) {
        self.id = id
        self.prompt = prompt; self.repo = repo; self.branch = branch
        self.model = model; self.startIn = startIn; self.agentId = agentId
        self.cwd = cwd; self.access = access; self.scratch = scratch; self.seed = seed
        self.base = base
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)          // required: no id-less spawn on the wire
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
