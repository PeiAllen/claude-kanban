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

    // MARK: telemetry parse (fileTail) — the daemon tails the rollout JSONL; THIS converts one line.

    /// Codex telemetry is `fileTail`: the daemon-side `RolloutTailer` hands one rollout JSONL line at a
    /// time; this converts it to a normalized `StatusReport`. AGENT-DEPENDENT (D3) — the mapping lives
    /// here, never in core. Rename-tolerant (Codex's rollout schema drifts: `TaskComplete`→`TurnComplete`,
    /// nested vs flat token totals). `ctxPct` uses THIS adapter's OFFLINE model table as the denominator
    /// (E1), never the rollout's own window. `seq` is the line timestamp (µs) so out-of-order/duplicate
    /// lines lose to the freshest via `report()`'s seq-gate. Any unrecognized line → nil (dropped).
    public func parse(_ raw: RawTelemetry) -> StatusReport? {
        guard case let .fileTail(line) = raw else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let jv = try? JSONValue.parse(Data(trimmed.utf8)) else { return nil }
        let payload = jv["payload"] ?? jv
        let seq = Self.rolloutSeq(jv)
        // Normalize BOTH the top-level and payload `type` (lower-cased, `_` stripped) for rename tolerance.
        let kinds = [jv["type"]?.stringValue, payload["type"]?.stringValue]
            .compactMap { $0 }.map(Self.norm)
        func any(_ needles: String...) -> Bool { kinds.contains { k in needles.contains { k.contains($0) } } }

        // Idle signal FIRST (a completed turn ends `.running`, rename-tolerant).
        if any("turncomplete", "taskcomplete") {
            return StatusReport(seq: seq, status: .waiting)
        }
        // Token usage → ctxPct (÷ offline model window) + modelId. No status (avoids churn vs turn edges).
        if any("tokencount", "tokenusage") {
            let info = payload["info"] ?? payload
            let mid = (info["model"] ?? payload["model"])?.stringValue
            let total = Self.tokenTotal(info)
            let pct = (mid != nil && total != nil) ? model(for: mid!).ctxPct(usedTokens: total!) : nil
            guard pct != nil || mid != nil else { return nil }
            return StatusReport(seq: seq, ctxPct: pct, modelId: mid)
        }
        // Turn start → running.
        if any("taskstarted", "turnstarted") {
            return StatusReport(seq: seq, status: .running)
        }
        // A tool/function call mid-turn → running (+ a coarse desc).
        if any("functioncall", "responseitem") {
            if let name = payload["name"]?.stringValue, !name.isEmpty {
                return StatusReport(seq: seq, desc: "Running \(name)", status: .running)
            }
            return StatusReport(seq: seq, status: .running)
        }
        return nil
    }

    /// Lower-case + drop underscores so `task_complete` / `TaskComplete` / `TurnComplete` normalize alike.
    private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "_", with: "")
    }

    /// Total tokens from a usage `info` object, tolerating the nested (`total_token_usage.total_tokens`)
    /// and flat (`total_tokens` / `tokens`) shapes the rollout schema has used.
    private static func tokenTotal(_ info: JSONValue) -> Int? {
        info["total_token_usage"]?["total_tokens"]?.intValue
            ?? info["total_tokens"]?.intValue
            ?? info["tokens"]?.intValue
    }

    /// Monotonic seq from the line's RFC3339 `timestamp`, in microseconds since epoch. Absent/unparseable
    /// → 0 (still applies: the tailer delivers lines in file order, so a 0-seq snapshot is never stale).
    private static func rolloutSeq(_ jv: JSONValue) -> UInt64 {
        guard let ts = jv["timestamp"]?.stringValue else { return 0 }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let d = withFrac.date(from: ts) ?? plain.date(from: ts) else { return 0 }
        return UInt64(max(0, d.timeIntervalSince1970 * 1_000_000))
    }

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
        // F1 (C3): Codex has no Stop hook (`inboxDrain == .sessionSeed`), so the folded seed (handoff
        // ctx + pending inbox) rides the resume as its opening positional turn.
        if let seed = ctx.seed, !seed.isEmpty { argv.append(seed) }
        return argv   // no prompt beyond the optional seed — the rollout holds prior task history
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
