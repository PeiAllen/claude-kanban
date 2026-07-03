import Foundation
import OrchestraCore
#if canImport(Darwin)
import Darwin
#endif

/// The hidden `orchestra _report --event <kind>` helper, run by the agent's statusLine + hooks. Reads
/// the event JSON from stdin, maps it to a StatusReport, and calls the daemon's `report` over
/// $ORCHESTRA_SOCK keyed by $ORCHESTRA_TASK_ID. For `statusline` it also prints the display line per
/// Config.statusLineMode. Best-effort: never fails the agent (always exits 0).
enum ReportHelper {
    static func run(_ args: [String]) async {
        let env = ProcessInfo.processInfo.environment
        let kind = Flags(args).value("event") ?? "statusline"
        let raw = readAllStdin()
        let payload = (try? JSONValue.parse(raw)) ?? .object([:])

        // statusLine display happens regardless of whether the report send succeeds. Write it
        // UNBUFFERED and BEFORE the send: against a pipe (Claude captures stdout) stdio is
        // block-buffered and would otherwise only flush at exit() — i.e. after the bounded send — so
        // a momentarily-slow daemon could stall the self-healing status bar. The bar must never wait
        // on the network. FileHandle.write bypasses stdio buffering.
        if kind == "statusline" {
            writeStdout(Data(renderStatusLine(payload: payload, raw: raw).utf8))
        }

        guard let taskId = env["ORCHESTRA_TASK_ID"], !taskId.isEmpty else { return }
        let sock = env["ORCHESTRA_SOCK"] ?? Config.socketPath

        // `orient` (Codex SessionStart hook): orientation ONLY — print the card's column/mode/self-id
        // `additionalContext`, send NO telemetry (Codex telemetry is the daemon-side rollout tail). This
        // is the agent-agnostic inbound channel; Claude folds the same brief onto its `session` event
        // below. Returns early — no parse, no report.
        if kind == "orient" {
            await emitSessionBrief(taskId: taskId, sock: sock, source: payload["source"]?.stringValue)
            return
        }

        // Parse is the ADAPTER's (agent-dependent, D3). This `_report` process IS the Claude hooksPush
        // transport; it supplies raw bytes and lets the adapter normalize them. Daemon-side transports
        // (Codex rollout tail, next PR) call the same `adapter.parse` seam.
        guard let report = ClaudeCodeAdapter().parse(.hooksPush(kind: kind, payload: payload))
        else { return }  // dropped (e.g. transition SessionEnd, unknown kind)

        let params = JSONValue.object(["ref": .string(taskId),
                                       "report": (try? JSONValue(encodable: report)) ?? .object([:])])
        // Bounded send: statusLine ~50ms (snapshot self-heals), hooks ~2s (Claude waits for them).
        let budgetMs = kind == "statusline" ? 50 : 2000
        await boundedSend(sock: sock, params: params, budgetMs: budgetMs)

        // SessionStart orientation (Claude): on a fresh open / reopen / clear (NOT a mid-turn compact),
        // print the card's live column/mode/self-id as the SessionStart hook's `additionalContext`, so the
        // agent knows where it was opened and starts on that footing without being told. Additive: the
        // session→(waiting/clear) report sent above is unchanged.
        if kind == "session" {
            await emitSessionBrief(taskId: taskId, sock: sock, source: payload["source"]?.stringValue)
        }

        // F3 Stop-drain: on the Stop hook (same `_report --event notify` command — distinguished by the
        // stdin `hook_event_name`), pull the card's durable inbox and, if non-empty, print the
        // `decision:block` continuation so Claude reads the queued messages as context. Additive: the
        // notify→waiting report sent above is unchanged, and non-Stop events never reach here.
        if payload["hook_event_name"]?.stringValue == "Stop" {
            let drainParams = JSONValue.object(["ref": .string(taskId)])
            if let resp = await boundedCall(sock: sock, method: "drain", params: drainParams, budgetMs: 2000),
               let reason = resp["reason"]?.stringValue, !reason.isEmpty {
                writeStdout(Data(StopDrain.blockJSON(reason: reason).utf8))
            }
        }
    }

    /// Fetch the card's live orientation (column + mode + self-id) from the daemon and print it as a
    /// SessionStart hook `additionalContext` payload (byte-identical schema for Claude and Codex). Skips
    /// a mid-turn `compact` so we don't re-announce where the agent already has its bearings. Best-effort
    /// and bounded — a slow/absent daemon just prints nothing.
    static func emitSessionBrief(taskId: String, sock: String, source: String?) async {
        guard (source ?? "startup") != "compact" else { return }
        let params = JSONValue.object(["ref": .string(taskId)])
        if let resp = await boundedCall(sock: sock, method: "sessionBrief", params: params, budgetMs: 2000),
           let context = resp["context"]?.stringValue, !context.isEmpty {
            writeStdout(Data(HookEnvelope.additionalContext(context).utf8))
        }
    }

    // MARK: crash-safe stdio
    //
    // The statusLine + hook pipes to Claude break the instant a self-close (`archive`) kills the
    // card's session — right when this helper runs. `FileHandle`'s read/write RAISE an uncatchable
    // ObjC `NSFileHandleOperationException` on the resulting EPIPE (Swift `try?` can't catch it →
    // `terminate()` → SIGABRT → the "orchestra quit unexpectedly" popup). This helper is contractually
    // best-effort (always exits 0, never fails the agent), so it does its own POSIX I/O and swallows
    // EPIPE/any error. Paired with the process-wide `signal(SIGPIPE, SIG_IGN)` in main, so the raw
    // signal can't kill us before the syscall even returns.

    /// Write all bytes to stdout, swallowing EPIPE/errors (never raises). Handles partial writes/EINTR.
    static func writeStdout(_ data: Data) {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var off = 0
            while off < buf.count {
                let n = Darwin.write(1, base + off, buf.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && errno == EINTR { continue }
                return   // EPIPE / any error: the reader is gone — drop it, never crash.
            }
        }
    }

    /// Read stdin to EOF via POSIX, swallowing errors (never raises).
    static func readAllStdin() -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(0, $0.baseAddress, $0.count) }
            if n > 0 { out.append(contentsOf: buf[0..<n]); continue }
            if n < 0 && errno == EINTR { continue }
            break   // EOF (0) or any error
        }
        return out
    }

    // MARK: statusLine display

    /// Hung-script backstop for the passthrough statusLine command. Not a Claude mirror — Claude
    /// imposes no fixed timeout (it cancels the in-flight run on the next refresh) — so this only has
    /// to exceed real statusLine scripts (ccusage/cost lookups routinely take 2-4s). A tighter bound
    /// (the old 1s) made passthrough always time out and fall back to the orchestra default.
    static let statusLineTimeout: Duration = .seconds(5)

    static func renderStatusLine(payload p: JSONValue, raw: Data) -> String {
        let config = ConfigStore.load()
        let model = p["model"]?["display_name"]?.stringValue ?? "claude"
        let ctx = p["context_window"]?["used_percentage"]?.doubleValue
        let defaultLine = ctx != nil ? "\(model) · \(Int(ctx!))%" : model

        switch config.statusLineMode {
        case .orchestraDefault:
            return defaultLine
        case .custom:
            guard let cmd = config.customStatusLine, !cmd.isEmpty,
                  let out = Proc.runShell(cmd, stdin: raw, timeout: statusLineTimeout) else { return defaultLine }
            return out.isEmpty ? defaultLine : out
        case .passthroughGlobal:
            guard let cmd = globalStatusLineCommand(),
                  let out = Proc.runShell(cmd, stdin: raw, timeout: statusLineTimeout)
            else { return defaultLine }
            return out.isEmpty ? defaultLine : out
        }
    }

    static func globalStatusLineCommand() -> String? {
        let path = "\(Config.home)/.claude/settings.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let jv = try? JSONValue.parse(data) else { return nil }
        return jv["statusLine"]?["command"]?.stringValue
    }

    // MARK: bounded send

    /// Send the report, returning as soon as the daemon acks OR the budget elapses — whichever is
    /// first. Critically, on a budget trip we `close()` the client, which RESUMES the in-flight
    /// `call` with an error so the send task ends immediately. (Cancellation alone wouldn't bound it:
    /// `call` is a CheckedContinuation that doesn't observe cancellation, so without the close the
    /// task group would still implicitly await the full round-trip and the "budget" would be a lie.)
    static func boundedSend(sock: String, params: JSONValue, budgetMs: Int) async {
        let client = ControlClient(socketPath: sock, source: .agent)
        do { try client.connect() } catch { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await client.call("report", params) }
            group.addTask { try? await _Concurrency.Task.sleep(for: .milliseconds(budgetMs)) }
            await group.next()   // first to finish: send completed, or budget tripped
            client.close()       // unblock the send if the budget tripped; idempotent if it acked
            group.cancelAll()
        }
    }

    /// Like `boundedSend`, but returns the daemon's `result` (or nil on timeout/error). Used by the Stop
    /// drain, which needs the response payload. Same close-to-unblock discipline as `boundedSend`.
    static func boundedCall(sock: String, method: String, params: JSONValue, budgetMs: Int) async -> JSONValue? {
        let client = ControlClient(socketPath: sock, source: .agent)
        do { try client.connect() } catch { return nil }
        return await withTaskGroup(of: JSONValue?.self) { group in
            group.addTask { try? await client.call(method, params) }
            group.addTask { try? await _Concurrency.Task.sleep(for: .milliseconds(budgetMs)); return nil }
            let first = await group.next() ?? nil   // whichever finished first: the response, or nil on timeout
            client.close()                           // unblock the call if the budget tripped; idempotent
            group.cancelAll()
            return first
        }
    }
}
