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

        // statusLine display happens regardless of whether the report send succeeds.
        if kind == "statusline" {
            print(renderStatusLine(payload: payload, raw: raw), terminator: "")
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
                model: p["model"]?["display_name"]?.stringValue,
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
                  let out = runStatusCommand(cmd, stdin: raw) else { return defaultLine }
            return out.isEmpty ? defaultLine : out
        case .passthroughGlobal:
            guard let cmd = globalStatusLineCommand(), let out = runStatusCommand(cmd, stdin: raw)
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

    /// Run a user statusLine command like Claude does: sh -c, same stdin JSON, inherited env, short
    /// timeout so a hung script can't wedge the bar. Returns stdout (trimmed) or nil on failure.
    static func runStatusCommand(_ cmd: String, stdin: Data) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        inPipe.fileHandleForWriting.write(stdin)
        try? inPipe.fileHandleForWriting.close()
        // 1s timeout
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); sem.signal() }
        if sem.wait(timeout: .now() + 1.0) == .timedOut { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: bounded send

    static func boundedSend(sock: String, params: JSONValue, budgetMs: Int) async {
        let task = _Concurrency.Task {
            let client = ControlClient(socketPath: sock, source: .agent)
            do { try client.connect() } catch { return }
            _ = try? await client.call("report", params)
            client.close()
        }
        // Race the send against the budget.
        let timeout = _Concurrency.Task {
            try? await _Concurrency.Task.sleep(for: .milliseconds(budgetMs))
        }
        _ = await timeout.value
        task.cancel()
    }
}
