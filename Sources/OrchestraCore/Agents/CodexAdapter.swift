import Foundation

/// The built-in Codex adapter. It keeps Codex's native home/state untouched, discovers rollouts from the
/// normal home (or an injected test path), and translates shared Orchestra content into Codex's per-launch
/// TOML overrides. Permission posture still mirrors Claude: a default card keeps Codex's own permissioning
/// and a read-only card receives the OS-sandboxed read-only preset.
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

    /// Test injection for a fake binary and an isolated rollout directory. The home override is never
    /// exported to a production Codex process; it only keeps rollout-discovery fixtures hermetic.
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

    /// Codex's normal default state location, retained only for rollout discovery.
    /// Production launch deliberately does not export CODEX_HOME, so auth, plugins, and state stay native.
    var codexHome: String { codexHomeOverride ?? "\(Config.home)/.codex" }

    /// Codex selects its own native state root. The adapter's test-only resolver is intentionally not an
    /// environment override, unlike the former isolated-home implementation.
    public var env: [String: String] { [:] }

    /// Codex's selectable models, from the vendored `Resources/codex-models.json` offline table
    /// (mirrors Codex's own model catalog). The hardcoded list is a safety net if that resource is
    /// missing/unreadable, so `models()` is never empty and model resolution never fails.
    public func models() -> [AgentModel] {
        let table = ModelCatalog.load("codex-models")
        return table.isEmpty ? Self.fallbackModels : table
    }

    private static let fallbackModels: [AgentModel] = [
        AgentModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", family: "gpt"),
        AgentModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", family: "gpt"),
        AgentModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", family: "gpt"),
        AgentModel(id: "gpt-5.5", displayName: "GPT-5.5", family: "gpt"),
    ]

    /// Codex's session id is `.discovered` (read back from the rollout dir after launch), so Orchestra
    /// mints nothing pre-launch — unlike Claude's `.seeded` `--session-id`.
    public func newSessionId() -> String? { nil }

    // MARK: telemetry parse (fileTail) — the daemon tails the rollout JSONL; THIS converts one line.

    /// Codex status/detail/context telemetry is `fileTail`: the daemon-side `RolloutTailer` hands one
    /// rollout JSONL line at a time; this converts it to a normalized `StatusReport`. Its SessionStart hook
    /// additionally supplies the definitive card-owned session id before discovery. AGENT-DEPENDENT (D3) —
    /// the mapping lives here, never in core. Rename-tolerant (Codex's rollout schema drifts:
    /// `TaskComplete`→`TurnComplete`, nested vs flat token totals). `ctxPct` uses THIS adapter's OFFLINE
    /// model table as the denominator (E1), never the rollout's own window. `seq` is the line timestamp
    /// (µs) so out-of-order/duplicate lines lose to the freshest via `report()`'s seq-gate. Any unrecognized
    /// line → nil (dropped).
    public func parse(_ raw: RawTelemetry) -> StatusReport? {
        // SessionStart runs under the launching tmux session, whose environment carries this card's
        // `ORCHESTRA_TASK_ID`. Codex provides its generated `session_id` on the hook's stdin, so this is a
        // direct card ↔ session correlation even when multiple primary rollouts share one cwd. Binding it
        // here avoids relying on rollout discovery for the normal launch path; discovery remains a safe
        // fallback if the hook is unavailable. PermissionRequest remains the provider-neutral wait gate.
        if case let .hooksPush(kind, payload) = raw {
            if kind == HookEvent.sessionStart.rawValue,
               let sid = payload["session_id"]?.stringValue, !sid.isEmpty {
                return StatusReport(sessionId: sid)
            }
            return kind == HookEvent.permission.rawValue
                ? StatusReport(run: .waiting(.permission))
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
            // Codex can start guardian/delegated agents in the same cwd. Their rollout metadata carries
            // the child id, not the card's primary session, so it must never replace the card binding.
            guard !Self.isSubagent(payload) else { return nil }
            let sid = (payload["id"] ?? payload["session_id"])?.stringValue
            guard let sid, !sid.isEmpty else { return nil }
            return StatusReport(sessionId: sid)
        }
        // Idle signal FIRST (a completed turn ends `.running`, rename-tolerant).
        if any("turncomplete", "taskcomplete") {
            // Codex has no permission hook and no background-yield/auto-resume pattern (subagents run
            // synchronously; background shells poll in-turn), so a completed turn is a genuine human-wait.
            return StatusReport(seq: seq, run: .waiting(.humanTurn), turnCompleted: true)
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
            return StatusReport(seq: seq, run: .running)
        }
        // A tool/function call mid-turn → running (+ a coarse desc).
        if any("functioncall", "responseitem") {
            if let name = payload["name"]?.stringValue, !name.isEmpty {
                return StatusReport(seq: seq, desc: "Running \(name)", run: .running)
            }
            return StatusReport(seq: seq, run: .running)
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
        guard let d = rolloutTimestamp(jv["timestamp"]?.stringValue) else { return 0 }
        return UInt64(max(0, d.timeIntervalSince1970 * 1_000_000))
    }

    /// Codex emits ISO-8601 timestamps both on its session metadata payload and on individual rollout
    /// records. The metadata timestamp is immutable launch identity; a file's modification date is not,
    /// because a prior card may append to its rollout long after a later card has started in the same cwd.
    private static func rolloutTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFrac.date(from: value) ?? plain.date(from: value)
    }

    /// Nested Codex agents write independent rollouts under the parent's cwd. Current rollouts name
    /// them explicitly; a nonempty parent id independently identifies the same nested boundary even if
    /// the source label is absent or changes.
    private static func isSubagent(_ payload: JSONValue) -> Bool {
        let source = payload["thread_source"]?.stringValue?.lowercased()
        let parentId = payload["parent_thread_id"]?.stringValue
        return source == "subagent" || !(parentId?.isEmpty ?? true)
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

    // Defect 2 · Codex hook-trust. This installed Codex build gates launch-scoped hooks behind a modal
    // Orchestra cannot answer, so the injected Stop handler would otherwise never drain the inbox. The
    // build-probed flag applies only to hook trust; it does not change approval or sandbox policy.
    private var hookTrustFlags: [String] {
        bypassHookTrustSupported ? ["--dangerously-bypass-hook-trust"] : []
    }

    /// Does the installed Codex build accept `--dangerously-bypass-hook-trust`? An unknown flag would
    /// abort launch (`exit 2, unexpected argument`), so this is build-gated. The flag's presence exactly
    /// tracks the trust gate's presence: this customized build has BOTH; a stock codex-rs build has
    /// NEITHER — so probing the flag is the correct capability gate. Probed per binary via `--help`.
    /// A launch that doesn't inject `hookTrustBypass:` and runs a bin whose `--help` can't complete
    /// cleanly (absent bin, timeout) degrades to no-flag; only a definitive `exit 0` result is cached.
    private var bypassHookTrustSupported: Bool {
        if let forced = hookTrustBypassOverride { return forced }
        return Self.probeBypassHookTrust(binary)
    }

    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var probeCache: [String: Bool] = [:]   // guarded by probeLock
    /// Probe `<bin> --help` for the flag. CRITICAL: only cache a DEFINITIVE outcome — a `--help` that ran
    /// to completion (`exit 0`, whose output we can trust to fully list flags; conventional for clap CLIs
    /// and confirmed for codex-cli 0.142.5). A timeout (`Proc.run` returns a SIGTERM, non-zero exit — it
    /// does NOT throw) or a spawn failure is TRANSIENT (cold first-exec under load, AV scan): return
    /// `false` for this launch but DON'T cache it, so the next launch retries. Caching a transient `false`
    /// would silently disable the flag for the whole daemon session → the exact non-delivery bug this
    /// fixes. (A build whose `--help` exits non-zero would re-probe every launch and never cache — safe,
    /// just not the target build.) The subprocess runs OUTSIDE the lock so a concurrent launch isn't
    /// stalled up to 5s; two concurrent first-probes may both spawn and store the same idempotent value.
    /// Stale on an in-place codex upgrade until daemon restart — acceptable; daemons restart on upgrade.
    static func probeBypassHookTrust(_ bin: String) -> Bool {
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

    private func launchConfigurationFlags(_ ctx: AdapterContext) -> [String] {
        CodexLaunchConfiguration.flags(cwd: ctx.cwd)
    }

    /// Write this launch's profile file BEFORE `start`/`resume` reference it via `-p`. The profile carries
    /// the hooks, per-project trust, and (~16KB) developer instructions off the tmux command line — see
    /// [[CodexLaunchConfiguration]] for why inlining them via `-c` killed every card at spawn. Mirrors the
    /// Claude adapter's `prepareToLaunch`, which writes its own per-card `--settings` file the same way.
    /// The write is load-bearing (a missing profile makes `-p` fail), so unlike a best-effort trust nudge
    /// it surfaces its error rather than swallowing it.
    public func prepareToLaunch(_ ctx: AdapterContext) throws {
        let path = CodexLaunchConfiguration.profilePath(cwd: ctx.cwd, codexHome: codexHome)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if ctx.autoInstallMCPGlobally {
            _ = MCPConfiguration.installCodexGlobally(command: ctx.orchestraMCPBin,
                                                       at: codexHome + "/config.toml")
        }
        try CodexLaunchConfiguration.profileTOML(context: ctx, agentId: id)
            .write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func start(_ ctx: AdapterContext) -> [String] {
        var argv = [binary]
        argv += launchConfigurationFlags(ctx)
        argv += hookTrustFlags
        argv += accessFlags(ctx.access)
        argv += modelFlag(ctx.model)
        if let p = ctx.prompt, !p.isEmpty { argv.append(p) }   // launch positional prompt
        return argv
    }

    public func resume(_ ctx: AdapterContext) -> [String]? {
        guard let sid = ctx.sessionId else { return nil }
        var argv = [binary, "resume", sid]
        argv += launchConfigurationFlags(ctx)
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

    public func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
        let sid = current ?? discover(cwd: ctx.cwd, newerThan: ctx.since)
        guard let sid else {
            return AgentSessionInfo(agentId: id, sessionId: nil, transcriptPath: nil,
                                    priorSessionIds: prior, priorTranscripts: [], resumeCmd: nil)
        }
        let resumeCtx = AdapterContext(cwd: ctx.cwd, model: ctx.model, sessionId: sid,
                                       name: ctx.name, access: ctx.access,
                                       orchestraMCPBin: ctx.orchestraMCPBin)
        return AgentSessionInfo(
            agentId: id,
            sessionId: sid,
            transcriptPath: rolloutPath(for: sid),
            priorSessionIds: prior,
            priorTranscripts: [],
            resumeCmd: resume(resumeCtx))
    }

    // MARK: rollout discovery — normal Codex state / sessions / rollout-<timestamp>-<uuid>.jsonl

    var sessionsDir: String { "\(codexHome)/sessions" }

    /// Newest rollout's embedded session UUID, or nil. Kept for diagnostics/tests; live card discovery
    /// uses `discover(cwd:)` so one Codex card does not accidentally claim another card's newest rollout.
    func discover() -> String? {
        let newest = rolloutFiles().max { mtime($0) < mtime($1) }
        guard let newest else { return nil }
        return sessionId(fromRollout: newest)
    }

    /// Newest primary rollout whose first metadata record belongs to this cwd. This is the safe discovery
    /// path for Orchestra cards before their Codex session id has been bound.
    ///
    /// `newerThan` (2.6) time-scopes the bind to rollouts created AFTER the card entered its being-born
    /// phase (`phaseChangedAt`): a launching Codex card must adopt ONLY the rollout its own fresh launch
    /// created, never a live sibling's actively-written rollout in the same cwd nor its own stale
    /// pre-reboot rollout. The first `session_meta` payload has an immutable creation timestamp; use it
    /// rather than mutable file mtime, which a prior card can update after this launch begins. Nested
    /// Codex-agent rollouts are excluded before the ambiguity check. If more than one primary rollout
    /// remains, binding is genuinely ambiguous and the N=3 liveness fallback carries readiness without
    /// letting an unbound card adopt a sibling's session after it becomes live. `newerThan == nil` can
    /// recover only an unambiguous primary cwd match.
    func discover(cwd: String, newerThan: Date? = nil) -> String? {
        let canon = PathResolver.canonical(cwd)
        let matches = rolloutFiles()
            .compactMap { path -> (path: String, startedAt: Date)? in
                guard let metadata = rolloutMetadata(path),
                      !metadata.isSubagent,
                      PathResolver.canonical(metadata.cwd) == canon else { return nil }
                let startedAt = metadata.startedAt ?? mtime(path)
                if let newerThan, startedAt <= newerThan { return nil }   // stale / pre-launch → not ours
                return (path, startedAt)
            }
        guard let newest = matches.max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        // More than one PRIMARY rollout is genuinely ambiguous at every lifecycle phase. In particular,
        // an unbound card may have reached live through the readiness fallback, but must never then adopt
        // a sibling's session through an unscoped telemetry lookup.
        if matches.count > 1 { return nil }
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

    private struct RolloutMetadata {
        let cwd: String
        let startedAt: Date?
        let isSubagent: Bool
    }

    private func rolloutMetadata(_ path: String) -> RolloutMetadata? {
        guard let line = firstLine(path),
              let jv = try? JSONValue.parse(Data(line.utf8)) else { return nil }
        let payload = jv["payload"] ?? jv
        guard let cwd = payload["cwd"]?.stringValue else { return nil }
        return RolloutMetadata(
            cwd: cwd,
            startedAt: Self.rolloutTimestamp(payload["timestamp"]?.stringValue)
                ?? Self.rolloutTimestamp(jv["timestamp"]?.stringValue),
            isSubagent: Self.isSubagent(payload))
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
        terminalPointerInput: .nativeSelection,
        // A fresh Codex launch writes a rollout whose FIRST line is a `session_meta` record — the daemon's
        // rollout tail observes it and resolves the launch's readiness (D1 `.rolloutMeta`). A `codex resume`
        // writes NO rollout at resume time, so a relaunch has no marker; the universal N=3 liveness-tick
        // fallback resolves the still-pending waiter within the grace, keeping the relaunch on the readiness
        // gate (never an immediate ensure-is-confirmation that would bypass it).
        readinessConfirmation: .rolloutMeta,
        // Codex's permission gate is a TUI prompt whose default option is accepted with Enter / cancelled
        // with Esc — the same keystrokes Claude uses — so the interim send-keys gate carries Enter/Esc.
        // This is the per-adapter seam C1 refines: when Codex's structured `PermissionRequest` reply is
        // wired, replace these with an empty chord so the gate routes through that channel, not keystrokes.
        approveChord: [.named(.enter)],
        denyChord: [.named(.esc)])
}
