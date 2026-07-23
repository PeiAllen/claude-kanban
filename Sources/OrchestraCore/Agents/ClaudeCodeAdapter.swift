import Foundation

/// The built-in Claude Code adapter. Builds argv for a fresh `start` (seeds `--session-id`, delivers
/// the initial prompt as a launch positional arg) and `resume` (re-attaches a specific session by id,
/// no prompt), and resolves the agent-native session id + transcript for `sessions`.
public struct ClaudeCodeAdapter: Adapter {
    public let id = "claude-code"
    public let name = "Claude Code"
    public let icon = "sparkle"
    public let bin = "claude"
    public let enabled = true

    /// Claude Code's shipped seam behavior, frozen as the descriptor (A1).
    public var capabilities: AgentCapabilities { .claudeCode }

    /// B3 — cold-path resume-modal suppression. A machine-driven `claude --resume` on an old
    /// (> ~70min) AND large (> ~100k tokens) session opens a "Resume from summary/full" modal INSTEAD of
    /// running the seed argv; with no human to answer it, the resume deadlocks and swallows the seed (two
    /// live cards were observed parked at it). Set both thresholds impossibly high so the modal never
    /// triggers. FAIL-SOFT by construction: these are undocumented internals a differing build ignores
    /// harmlessly, and if the modal still appears the readiness await times out → the lease survives →
    /// the arm retries / stuck-flags (never a silent swallow). Agent-agnostic: this is the `Adapter.env`
    /// seam (Codex uses it for `CODEX_HOME`); other adapters return nothing.
    public var env: [String: String] {
        ["CLAUDE_CODE_RESUME_THRESHOLD_MINUTES": "1000000",
         "CLAUDE_CODE_RESUME_TOKEN_THRESHOLD": "1000000"]
    }

    /// Allow tests to inject a fake binary (the fake-agent fixture) without spawning real Claude.
    let binOverride: String?
    /// Test-only home injection for the opt-in global MCP installer; production reads the user's HOME.
    let claudeHomeOverride: String?

    public init(binOverride: String? = nil, claudeHome: String? = nil) {
        self.binOverride = binOverride
        self.claudeHomeOverride = claudeHome
    }

    private var binary: String { binOverride ?? bin }
    private var claudeHome: String { claudeHomeOverride ?? Config.home }

    /// Claude Code's selectable models + their OFFLINE context windows / capability flags, from the
    /// vendored `Resources/claude-code-models.json` (PR-updated, no network). The hardcoded list is a
    /// last-resort fallback so `models()` is never empty if the resource fails to bundle.
    public func models() -> [AgentModel] {
        let table = ModelCatalog.load("claude-code-models")
        return table.isEmpty ? Self.fallbackModels : table
    }

    private static let fallbackModels: [AgentModel] = [
        AgentModel(id: "claude-opus-4-8", displayName: "Opus 4.8", family: "claude"),
        AgentModel(id: "claude-fable-5", displayName: "Fable 5", family: "claude"),
        AgentModel(id: "claude-sonnet-5", displayName: "Sonnet 5", family: "claude"),
        AgentModel(id: "claude-haiku-4-5", displayName: "Haiku 4.5", family: "claude"),
    ]

    public func newSessionId() -> String? { UUID().uuidString.lowercased() }

    // MARK: telemetry parse (hooksPush) — relocated from the `orchestra` CLI `ReportHelper.map`.

    /// Claude telemetry is `hooksPush`: the `_report` transport pushes each hook event (kind + JSON
    /// payload); this converts it to a normalized two-tier `StatusReport`. Byte-identical to the former
    /// CLI `ReportHelper.map` so `ReportTests` and live Claude reporting are unchanged. Claude has no
    /// `fileTail` transport, so any non-`hooksPush` raw returns nil.
    public func parse(_ raw: RawTelemetry) -> StatusReport? {
        guard case let .hooksPush(kind, p) = raw else { return nil }
        switch kind {
        case "statusline":
            let seq = DispatchTime.now().uptimeNanoseconds
            return StatusReport(
                seq: seq,
                sessionId: p["session_id"]?.stringValue,
                transcriptPath: p["transcript_path"]?.stringValue,
                ctxPct: p["context_window"]?["used_percentage"]?.doubleValue,
                modelId: p["model"]?["id"]?.stringValue,            // launch id (for resume/restart)
                modelDisplay: p["model"]?["display_name"]?.stringValue,  // UI label only
                sessionName: p["session_name"]?.stringValue)
        case "session":
            return StatusReport(
                sessionId: p["session_id"]?.stringValue,
                transcriptPath: p["transcript_path"]?.stringValue,
                sessionSource: p["source"]?.stringValue)
        case "prompt":
            return StatusReport(run: .running, promptText: p["prompt"]?.stringValue)
        case "pretool", "posttool":
            let tool = p["tool_name"]?.stringValue ?? "tool"
            return StatusReport(desc: toolDesc(tool: tool, input: p["tool_input"]), run: .running)
        case "notification":
            // The Notification hook: permission_prompt is the only "you're blocking me" case; everything
            // else (idle_prompt, …) is a genuine human-turn wait.
            let reason: WaitReason = p["notification_type"]?.stringValue == "permission_prompt"
                ? .permission : .humanTurn
            return StatusReport(desc: p["message"]?.stringValue, run: .waiting(reason))
        case "taskcompleted":
            return StatusReport(run: .waiting(.humanTurn), turnCompleted: true)
        case "stop":
            // A turn that yielded to await background work (a run_in_background shell, a background
            // subagent, a /loop or scheduled wake) will AUTO-RESUME — the human isn't needed. Leave the
            // card running (return nil) so it neither flips to waiting nor alerts. (background_tasks /
            // session_crons are Claude Code v2.1.145+; absent on older builds → treated as empty.)
            let hasBg = (p["background_tasks"]?.arrayValue?.isEmpty == false)
                || (p["session_crons"]?.arrayValue?.isEmpty == false)
            if hasBg { return nil }
            return StatusReport(run: .waiting(.humanTurn))
        case "sessionend":
            let reason = p["reason"]?.stringValue ?? "other"
            // Transition reasons are ignored (the matching SessionStart handles them).
            if ["clear", "resume", "compact"].contains(reason) { return nil }
            return StatusReport(sessionId: p["session_id"]?.stringValue, endReason: reason)
        default:
            return nil
        }
    }

    /// Receive-direction format: wrap core's neutral `HookResponse` in Claude's hook stdout envelope.
    /// Explicit (not the protocol default) so Claude's shape is never silently inherited by another agent.
    public func encode(_ r: HookResponse, for event: HookEvent) -> String? {
        if let c = r.additionalContext { return HookEnvelope.additionalContext(c) }
        if let cont = r.continuation   { return HookEnvelope.block(cont) }
        return nil
    }

    private func toolDesc(tool: String, input: JSONValue?) -> String {
        switch tool {
        case "Edit", "Write", "MultiEdit":
            if let f = input?["file_path"]?.stringValue { return "Editing \((f as NSString).lastPathComponent)" }
            return "Editing"
        case "Bash":
            if let c = input?["command"]?.stringValue { return "Running: \(String(c.prefix(40)))" }
            return "Running a command"
        case "Read":
            if let f = input?["file_path"]?.stringValue { return "Reading \((f as NSString).lastPathComponent)" }
            return "Reading"
        case "WebSearch": return "Web search"
        case "Grep", "Glob": return "Searching"
        default: return tool
        }
    }

    /// Mirror the source repo's trust onto the worktree: only when the user has already trusted the
    /// main project folder in Claude Code do we pre-accept the worktree's trust dialog (each worktree
    /// is a fresh path Claude would otherwise re-prompt for). If the repo isn't trusted, we leave the
    /// worktree alone so Claude still asks — we don't silently grant trust the user never gave.
    public func prepareToLaunch(_ ctx: AdapterContext) throws {
        // Render the managed --settings base (statusLine + hooks) pointing at the live orchestra binary,
        // FIRST — the overlay merge below reads it. Per-launch render keeps the bin path + statusLine
        // config fresh; the daemon no longer renders anything. Best-effort (never blocks a launch).
        _ = try? HooksRenderer.render(orchestraBin: ctx.orchestraBin, agentId: id)
        if ctx.autoInstallMCPGlobally {
            _ = MCPConfiguration.installUserCommands(orchestra: ctx.orchestraBin,
                                                      orchestraMCP: ctx.orchestraMCPBin,
                                                      home: claudeHome)
            _ = MCPConfiguration.installClaudeGlobally(command: ctx.orchestraMCPBin,
                                                        at: claudeHome + "/.claude.json")
        }
        // Apply the CORE's trust decision (resolved into ctx.trustCwd by OrchestraService.resolveTrust).
        // The adapter only *mirrors* that decision into Claude's native per-directory trust — it never
        // reads the TrustLedger itself. When untrusted, leave Claude to prompt / the card to clamp.
        ClaudeTrust.apply(trusted: ctx.trustCwd, cwd: ctx.cwd)
        // If this card contributes any settings overlays (read-only enforcement today, anything future),
        // fold them onto the managed hooks/statusLine base into ONE merged file that start/resume pass as
        // the sole --settings. Claude Code's multiple --settings are last-file-wins (full replace), NOT
        // deep-merged, so a second --settings would silently drop the managed statusLine + telemetry hooks
        // — see SettingsComposer. Cards with no overlays just use the shared hooks file directly.
        let overlays = settingsOverlays(ctx)
        if !overlays.isEmpty {
            let base = (try? String(contentsOfFile: Config.hooksPath, encoding: .utf8)) ?? ""
            let json = SettingsComposer.composeJSON(baseJSON: base, overlays: overlays)
            try? FileManager.default.createDirectory(atPath: Config.dataDir, withIntermediateDirectories: true)
            try? json.write(toFile: cardSettingsPath(ctx.cwd), atomically: true, encoding: .utf8)
        }
        // The provider-neutral bundle owns which Orchestra sections exist and their ordering. Claude's
        // adapter owns only this packaging: two project skills, one directory each, leaving Codex free to
        // project the identical content into its own launch-scoped config instead of a filesystem write.
        for section in AgentGuidance.sections(for: id) {
            _ = AgentGuidance.install(section,
                                      at: "\(ctx.cwd)/.claude/skills/orchestra-\(section.name)/SKILL.md")
        }
    }

    private func modelFlag(_ model: String?) -> [String] {
        guard let m = model, !m.isEmpty else { return [] }
        return ["--model", m]
    }

    /// Edit-tool denials for a read-only card — removes Edit/Write/MultiEdit/NotebookEdit from the
    /// model's context (reuses [[ReadOnlyLaunch]]'s tool list). The sandbox half rides in as a settings
    /// overlay (see `settingsOverlays`), which `prepareToLaunch` merges into the single `--settings` file.
    private func accessFlags(_ access: CardAccess) -> [String] {
        access == .readOnly
            ? ["--disallowedTools", "Edit", "Write", "MultiEdit", "NotebookEdit"]
            : []
    }

    /// The per-card settings overlays to deep-merge onto the managed hooks/statusLine base, in order.
    /// THIS IS THE SEAM for any future per-card settings: append a `[String: Any]` layer here and it is
    /// automatically folded into the single merged `--settings` file — no new `--settings` flag, no risk
    /// of clobbering the managed statusLine/hooks (Claude's multiple --settings are last-file-wins).
    private func settingsOverlays(_ ctx: AdapterContext) -> [[String: Any]] {
        var overlays: [[String: Any]] = []
        if ctx.access == .readOnly {
            overlays.append(ReadOnlyLaunch.settingsObject(cwd: ctx.cwd, gitDir: nil))
        }
        return overlays
    }

    /// The single `--settings` file for a card. With no overlays the shared managed hooks file is used
    /// directly; with overlays, the per-card merged file `prepareToLaunch` wrote. Exactly one --settings,
    /// always — Claude Code's multiple --settings are last-file-wins (full replace), not deep-merged.
    private func settingsFlags(_ ctx: AdapterContext) -> [String] {
        ["--settings", settingsOverlays(ctx).isEmpty ? Config.hooksPath : cardSettingsPath(ctx.cwd)]
    }

    /// The inline launch-local MCP config keeps Claude's same-name `orchestra` server scoped to this
    /// card while its normal non-strict loading still includes unrelated user/project servers.
    private func mcpFlags(_ ctx: AdapterContext) -> [String] {
        ["--mcp-config", MCPConfiguration.claudeJSON(command: ctx.orchestraMCPBin)]
    }

    /// The managed per-card `--settings` file (statusLine + telemetry hooks + any overlays), reaped by
    /// core's card-file sweep (`sweepCardFiles`). Only actually WRITTEN for cards with overlays (today:
    /// read-only), but the spec describes the whole class so the sweep recognizes every one on disk.
    public var cardFile: CardFileSpec? {
        CardFileSpec(directory: Config.dataDir, prefix: "card-settings-", suffix: ".json", key: .cwdHash)
    }

    /// Deterministic per-cwd path for the merged per-card settings file, so `prepareToLaunch` writes the
    /// same file `start`/`resume` reference. Routed through `cardFile` so the writer and the sweep agree
    /// on one hash. `cardFile!` is safe — this adapter always returns a non-nil `cardFile`.
    private func cardSettingsPath(_ cwd: String) -> String {
        cardFile!.path(token: CardFileSpec.cwdHash(cwd))
    }

    /// In the plan column we hand `--permission-mode auto` so a planning workflow can actually
    /// read/write design docs while the user steers; impl just starts normally.
    private func startInFlags(_ startIn: StartIn?) -> [String] {
        guard let s = startIn else { return [] }
        return s == .plan ? ["--permission-mode", "auto"] : []
    }

    public func start(_ ctx: AdapterContext) -> [String] {
        var argv = [binary]
        argv += modelFlag(ctx.model)
        argv += startInFlags(ctx.startIn)
        argv += accessFlags(ctx.access)
        if let sid = ctx.sessionId { argv += ["--session-id", sid] }
        argv += settingsFlags(ctx)
        argv += mcpFlags(ctx)
        let nameValue = ctx.name ?? (ctx.prompt.map { titleSeed(from: $0) } ?? "")
        if !nameValue.isEmpty { argv += ["--name", nameValue] }
        if let p = ctx.prompt, !p.isEmpty { argv.append(p) }   // launch positional prompt
        return argv
    }

    public func resume(_ ctx: AdapterContext) -> [String]? {
        guard let sid = ctx.sessionId else { return nil }
        var argv = [binary, "--resume", sid] + settingsFlags(ctx) + mcpFlags(ctx)
        if let n = ctx.name, !n.isEmpty { argv += ["--name", n] }
        argv += modelFlag(ctx.model)
        // A plan-column card gets `--permission-mode auto` on START; without it here it silently LOST that
        // mode the first time it was resumed, handed off, or revived — and began prompting mid-task. The
        // launch posture must be identical whether a session is starting or continuing.
        argv += startInFlags(ctx.startIn)
        argv += accessFlags(ctx.access)
        // F1 (C3): a handoff/fork seed (authored ctx + folded inbox) rides as the resumed session's
        // opening positional turn — history holds the task, the seed adds the new instruction.
        if let seed = ctx.seed, !seed.isEmpty { argv.append(seed) }
        return argv   // no --session-id; no prompt beyond the optional seed — history holds the task
    }

    public func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
        let sid = current ?? discover(cwd: ctx.cwd)
        guard let sid else {
            return AgentSessionInfo(agentId: id, sessionId: nil, transcriptPath: nil,
                                    priorSessionIds: prior, priorTranscripts: prior.map { transcriptPath(cwd: ctx.cwd, sessionId: $0) },
                                    resumeCmd: nil)
        }
        let resumeCtx = AdapterContext(cwd: ctx.cwd, model: ctx.model, sessionId: sid,
                                       name: ctx.name, access: ctx.access,
                                       orchestraMCPBin: ctx.orchestraMCPBin)
        return AgentSessionInfo(
            agentId: id,
            sessionId: sid,
            transcriptPath: transcriptPath(cwd: ctx.cwd, sessionId: sid),
            priorSessionIds: prior,
            priorTranscripts: prior.map { transcriptPath(cwd: ctx.cwd, sessionId: $0) },
            resumeCmd: resume(resumeCtx)
        )
    }

    // MARK: transcript path helpers

    /// Claude Code stores transcripts at ~/.claude/projects/<cwd-slug>/<sessionId>.jsonl, where the
    /// slug is the absolute cwd with EVERY non-alphanumeric char replaced by '-'.
    func transcriptPath(cwd: String, sessionId: String) -> String {
        "\(Config.home)/.claude/projects/\(cwdSlug(cwd))/\(sessionId).jsonl"
    }

    /// Reproduce Claude Code's project-dir encoding EXACTLY: every non-`[A-Za-z0-9]` char in the
    /// absolute cwd becomes '-', with NO collapsing of consecutive separators (`/.orchestra` →
    /// `--orchestra`). Matching '.' → '-' is essential: an Orchestra worktree always lives under
    /// `~/.orchestra/…`, so slugging the dot as a literal '.' points `sessionInfo`/`isResumable`/
    /// `resume` at a nonexistent transcript — silently downgrading a reopen or recovery to a blank
    /// restart instead of resuming the real session.
    func cwdSlug(_ cwd: String) -> String {
        String(cwd.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
    }

    /// Fallback for sessions Orchestra didn't start: newest *.jsonl under the cwd-slug dir whose first
    /// record's cwd matches. Returns nil (never a fabricated id) when nothing matches.
    /// NOTE: when multiple cards share a worktree they share this cwd-slug dir, so "newest" is ambiguous
    /// across co-located cards. Only safe as the `agentSessionId == nil` fallback — orchestra-spawned
    /// cards always carry a tracked id, so `sessionInfo` never reaches this for them.
    func discover(cwd: String) -> String? {
        let dir = "\(Config.home)/.claude/projects/\(cwdSlug(cwd))"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        // Newest *.jsonl by mtime (stat each file once, then take the max).
        let newest = entries
            .filter { $0.hasSuffix(".jsonl") }
            .map { (name: $0, mtime: mtime("\(dir)/\($0)")) }
            .max { $0.mtime < $1.mtime }
        guard let newest else { return nil }
        return String(newest.name.dropLast(".jsonl".count))
    }

    private func mtime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
    }
}

public extension AgentCapabilities {
    /// Claude Code's shipped capabilities. This tuple stays beside its adapter: capability vocabulary is
    /// shared in OrchestraKit, while each agent owns the concrete behavior it advertises.
    static let claudeCode = AgentCapabilities(
        sessionId: .seeded,
        telemetry: .hooksPush,
        contextUsage: .percent,
        wakeTransport: .nativeReinvoke,
        inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed,
        authMode: .subscription,
        terminalImagePaste: .controlV,
        // Claude's interactive terminal controls rely on its existing mouse reporting behavior.
        terminalPointerInput: .applicationMouseReporting,
        // Claude fires SessionStart(startup) on a fresh launch and SessionStart(resume) on a relaunch, both
        // via hooksPush — one hook capability confirms BOTH being-born phases.
        readinessConfirmation: .sessionStartHook)
}

/// Manages Claude Code's per-directory trust state in `~/.claude.json` (keyed by absolute path under
/// `projects.<path>`, flagged via `hasTrustDialogAccepted`). The adapter only ever *applies* the core's
/// already-resolved trust decision (`ctx.trustCwd`) into this native flag — it never consults the
/// Orchestra `TrustLedger` (core owns resolution; see `OrchestraService.resolveTrust`).
enum ClaudeTrust {
    /// Apply the core's already-resolved trust decision to Claude's native per-directory trust. Writes
    /// `hasTrustDialogAccepted` for `cwd` iff `trusted`; otherwise a no-op (Claude will prompt / the
    /// card clamps to sandbox). This is the ONLY trust entry point the adapter uses — it consumes
    /// `ctx.trustCwd`, never the `TrustLedger`.
    static func apply(trusted: Bool, cwd: String, home: String = Config.home) {
        guard trusted else { return }
        grant(cwd, home: home)
    }

    /// Unconditionally mark `path` trusted in `~/.claude.json` (merging into any existing entry, leaving
    /// every other field untouched). For directories Orchestra itself creates and owns — a scratch dir —
    /// where there's no source repo whose trust we could mirror. No-op when already trusted; bails
    /// without writing if the file exists but can't be parsed (so a transient read can't clobber it).
    static func grant(_ path: String, home: String = Config.home) {
        let url = URL(fileURLWithPath: "\(home)/.claude.json")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            root = parsed                                                    // missing file → write fresh
        }
        var projects = root["projects"] as? [String: Any] ?? [:]
        var project = projects[path] as? [String: Any] ?? [:]
        if (project["hasTrustDialogAccepted"] as? Bool) == true { return }   // already trusted → no write

        project["hasTrustDialogAccepted"] = true
        projects[path] = project
        root["projects"] = projects

        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
            try? out.write(to: url, options: .atomic)
        }
    }
}
