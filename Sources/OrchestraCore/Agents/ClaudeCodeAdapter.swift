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

    public func models() -> [String] {
        // Claude Code's selectable models. Not hardcoded into business logic — just this adapter's list.
        ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5", "claude-opus-4-7"]
    }

    public func newSessionId() -> String? { UUID().uuidString.lowercased() }

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
        let jsonls = entries.filter { $0.hasSuffix(".jsonl") }
        let sorted = jsonls.sorted { a, b in
            let am = (try? FileManager.default.attributesOfItem(atPath: "\(dir)/\(a)")[.modificationDate] as? Date) ?? nil
            let bm = (try? FileManager.default.attributesOfItem(atPath: "\(dir)/\(b)")[.modificationDate] as? Date) ?? nil
            return (am ?? .distantPast) > (bm ?? .distantPast)
        }
        guard let newest = sorted.first else { return nil }
        return String(newest.dropLast(".jsonl".count))
    }
}
