import Foundation

/// The built-in Codex adapter. Mirrors `ClaudeCodeAdapter` for the second agent: it builds read-only
/// launch/resume argv (`-s read-only -a never`), pins `CODEX_HOME` (via `env`), discovers the session
/// id from the rollout dir post-launch (Codex is `.discovered`, not seeded), and mirrors the CORE's
/// trust decision (`ctx.trustCwd`) into Codex's native per-project `trust_level` — never reading the
/// `TrustLedger`. Permission posture honors `ctx.access` like Claude: a default (read-write) card
/// launches with Codex's OWN default permissioning, and only a read-only card clamps to Codex's
/// OS-sandboxed read-only preset (`-s read-only -a never`).
public struct CodexAdapter: Adapter {
    public let id = "codex"
    public let name = "Codex"
    public let icon = "chevron.left.forwardslash.chevron.right"
    public let bin = "codex"
    public let enabled = true

    /// Codex's capability tuple (B1 as-built). Differs from Claude on the launch-relevant axes: discovered
    /// session id, rollout file-tail telemetry, token-based ctx. Shares Claude's live-delivery shape —
    /// resume-seed wake (`.relaunch`) + Stop-hook drain (`.stopHook`).
    public var capabilities: AgentCapabilities { .codex }

    /// Test injection (fake binary / isolated home) — never spawns real Codex.
    let binOverride: String?
    let codexHomeOverride: String?
    /// Test injection for the hook-trust build-probe. `nil` ⇒ probe the real binary once (cached);
    /// `true`/`false` ⇒ force the result (hermetic tests, no subprocess).
    let hookTrustBypassOverride: Bool?

    public init(binOverride: String? = nil, codexHome: String? = nil, hookTrustBypass: Bool? = nil) {
        self.binOverride = binOverride
        self.codexHomeOverride = codexHome
        self.hookTrustBypassOverride = hookTrustBypass
    }

    private var binary: String { binOverride ?? bin }

    /// Orchestra pins CODEX_HOME so Codex's config + session rollouts live in a known location the
    /// daemon controls (config trust write here; rollout tail in B2). Defaults to `$HOME/.codex`; an
    /// isolated daemon already redirects `$HOME`, so this is isolated along with it.
    var codexHome: String { codexHomeOverride ?? "\(Config.home)/.codex" }

    /// The pinned CODEX_HOME is delivered to the process as an environment variable (wired into the
    /// tmux launch via `SessionManaging.ensure(env:)`). Claude leaves this empty (default).
    public var env: [String: String] { ["CODEX_HOME": codexHome] }

    /// Codex's selectable models, from the vendored `Resources/codex-models.json` offline table
    /// (mirrors Codex's own model catalog). The hardcoded list is a safety net if that resource is
    /// missing/unreadable, so `models()` is never empty and model resolution never fails.
    public func models() -> [AgentModel] {
        let table = ModelCatalog.load("codex-models")
        return table.isEmpty ? Self.fallbackModels : table
    }

    private static let fallbackModels: [AgentModel] = [
        AgentModel(id: "gpt-5.5", displayName: "GPT-5.5", family: "gpt"),
        AgentModel(id: "gpt-5.4", displayName: "GPT-5.4", family: "gpt"),
        AgentModel(id: "gpt-5.4-mini", displayName: "GPT-5.4 Mini", family: "gpt"),
        AgentModel(id: "gpt-5.3-codex", displayName: "GPT-5.3 Codex", family: "gpt"),
        AgentModel(id: "gpt-5.2", displayName: "GPT-5.2", family: "gpt"),
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
        // C1 · permission gate (hooksPush). Codex's `PermissionRequest` hook fires `_report --event
        // permission`, which arrives here as a hooksPush. Classify it into the SAME neutral
        // `waitReason == .permission` Claude reaches via its Notification/permission_prompt — so a
        // blocked Codex card surfaces as a Needs-You 🔐 row (M3 renders it provider-neutrally). This is
        // the adapter/capability seam: the Codex-specific mapping lives HERE, never as `if agent==` in
        // core. Codex's OTHER hooks (SessionStart/Stop) carry no StatusReport — the daemon dispatches
        // them (orientation, inbox drain) via the typed HookEvent — so they fall through to nil, and
        // telemetry stays the rollout fileTail below.
        if case let .hooksPush(kind, _) = raw {
            return kind == HookEvent.permission.rawValue
                ? StatusReport(status: .waiting, waitReason: .permission)
                : nil
        }
        guard case let .fileTail(line) = raw else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let jv = try? JSONValue.parse(Data(trimmed.utf8)) else { return nil }
        let payload = jv["payload"] ?? jv
        let seq = Self.rolloutSeq(jv)
        // Normalize BOTH the top-level and payload `type` (lower-cased, `_` stripped) for rename tolerance.
        let kinds = [jv["type"]?.stringValue, payload["type"]?.stringValue]
            .compactMap { $0 }.map(Self.norm)
        func any(_ needles: String...) -> Bool { kinds.contains { k in needles.contains { k.contains($0) } } }

        // Bind the discovered rollout id to this card as soon as the first metadata record is tailed.
        if any("sessionmeta") {
            let sid = (payload["id"] ?? payload["session_id"])?.stringValue
            guard let sid, !sid.isEmpty else { return nil }
            return StatusReport(sessionId: sid)
        }
        // Idle signal FIRST (a completed turn ends `.running`, rename-tolerant).
        if any("turncomplete", "taskcomplete") {
            // Codex has no permission hook and no background-yield/auto-resume pattern (subagents run
            // synchronously; background shells poll in-turn), so a completed turn is a genuine human-wait.
            return StatusReport(seq: seq, status: .waiting, waitReason: .humanTurn, turnCompleted: true)
        }
        // Token usage -> ctxPct + modelId. Prefer the offline model table as the denominator when the
        // rollout names a model; fall back to the rollout's explicit context window for model-less
        // token reporters. No status (avoids churn vs turn edges).
        if any("tokencount", "tokenusage") {
            let info = payload["info"] ?? payload
            let mid = (info["model"] ?? payload["model"])?.stringValue
            let pct = tokenContextPercent(
                usedTokens: Self.contextTokenTotal(info),
                modelId: mid,
                reportedContextWindow: info["model_context_window"]?.intValue)
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

    /// Tokens currently occupying the model context. Modern Codex emits both session-cumulative
    /// `total_token_usage` and request/window-sized `last_token_usage`; the latter is the context gauge.
    /// Older rollouts only had total/flat fields, so keep them as fallbacks.
    private static func contextTokenTotal(_ info: JSONValue) -> Int? {
        info["last_token_usage"]?["total_tokens"]?.intValue
            ?? info["total_token_usage"]?["total_tokens"]?.intValue
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

    // Permission posture — mirrors Claude's `accessFlags` (D8 §7): a DEFAULT (read-write) card launches
    // with Codex's OWN default permissioning — NO `-s`/`-a` clamp — so `AccessPolicy .default` means
    // "the agent's native default", exactly like Claude passes no `--permission-mode`. Only a `.readOnly`
    // card applies Codex's OS-sandboxed read-only PRESET: `-s read-only` selects the sandboxed read-only
    // mode and `-a never` disables the approval round-trip. This is the Codex analogue of Claude's
    // `--disallowedTools` + `denyWrite` overlay.
    private func accessFlags(_ access: CardAccess) -> [String] {
        access == .readOnly ? ["-s", "read-only", "-a", "never"] : []
    }

    // Defect 2 · Codex hook-trust. This customized Codex build TRUST-GATES hooks behind a launch-time
    // modal ("Hooks need review") Orchestra can't answer — so without intervention the Stop hook never
    // runs and the durable inbox never drains ("Codex won't wake"). `--dangerously-bypass-hook-trust`
    // establishes trust by construction: Orchestra AUTHORS the hooks (it owns CODEX_HOME + writes
    // hooks.json), so trusting them is correct. Empirically it is the ONLY mechanism that runs untrusted
    // hooks (the `-c bypass_hook_trust` override is inert; persisted trust is hash-keyed → a config-seed
    // is fragile). It is DANGEROUS only re: hook trust — it does NOT touch approvals/sandbox.
    private var hookTrustFlags: [String] {
        bypassHookTrustSupported ? ["--dangerously-bypass-hook-trust"] : []
    }

    /// Does the installed Codex build accept `--dangerously-bypass-hook-trust`? An unknown flag would
    /// abort launch (`exit 2, unexpected argument`), so this is build-gated. The flag's presence exactly
    /// tracks the trust gate's presence: this customized build has BOTH; a stock codex-rs build has
    /// NEITHER — so probing the flag is the correct capability gate. Probed per binary via `--help`; a
    /// DEFINITIVE result (help completed, `exit 0`) is cached; anything else degrades to no flag for THIS
    /// launch WITHOUT caching. Never blocks launch; never spawns for fake-bin tests (they inject
    /// `hookTrustBypass:`; an absent bin fails the probe → no flag).
    private var bypassHookTrustSupported: Bool {
        if let forced = hookTrustBypassOverride { return forced }
        return Self.probeBypassHookTrust(binary)
    }

    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var probeCache: [String: Bool] = [:]   // guarded by probeLock
    /// Probe `<bin> --help` for the flag. CRITICAL: only cache a DEFINITIVE outcome — a `--help` that ran
    /// to completion (`exit 0`, whose output we can trust to fully list flags). A timeout (`Proc.run`
    /// returns a SIGTERM, non-zero exit — it does NOT throw) or a spawn failure is TRANSIENT (cold
    /// first-exec under load, AV scan): return `false` for this launch but DON'T cache it, so the next
    /// launch retries. Caching a transient `false` would silently disable the flag for the whole daemon
    /// session → the exact non-delivery bug this fixes. Double-checked locking: the subprocess runs
    /// OUTSIDE the lock so a concurrent launch isn't stalled up to 5s. Stale on an in-place codex upgrade
    /// until daemon restart — acceptable; daemons restart on upgrade.
    private static func probeBypassHookTrust(_ bin: String) -> Bool {
        probeLock.lock()
        let cached = probeCache[bin]
        probeLock.unlock()
        if let cached { return cached }

        guard let r = try? Proc.run([bin, "--help"], timeout: .seconds(5)), r.exitCode == 0 else {
            return false   // transient/failed probe → no flag THIS launch, but NOT cached (retry next time)
        }
        let supported = (r.stdout + r.stderr).contains("--dangerously-bypass-hook-trust")
        probeLock.lock()
        probeCache[bin] = supported   // definitive → cache
        probeLock.unlock()
        return supported
    }

    private func modelFlag(_ model: String?) -> [String] {
        guard let m = model, !m.isEmpty else { return [] }
        return ["-m", m]
    }

    public func start(_ ctx: AdapterContext) -> [String] {
        var argv = [binary]
        argv += hookTrustFlags
        argv += accessFlags(ctx.access)
        argv += modelFlag(ctx.model)
        if let p = ctx.prompt, !p.isEmpty { argv.append(p) }   // launch positional prompt
        return argv
    }

    public func resume(_ ctx: AdapterContext) -> [String]? {
        guard let sid = ctx.sessionId else { return nil }
        var argv = [binary, "resume", sid]
        argv += hookTrustFlags
        argv += accessFlags(ctx.access)
        argv += modelFlag(ctx.model)
        // F1: the folded seed (handoff ctx + pending inbox) rides the resume as its opening positional
        // turn. This is the resume-seed delivery for handoff AND the idle-wake path (`.relaunch`); live
        // turn-end delivery is the Stop hook (`inboxDrain == .stopHook`).
        if let seed = ctx.seed, !seed.isEmpty { argv.append(seed) }
        return argv   // no prompt beyond the optional seed — the rollout holds prior task history
    }

    /// Receive-direction format: Codex 0.135+ reads the SAME `hookSpecificOutput.additionalContext`
    /// envelope Claude does, so this body is identical — but stated explicitly (not inherited) so the
    /// shape is a deliberate Codex choice, not a silent inheritance of Claude's.
    public func encode(_ r: HookResponse, for event: HookEvent) -> String? {
        if let c = r.additionalContext { return HookEnvelope.additionalContext(c) }
        if let cont = r.continuation   { return HookEnvelope.block(cont) }
        return nil
    }

    /// Prep runs isolation FIRST (ensure the pinned CODEX_HOME exists), THEN mirrors the core's trust
    /// decision into it. The adapter applies `ctx.trustCwd` only — it never reads the `TrustLedger`.
    public func prepareToLaunch(_ ctx: AdapterContext) throws {
        try? FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        CodexTrust.apply(trusted: ctx.trustCwd, cwd: ctx.cwd, codexHome: codexHome)
        // Standing delegation guidance for EVERY Codex card (independent of ctx.seed): deliver the
        // AGENTS.md variant to the ISOLATED CODEX_HOME — the global (top) level of Codex's AGENTS.md
        // precedence, merged ABOVE any project AGENTS.md. Orchestra owns CODEX_HOME, so this never
        // clobbers the user's own project AGENTS.md nor dirties the worktree. Best-effort (never throws);
        // content keyed via forAgent(id), so there's no `if codex` here.
        // Codex reads ONE AGENTS.md per scope, so delegation and tree guidance must COMPOSE into it, not
        // overwrite each other. Upsert each as a named, marker-delimited section (rewrite-idempotent): a
        // relaunch/recovery refreshes both in place without duplication. Best-effort; content keyed via
        // forAgent(id), so no `if codex` here.
        let agentsPath = "\(codexHome)/AGENTS.md"
        if let deleg = DelegationDocs.forAgent(id) {
            AgentsFileComposer.upsert(section: "delegation", content: deleg, at: agentsPath)
        }
        if let tree = TreeDocs.forAgent(id) {
            AgentsFileComposer.upsert(section: "tree", content: tree, at: agentsPath)
        }
        // Render + install the managed Codex hooks file (per-launch; the daemon renders nothing), pointing
        // at the live orchestra binary with `--agent codex` baked in. Two hooks: SessionStart→`session`
        // (column/mode/self-id orientation) and Stop→`stop` (drain the durable inbox at turn-end, parity
        // with Claude — F3). Installed into the pinned CODEX_HOME, never clobbering a foreign user
        // hooks.json. Best-effort.
        _ = try? HooksRenderer.renderCodex(orchestraBin: ctx.orchestraBin, agentId: id)
        CodexHooks.install(to: "\(codexHome)/hooks.json")
    }

    public func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
        let sid = current ?? discover(cwd: ctx.cwd)
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

    /// Newest rollout's embedded session UUID, or nil. Kept for diagnostics/tests; live card discovery
    /// uses `discover(cwd:)` so one Codex card does not accidentally claim another card's newest rollout.
    func discover() -> String? {
        let newest = rolloutFiles().max { mtime($0) < mtime($1) }
        guard let newest else { return nil }
        return sessionId(fromRollout: newest)
    }

    /// Newest rollout whose first metadata record belongs to this cwd. This is the safe discovery path
    /// for Orchestra cards before their Codex session id has been bound.
    func discover(cwd: String) -> String? {
        let canon = PathResolver.canonical(cwd)
        let newest = rolloutFiles()
            .compactMap { path -> (path: String, mtime: Date)? in
                guard let metaCwd = rolloutCwd(path),
                      PathResolver.canonical(metaCwd) == canon else { return nil }
                return (path, mtime(path))
            }
            .max { $0.mtime < $1.mtime }
        guard let newest else { return nil }
        return sessionId(fromRollout: newest.path)
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

    private func rolloutCwd(_ path: String) -> String? {
        guard let line = firstLine(path),
              let jv = try? JSONValue.parse(Data(line.utf8)) else { return nil }
        let payload = jv["payload"] ?? jv
        return payload["cwd"]?.stringValue
    }

    private func firstLine(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var data = Data()
        let chunkSize = 64 * 1024
        let cap = 4 * 1024 * 1024
        while data.count < cap {
            let chunk = fh.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            if let nl = chunk.firstIndex(of: 0x0A) {
                data.append(chunk[..<nl])
                break
            }
            data.append(chunk)
        }
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func mtime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
    }
}

public extension AgentCapabilities {
    /// Codex's shipped capabilities (B1 as-built). Discovered session id (rollout), file-tail telemetry
    /// (rollout JSONL), token-based context usage, resume-seed wake (`.relaunch` — idle cards resume; no
    /// TUI scrape), Stop-hook inbox drain (parity with Claude), an OS-sandboxed read-only guarantee, and
    /// subscription auth.
    static let codex = AgentCapabilities(
        sessionId: .discovered,
        telemetry: .fileTail,
        contextUsage: .tokens,
        wakeTransport: .relaunch,
        inboxDrain: .stopHook,
        readOnlyEnforcement: .sandboxed,
        authMode: .subscription,
        terminalImagePaste: .controlV,
        // `codex resume` emits no SessionStart(resume) marker (no rollout written at resume time), so the
        // successful relaunch itself confirms — waiting for a hook would time out and kill a live idle card.
        resumeConfirmation: .relaunchLiveness,
        // Codex's permission gate is a TUI prompt whose default option is accepted with Enter / cancelled
        // with Esc — the same keystrokes Claude uses — so the interim send-keys gate carries Enter/Esc.
        // This is the per-adapter seam C1 refines: when Codex's structured `PermissionRequest` reply is
        // wired, replace these with an empty chord so the gate routes through that channel, not keystrokes.
        approveChord: [.named(.enter)],
        denyChord: [.named(.esc)])
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
