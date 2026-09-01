import Foundation

/// The built-in Codex adapter. It keeps Codex's native home/state untouched, reads metadata for an already
/// bound app-server thread, and translates shared Orchestra content into Codex's per-launch
/// TOML overrides. Permission posture still mirrors Claude: a default card keeps Codex's own permissioning
/// and a read-only card receives the OS-sandboxed read-only preset.
public struct CodexAdapter: Adapter {
    public let id = "codex"
    public let name = "Codex"
    public let icon = "chevron.left.forwardslash.chevron.right"
    public let bin = "codex"
    public let enabled = true

    /// Codex's capability tuple: app-server-discovered session id, rollout file-tail metadata, and token-based
    /// context usage.
    public var capabilities: AgentCapabilities { .codex }

    /// Test injection for a fake binary and an isolated rollout directory. The home override is never
    /// exported to a production Codex process; it only keeps rollout metadata fixtures hermetic.
    let binOverride: String?
    let codexHomeOverride: String?
    let userHomeOverride: String?
    /// Test injection for the hook-trust build-probe. `nil` ⇒ probe the real binary once (cached);
    /// `true`/`false` ⇒ force the result (hermetic tests, no subprocess).
    let hookTrustBypassOverride: Bool?

    public init(binOverride: String? = nil, codexHome: String? = nil, hookTrustBypass: Bool? = nil,
                userHome: String? = nil) {
        self.binOverride = binOverride
        self.codexHomeOverride = codexHome
        self.hookTrustBypassOverride = hookTrustBypass
        self.userHomeOverride = userHome
    }

    private var binary: String { binOverride ?? bin }

    public func observationEndpoint(_ setup: AgentObservationSetup) -> AgentObservationEndpoint? {
        .unixSocket(path: (setup.runtimeStateDir as NSString)
            .appendingPathComponent("codex-\(setup.cardRef).sock"))
    }

    public func makeObservationSource(
        endpoint: AgentObservationEndpoint,
        binding: AgentObservationBinding
    ) -> (any AgentObservationSource)? {
        guard let socketPath = endpoint.unixSocketPath else { return nil }
        return CodexAppServerObservationSource(socketPath: socketPath, binding: binding)
    }

    public func messageEndpoint(
        observationEndpoint: AgentObservationEndpoint,
        harnessSessionId: String
    ) -> AgentMessageEndpoint? {
        guard let socketPath = observationEndpoint.unixSocketPath,
              !socketPath.isEmpty,
              !harnessSessionId.isEmpty
        else { return nil }
        return .codexAppServer(socketPath: socketPath, threadId: harnessSessionId)
    }

    public func makeMessageSender(for endpoint: AgentMessageEndpoint) -> (any AgentMessageSender)? {
        guard case let .codexAppServer(socketPath, threadId) = endpoint,
              !socketPath.isEmpty,
              !threadId.isEmpty
        else { return nil }
        return CodexMessageSender(socketPath: socketPath, threadId: threadId)
    }

    /// Codex's normal default state location, retained only for metadata lookup after app-server binding.
    /// Production launch deliberately does not export CODEX_HOME, so auth, plugins, and state stay native.
    var codexHome: String { codexHomeOverride ?? "\(Config.home)/.codex" }
    private var userHome: String { userHomeOverride ?? Config.home }

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

    /// Codex's thread id is `.discovered` from its app-server after launch, so Orchestra mints nothing
    /// pre-launch — unlike Claude's `.seeded` `--session-id`.
    public func newSessionId() -> String? { nil }

    // MARK: telemetry parse (fileTail) — the daemon tails the rollout JSONL; THIS converts one line.

    /// Codex metadata telemetry is `fileTail`: the daemon-side `RolloutTailer` hands one rollout JSONL
    /// line at a time; this extracts context and display detail into `StatusReport`. SessionStart remains
    /// lifecycle/orientation-only; the app-server thread is the sole provider-session identity. AGENT-DEPENDENT (D3) —
    /// the mapping lives here, never in core. Rename-tolerant (Codex's rollout schema drifts:
    /// `TaskComplete`→`TurnComplete`, nested vs flat token totals). `ctxPct` uses THIS adapter's OFFLINE
    /// model table as the denominator (E1), never the rollout's own window. `seq` is the line timestamp
    /// (µs) so out-of-order/duplicate lines lose to the freshest via `report()`'s seq-gate. Any unrecognized
    /// line → nil (dropped).
    public func parse(_ raw: RawTelemetry) -> StatusReport? {
        if case let .hooksPush(kind, payload) = raw {
            if kind == HookEvent.sessionStart.rawValue,
               let source = payload["source"]?.stringValue, !source.isEmpty {
                return StatusReport(sessionSource: source)
            }
            return nil
        }
        if case let .rpcNotification(method, params) = raw,
           method == "thread/started",
           let threadId = params["thread"]?["id"]?.stringValue,
           !threadId.isEmpty {
            return StatusReport(sessionId: threadId)
        }
        if case let .rpcResponse(method, result) = raw,
           method == "thread/list",
           let threads = result["data"]?.arrayValue,
           threads.count == 1,
           let threadId = threads[0]["id"]?.stringValue,
           !threadId.isEmpty {
            return StatusReport(sessionId: threadId)
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

        if any("sessionmeta") {
            return nil
        }
        // Turn edges come from app-server notifications, never from the historical rollout tail.
        if any("turncomplete", "taskcomplete") {
            return nil
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
        if any("taskstarted", "turnstarted") {
            return nil
        }
        // A tool/function call contributes display detail only; the app-server turn stays authoritative.
        if any("functioncall", "responseitem") {
            if let name = payload["name"]?.stringValue, !name.isEmpty {
                return StatusReport(seq: seq, desc: "Running \(name)")
            }
            return nil
        }
        return nil
    }

    // MARK: provider-neutral agent-state mapping

    public func hookObservationPayload(event: HookEvent, payload: JSONValue) -> JSONValue? {
        nil
    }

    public func agentSignals(from raw: RawTelemetry, context: AgentSignalContext) -> [AgentSignal] {
        guard let expectedThreadId = context.harnessSessionId, !expectedThreadId.isEmpty else { return [] }

        let kinds: [AgentSignal.Kind]
        let turnID: String?
        switch raw {
        case .rpcNotification(let method, let params):
            guard params["threadId"]?.stringValue == expectedThreadId else { return [] }
            switch method {
            case "turn/started":
                guard let id = params["turn"]?["id"]?.stringValue, !id.isEmpty else { return [] }
                kinds = [.turnStarted]
                turnID = id
            case "turn/completed":
                kinds = [.turnCompleted()]
                let id = params["turn"]?["id"]?.stringValue
                turnID = id?.isEmpty == false ? id : nil
            case "thread/status/changed":
                kinds = reconciliations(from: params["status"])
                turnID = nil
            default:
                kinds = []
                turnID = nil
            }

        case .rpcResponse(let method, let result):
            guard ["thread/resume", "thread/read"].contains(method), let thread = result["thread"],
                  thread["id"]?.stringValue == expectedThreadId
            else { return [] }
            kinds = reconciliations(from: thread["status"])
            turnID = nil

        case .hooksPush, .fileTail:
            kinds = []
            turnID = nil
        }

        return kinds.map { .init(sessionEpoch: context.sessionEpoch, turnID: turnID, kind: $0) }
    }

    private func reconciliations(from status: JSONValue?) -> [AgentSignal.Kind] {
        switch status?["type"]?.stringValue {
        case "active":
            let flags = status?["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return [.turnReconciled(.running, humanNeed: humanNeed(for: flags))]
        case "idle":
            return [.turnReconciled(.waiting(), humanNeed: nil)]
        case "notLoaded", "systemError":
            return [.observationLost]
        default:
            return []
        }
    }

    private func humanNeed(for flags: [String]) -> ProviderHumanNeed? {
        let approval = flags.contains("waitingOnApproval")
        let input = flags.contains("waitingOnUserInput")
        return switch (approval, input) {
        case (false, false): nil
        case (true, false): .permission
        case (false, true): .input
        case (true, true): .unspecified
        }
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

    // Permission posture — mirrors Claude's `accessFlags` (D8 §7): a DEFAULT (read-write) card launches
    // with Codex's OWN default permissioning — NO `-s`/`-a` clamp — so `AccessPolicy .default` means
    // "the agent's native default", exactly like Claude passes no `--permission-mode`. Only a `.readOnly`
    // card applies Codex's OS-sandboxed read-only PRESET: `-s read-only` selects the sandboxed read-only
    // mode and `-a never` disables the approval round-trip. This is the Codex analogue of Claude's
    // `--disallowedTools` + `denyWrite` overlay.
    private func accessFlags(_ access: CardAccess) -> [String] {
        access == .readOnly ? ["-s", "read-only", "-a", "never"] : []
    }

    // Some Codex builds gate launch-scoped hooks behind a modal Orchestra cannot answer. The build-probed
    // flag applies only to hook trust; it does not change approval or sandbox policy.
    private var hookTrustFlags: [String] {
        bypassHookTrustSupported ? ["--dangerously-bypass-hook-trust"] : []
    }

    /// Does the installed Codex build accept `--dangerously-bypass-hook-trust`? An unknown flag would
    /// abort launch (`exit 2, unexpected argument`), so this is build-gated. The flag's presence exactly
    /// tracks the trust gate's presence. Probe it per binary via `--help`.
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
    /// would silently disable the flag for the whole daemon session. A build whose `--help` exits non-zero
    /// re-probes every launch and never caches — safe,
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

    /// The per-launch profile file (`$CODEX_HOME/orch-<djb2>.config.toml`), reaped by core's card-file
    /// sweep (`sweepCardFiles`). `directory` is the (instance) native codex home; `-p <profileName>`
    /// resolves to exactly this file. Not the user's own `config.toml` — the `orch-` prefix scopes the
    /// sweep off it (and off the global MCP-install `config.toml`).
    public var cardFile: CardFileSpec? {
        // `ownershipMarker` set because codexHome is the user's REAL `~/.codex` — the sweep must prove
        // Orchestra wrote a file (via the stamped marker) before deleting it, since the name shape alone
        // can't distinguish our hash from a user profile that happens to look like one.
        CardFileSpec(directory: codexHome, prefix: "orch-", suffix: ".config.toml", key: .cwdHash,
                     ownershipMarker: CodexLaunchConfiguration.ownershipMarker)
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
            _ = MCPConfiguration.installUserCommands(orchestra: ctx.orchestraBin,
                                                      orchestraMCP: ctx.orchestraMCPBin,
                                                      home: userHome)
            _ = MCPConfiguration.installCodexGlobally(command: ctx.orchestraMCPBin,
                                                       at: codexHome + "/config.toml")
        }
        try CodexLaunchConfiguration.profileTOML(context: ctx, agentId: id)
            .write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func start(_ ctx: AdapterContext) -> [String] {
        var arguments = launchConfigurationFlags(ctx)
        arguments += hookTrustFlags
        arguments += accessFlags(ctx.access)
        arguments += modelFlag(ctx.model)
        let positional = ctx.prompt.flatMap { $0.isEmpty ? nil : $0 }.map { [$0] } ?? []
        if let launch = CodexLaunchConfiguration.appServerLaunch(
            binary: binary, context: ctx, agentId: id,
            clientArguments: arguments, positional: positional
        ) {
            return launch.argv
        }
        return [binary] + arguments + positional
    }

    public func resume(_ ctx: AdapterContext) -> [String]? {
        guard let sid = ctx.sessionId else { return nil }
        var arguments = ["resume", sid]
        arguments += launchConfigurationFlags(ctx)
        arguments += hookTrustFlags
        arguments += accessFlags(ctx.access)
        arguments += modelFlag(ctx.model)
        // The folded handoff seed rides the resume as its opening positional turn.
        let positional = ctx.seed.flatMap { $0.isEmpty ? nil : $0 }.map { [$0] } ?? []
        if let launch = CodexLaunchConfiguration.appServerLaunch(
            binary: binary, context: ctx, agentId: id,
            clientArguments: arguments, positional: positional
        ) {
            return launch.argv
        }
        return [binary] + arguments + positional
    }

    /// Receive-direction format: Codex 0.135+ reads the SAME `hookSpecificOutput.additionalContext`
    /// envelope Claude does, so this body is identical — but stated explicitly (not inherited) so the
    /// shape is a deliberate Codex choice, not a silent inheritance of Claude's.
    public func encode(_ r: HookResponse, for event: HookEvent) -> String? {
        if let c = r.additionalContext { return HookEnvelope.additionalContext(c) }
        return nil
    }

    public func sessionInfo(_ ctx: AdapterContext, current: String?, prior: [String]) -> AgentSessionInfo? {
        guard let sid = current, !sid.isEmpty else {
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

    // MARK: rollout metadata lookup — sessions / rollout-<timestamp>-<uuid>.jsonl

    var sessionsDir: String { "\(codexHome)/sessions" }

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

}

public extension AgentCapabilities {
    /// Codex's shipped capabilities: app-server-discovered thread ids, file-tail metadata, token-based
    /// context usage, an OS-sandboxed read-only guarantee, and subscription auth.
    static let codex = AgentCapabilities(
        sessionId: .discovered,
        telemetry: .fileTail,
        contextUsage: .tokens,
        readOnlyEnforcement: .sandboxed,
        authMode: .subscription,
        terminalImagePaste: .controlV,
        // SessionStart is lifecycle readiness only. Thread identity and state remain app-server-owned.
        readinessConfirmation: .sessionStartHook)
}
