import Foundation

/// The built-in Codex adapter. Mirrors `ClaudeCodeAdapter` for the second agent: it builds read-only
/// launch/resume argv (`-s read-only -a never`), pins `CODEX_HOME` (via `env`), discovers the session
/// id from the rollout dir post-launch (Codex is `.discovered`, not seeded), and mirrors the CORE's
/// trust decision (`ctx.trustCwd`) into Codex's native per-project `trust_level` — never reading the
/// `TrustLedger`. B1 ships READ-ONLY ONLY (approvals/write deferred), so every launch clamps read-only.
public struct CodexAdapter: Adapter {
    public let id = "codex"
    public let name = "Codex"
    public let icon = "chevron.left.forwardslash.chevron.right"
    public let bin = "codex"
    public let enabled = true

    /// Codex's capability tuple (B1 as-built). Differs from Claude on every launch-relevant axis:
    /// discovered session id, rollout file-tail telemetry, token-based ctx, send-keys wake.
    public var capabilities: AgentCapabilities { .codex }

    /// Test injection (fake binary / isolated home) — never spawns real Codex.
    let binOverride: String?
    let codexHomeOverride: String?

    public init(binOverride: String? = nil, codexHome: String? = nil) {
        self.binOverride = binOverride
        self.codexHomeOverride = codexHome
    }

    private var binary: String { binOverride ?? bin }

    /// Orchestra pins CODEX_HOME so Codex's config + session rollouts live in a known location the
    /// daemon controls (config trust write here; rollout tail in B2). Defaults to `$HOME/.codex`; an
    /// isolated daemon already redirects `$HOME`, so this is isolated along with it.
    var codexHome: String { codexHomeOverride ?? "\(Config.home)/.codex" }

    /// The pinned CODEX_HOME is delivered to the process as an environment variable (wired into the
    /// tmux launch via `SessionManaging.ensure(env:)`). Claude leaves this empty (default).
    public var env: [String: String] { ["CODEX_HOME": codexHome] }

    /// Codex's selectable models. B2/E1 vendor `Resources/codex-models.json` (offline table); until
    /// then this hardcoded list keeps `models()` non-empty so model resolution never fails.
    public func models() -> [AgentModel] {
        let table = ModelCatalog.load("codex-models")
        return table.isEmpty ? Self.fallbackModels : table
    }

    private static let fallbackModels: [AgentModel] = [
        AgentModel(id: "gpt-5-codex", displayName: "GPT-5 Codex", family: "gpt"),
        AgentModel(id: "gpt-5", displayName: "GPT-5", family: "gpt"),
        AgentModel(id: "o3", displayName: "o3", family: "gpt"),
    ]

    /// Codex's session id is `.discovered` (read back from the rollout dir after launch), so Orchestra
    /// mints nothing pre-launch — unlike Claude's `.seeded` `--session-id`.
    public func newSessionId() -> String? { nil }

    // Read-only-first: B1 ships read-only ONLY (approvals deferred), so EVERY launch clamps to these
    // flags regardless of `ctx.access`. `-s read-only` selects Codex's OS-sandboxed read-only mode;
    // `-a never` disables the approval round-trip (which B1 does not implement).
    private var readOnlyFlags: [String] { ["-s", "read-only", "-a", "never"] }

    private func modelFlag(_ model: String?) -> [String] {
        guard let m = model, !m.isEmpty else { return [] }
        return ["-m", m]
    }

    public func start(_ ctx: AdapterContext) -> [String] {
        var argv = [binary]
        argv += readOnlyFlags
        argv += modelFlag(ctx.model)
        if let p = ctx.prompt, !p.isEmpty { argv.append(p) }   // launch positional prompt
        return argv
    }

    public func resume(_ ctx: AdapterContext) -> [String]? {
        guard let sid = ctx.sessionId else { return nil }
        var argv = [binary, "resume", sid]
        argv += readOnlyFlags
        argv += modelFlag(ctx.model)
        return argv   // no prompt — the rollout holds the task
    }

    /// Prep runs isolation FIRST (ensure the pinned CODEX_HOME exists), THEN mirrors the core's trust
    /// decision into it. The adapter applies `ctx.trustCwd` only — it never reads the `TrustLedger`.
    public func prepareToLaunch(_ ctx: AdapterContext) throws {
        try? FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        CodexTrust.apply(trusted: ctx.trustCwd, cwd: ctx.cwd, codexHome: codexHome)
    }

    public func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
        let sid = current ?? discover()
        guard let sid else {
            return AgentSessionInfo(agentId: id, sessionId: nil, transcriptPath: nil,
                                    priorSessionIds: prior, priorTranscripts: [], resumeCmd: nil)
        }
        let resumeCtx = AdapterContext(cwd: ctx.cwd, model: ctx.model, sessionId: sid,
                                       name: ctx.name, access: ctx.access)
        return AgentSessionInfo(
            agentId: id,
            sessionId: sid,
            transcriptPath: rolloutPath(for: sid),
            priorSessionIds: prior,
            priorTranscripts: [],
            resumeCmd: resume(resumeCtx))
    }

    // MARK: rollout discovery — $CODEX_HOME/sessions/**/rollout-<timestamp>-<uuid>.jsonl

    var sessionsDir: String { "\(codexHome)/sessions" }

    /// Newest rollout's embedded session UUID, or nil. The `.discovered` fallback when Orchestra has no
    /// tracked id yet. NOTE: like Claude's `discover`, "newest" is ambiguous if multiple Codex cards
    /// share one CODEX_HOME — safe only as the `current == nil` fallback (tracked cards pass `current`).
    func discover() -> String? {
        let newest = rolloutFiles().max { mtime($0) < mtime($1) }
        guard let newest else { return nil }
        return sessionId(fromRollout: newest)
    }

    func rolloutPath(for sessionId: String) -> String? {
        rolloutFiles().first { self.sessionId(fromRollout: $0) == sessionId }
    }

    private func rolloutFiles() -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: sessionsDir) else { return [] }
        var out: [String] = []
        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            if (rel as NSString).lastPathComponent.hasPrefix("rollout-") {
                out.append("\(sessionsDir)/\(rel)")
            }
        }
        return out
    }

    /// Extract the trailing UUID from `rollout-<timestamp>-<uuid>.jsonl`. Returns nil if the tail is
    /// not a valid UUID (never a fabricated id).
    func sessionId(fromRollout path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(".jsonl".count))
        let candidate = String(stem.suffix(36))
        return UUID(uuidString: candidate) != nil ? candidate.lowercased() : nil
    }

    private func mtime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
    }
}

public extension AgentCapabilities {
    /// Codex's shipped capabilities (B1 as-built). Discovered session id (rollout), file-tail telemetry
    /// (rollout JSONL, parsed in B2), token-based context usage, send-keys wake (C4), seed-folded inbox
    /// drain (no Stop hook), an OS-sandboxed read-only guarantee, and subscription auth.
    static let codex = AgentCapabilities(
        sessionId: .discovered,
        telemetry: .fileTail,
        contextUsage: .tokens,
        wakeTransport: .sendKeys,
        inboxDrain: .sessionSeed,
        readOnlyEnforcement: .sandboxed,
        authMode: .subscription)
}

/// Manages Codex's per-project trust in `$CODEX_HOME/config.toml` (`[projects."<path>"].trust_level`).
/// The adapter only ever *applies* the core's already-resolved decision (`ctx.trustCwd`) — it never
/// reads the Orchestra `TrustLedger` (core owns resolution; see `OrchestraService.resolveTrust`). The
/// Codex analogue of `ClaudeTrust`.
enum CodexTrust {
    /// Apply the core's trust decision to Codex's native per-project trust. Writes `trust_level` for
    /// `cwd` iff `trusted`; otherwise a no-op (Codex will prompt / the card clamps).
    static func apply(trusted: Bool, cwd: String, codexHome: String) {
        guard trusted else { return }
        record(cwd, codexHome: codexHome)
    }

    /// Mark `cwd` trusted by appending a `[projects."<cwd>"]` table with `trust_level = "trusted"`.
    /// Idempotent + non-clobbering: if the section header already exists we leave the file untouched
    /// (mirrors `ClaudeTrust.grant` bailing when already trusted / unparseable), so we never corrupt a
    /// user's existing config.toml.
    static func record(_ cwd: String, codexHome: String) {
        let path = "\(codexHome)/config.toml"
        let header = "[projects.\"\(tomlEscape(cwd))\"]"
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if text.contains(header) { return }                       // already managed → no clobber
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\n\(header)\ntrust_level = \"trusted\"\n"
        try? FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func tomlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
