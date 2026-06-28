import Foundation
import OrchestraCore

/// The hidden `orchestra _report --event <kind>` helper, run by the agent's statusLine + hooks. Reads
/// the event JSON from stdin, maps it to a StatusReport, and calls the daemon's `report` over
/// $ORCHESTRA_SOCK keyed by $ORCHESTRA_TASK_ID. For `statusline` it also prints the display line per
/// Config.statusLineMode. Best-effort: never fails the agent (always exits 0).
enum ReportHelper {
    static func run(_ args: [String]) async {
        let env = ProcessInfo.processInfo.environment
        let kind = Flags(args).value("event") ?? "statusline"
        let raw = FileHandle.standardInput.readDataToEndOfFile()
        let payload = (try? JSONValue.parse(raw)) ?? .object([:])

        // statusLine display happens regardless of whether the report send succeeds. Write it
        // UNBUFFERED and BEFORE the send: against a pipe (Claude captures stdout) stdio is
        // block-buffered and would otherwise only flush at exit() — i.e. after the bounded send — so
        // a momentarily-slow daemon could stall the self-healing status bar. The bar must never wait
        // on the network. FileHandle.write bypasses stdio buffering.
        if kind == "statusline" {
            FileHandle.standardOutput.write(Data(renderStatusLine(payload: payload, raw: raw).utf8))
        }

        guard let taskId = env["ORCHESTRA_TASK_ID"], !taskId.isEmpty else { return }
        let sock = env["ORCHESTRA_SOCK"] ?? Config.socketPath

        guard let report = map(kind: kind, payload: payload) else { return }  // dropped (e.g. transition SessionEnd)

        let params = JSONValue.object(["ref": .string(taskId),
                                       "report": (try? JSONValue(encodable: report)) ?? .object([:])])
        // Bounded send: statusLine ~50ms (snapshot self-heals), hooks ~2s (Claude waits for them).
        let budgetMs = kind == "statusline" ? 50 : 2000
        await boundedSend(sock: sock, params: params, budgetMs: budgetMs)
    }

    // MARK: mapping

    static func map(kind: String, payload p: JSONValue) -> StatusReport? {
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
            return StatusReport(status: .running, promptText: p["prompt"]?.stringValue)
        case "tool":
            let tool = p["tool_name"]?.stringValue ?? "tool"
            return StatusReport(desc: toolDesc(tool: tool, input: p["tool_input"]), status: .running)
        case "notify":
            return StatusReport(desc: p["message"]?.stringValue, status: .waiting)
        case "sessionend":
            let reason = p["reason"]?.stringValue ?? "other"
            // Transition reasons are ignored (the matching SessionStart handles them).
            if ["clear", "resume", "compact"].contains(reason) { return nil }
            return StatusReport(endReason: reason)
        default:
            return nil
        }
    }

    static func toolDesc(tool: String, input: JSONValue?) -> String {
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
}
