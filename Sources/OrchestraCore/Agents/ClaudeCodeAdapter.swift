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

    /// Allow tests to inject a fake binary (the fake-agent fixture) without spawning real Claude.
    let binOverride: String?

    public init(binOverride: String? = nil) {
        self.binOverride = binOverride
    }

    private var binary: String { binOverride ?? bin }

    public func models() -> [AgentModel] {
        // Claude Code's selectable models. Not hardcoded into business logic — just this adapter's
        // catalog (launch id + display label). The `family` is fixed for this provider.
        [
            AgentModel(id: "claude-opus-4-8", displayName: "Opus 4.8", family: "claude"),
            AgentModel(id: "claude-sonnet-4-6", displayName: "Sonnet 4.6", family: "claude"),
            AgentModel(id: "claude-haiku-4-5", displayName: "Haiku 4.5", family: "claude"),
            AgentModel(id: "claude-opus-4-7", displayName: "Opus 4.7", family: "claude"),
        ]
    }

    public func newSessionId() -> String? { UUID().uuidString.lowercased() }

    /// Mirror the source repo's trust onto the worktree: only when the user has already trusted the
    /// main project folder in Claude Code do we pre-accept the worktree's trust dialog (each worktree
    /// is a fresh path Claude would otherwise re-prompt for). If the repo isn't trusted, we leave the
    /// worktree alone so Claude still asks — we don't silently grant trust the user never gave.
    public func prepareToLaunch(_ ctx: AdapterContext) throws {
        ClaudeTrust.mirror(toWorktree: ctx.cwd, fromRepo: ctx.repo)
    }

    private func modelFlag(_ model: String?) -> [String] {
        guard let m = model, !m.isEmpty else { return [] }
        return ["--model", m]
    }

    /// In plan mode we hand `--permission-mode plan`; impl just starts normally.
    private func startInFlags(_ startIn: StartIn?) -> [String] {
        guard let s = startIn else { return [] }
        return s == .plan ? ["--permission-mode", "plan"] : []
    }

    public func start(_ ctx: AdapterContext) -> [String] {
        var argv = [binary]
        argv += modelFlag(ctx.model)
        argv += startInFlags(ctx.startIn)
        if let sid = ctx.sessionId { argv += ["--session-id", sid] }
        argv += ["--settings", ctx.hooksPath]
        let nameValue = ctx.name ?? (ctx.prompt.map { titleSeed(from: $0) } ?? "")
        if !nameValue.isEmpty { argv += ["--name", nameValue] }
        if let p = ctx.prompt, !p.isEmpty { argv.append(p) }   // launch positional prompt
        return argv
    }

    public func resume(_ ctx: AdapterContext) -> [String]? {
        guard let sid = ctx.sessionId else { return nil }
        var argv = [binary, "--resume", sid, "--settings", ctx.hooksPath]
        if let n = ctx.name, !n.isEmpty { argv += ["--name", n] }
        argv += modelFlag(ctx.model)
        return argv   // no --session-id, no prompt — history holds the task
    }

    public func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
        let sid = current ?? discover(cwd: ctx.cwd)
        guard let sid else {
            return AgentSessionInfo(agentId: id, sessionId: nil, transcriptPath: nil,
                                    priorSessionIds: prior, priorTranscripts: prior.map { transcriptPath(cwd: ctx.cwd, sessionId: $0) },
                                    resumeCmd: nil)
        }
        let resumeCtx = AdapterContext(cwd: ctx.cwd, model: ctx.model, sessionId: sid,
                                       name: ctx.name, hooksPath: ctx.hooksPath)
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
    /// slug is the absolute cwd with '/' replaced by '-'.
    func transcriptPath(cwd: String, sessionId: String) -> String {
        "\(Config.home)/.claude/projects/\(cwdSlug(cwd))/\(sessionId).jsonl"
    }

    func cwdSlug(_ cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
    }

    /// Fallback for sessions Orchestra didn't start: newest *.jsonl under the cwd-slug dir whose first
    /// record's cwd matches. Returns nil (never a fabricated id) when nothing matches.
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

/// Manages Claude Code's per-directory trust state in `~/.claude.json` (keyed by absolute path under
/// `projects.<path>`, flagged via `hasTrustDialogAccepted`). We only ever *mirror* trust the user has
/// already granted to a repo onto that repo's worktrees — never grant trust they haven't given.
enum ClaudeTrust {
    /// If `repo` is trusted in `~/.claude.json`, mark `worktree` trusted too (merging into any existing
    /// entry, leaving every other field untouched). No-op when the repo is untrusted/unknown, the
    /// worktree is already trusted, or the config can't be read.
    static func mirror(toWorktree worktree: String, fromRepo repo: String?, home: String = Config.home) {
        guard let repo else { return }
        let url = URL(fileURLWithPath: "\(home)/.claude.json")

        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var projects = root["projects"] as? [String: Any] ?? [:]

        guard isTrusted(repo, in: projects) else { return }                 // repo not trusted → don't grant
        var project = projects[worktree] as? [String: Any] ?? [:]
        if (project["hasTrustDialogAccepted"] as? Bool) == true { return }   // already trusted → no write

        project["hasTrustDialogAccepted"] = true
        projects[worktree] = project
        root["projects"] = projects

        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
            try? out.write(to: url, options: .atomic)
        }
    }

    private static func isTrusted(_ path: String, in projects: [String: Any]) -> Bool {
        (projects[path] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true
    }
}
