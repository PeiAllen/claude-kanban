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
        let flags = Flags(args)
        let kind = flags.value("event") ?? "statusline"
        let raw = readAllStdin()
        let payload = (try? JSONValue.parse(raw)) ?? .object([:])

        // statusLine display happens regardless of whether the send succeeds. Write it UNBUFFERED and
        // BEFORE any network: against a pipe (Claude captures stdout) stdio is block-buffered and would
        // otherwise only flush at exit() — so a momentarily-slow daemon could stall the self-healing
        // status bar. The bar must never wait on the network. FileHandle.write bypasses stdio buffering.
        if kind == "statusline" {
            writeStdout(Data(renderStatusLine(payload: payload, raw: raw).utf8))
        }

        // THE EDGE: resolve this card's adapter from the baked `--agent`, convert the raw payload to typed
        // telemetry, and send a typed `hook` to the daemon. Raw agent JSON never leaves this process; the
        // daemon dispatches on the typed HookEvent (adapter-free). No agent identity in the wire beyond
        // the event vocabulary. Missing task/agent/unknown event → bail (best-effort; always exits 0).
        guard let taskId = env["ORCHESTRA_TASK_ID"], !taskId.isEmpty,
              let event = HookEvent(rawValue: kind),
              let agentId = flags.value("agent"),
              let adapter = try? AgentRegistry().get(agentId) else { return }
        let sock = env["ORCHESTRA_SOCK"] ?? Config.socketPath

        let report = adapter.parse(.hooksPush(kind: kind, payload: payload))   // raw → typed; raw dies here
        let source = event == .sessionStart ? adapter.sessionSource(payload) : nil
        var fields: [String: JSONValue] = ["ref": .string(taskId), "event": .string(kind)]
        if let report { fields["report"] = (try? JSONValue(encodable: report)) ?? .null }
        if let source { fields["source"] = .string(source.rawValue) }
        let params = JSONValue.object(fields)

        // statusLine never yields a response → pure fire-and-forget send (~50ms; snapshot self-heals).
        // Every other event awaits a possible HookResponse (~2s; the agent waits) and encodes it to stdout.
        if event == .statusLine {
            await boundedSend(sock: sock, method: "hook", params: params, budgetMs: 50)
            return
        }
        guard let resp = await boundedCall(sock: sock, method: "hook", params: params, budgetMs: 2000),
              let response = resp["response"].flatMap({ try? $0.decode(HookResponse.self) }),
              let out = adapter.encode(response, for: event) else { return }
        writeStdout(Data(out.utf8))   // native envelope (orientation / drain continuation) → the agent
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
    static func boundedSend(sock: String, method: String, params: JSONValue, budgetMs: Int) async {
        let client = ControlClient(socketPath: sock, source: .agent)
        do { try client.connect() } catch { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await client.call(method, params) }
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
