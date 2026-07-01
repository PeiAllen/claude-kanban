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
