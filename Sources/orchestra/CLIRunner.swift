import Foundation
import OrchestraCore

/// Parses argv flags into command params and calls the daemon.
enum CLIRunner {
    static func run(verb: String, args: [String], socketPath: String) async {
        let flags = Flags(args)
        let client = ControlClient(socketPath: socketPath, source: .cli)
        do { try client.connect() }
        catch {
            FileHandle.standardError.write(Data("orchestra: daemon not reachable at \(socketPath) (\(error))\n".utf8))
            exit(1)
        }
        defer { client.close() }

        do {
            switch verb {
            case "list":
                var p: [String: JSONValue] = [:]
                if let c = flags.value("col") { p["col"] = .string(c) }
                let result = try await client.call("list", .object(p))
                renderTasks(result)

            case "spawn":
                let p = JSONValue.object([
                    "prompt": .string(flags.require("prompt")),
                    "repo": .string(flags.require("repo")),
                    "branch": .string(flags.require("branch")),
                ].merging(optional("model", flags.value("model"))) { a, _ in a }
                 .merging(optional("col", flags.value("col"))) { a, _ in a })
                let task = try await client.call("spawn", p)
                printRef(task)

            case "move":
                let ref = flags.positional(0) ?? flags.require("ref")
                guard let col = flags.value("col") ?? flags.positional(1) else { die("move needs a column") }
                _ = try await client.call("move", .object(["ref": .string(ref), "col": .string(col)]))
                print("moved \(ref) → \(col)")

            case "send":
                let ref = flags.positional(0) ?? flags.require("ref")
                let msg = flags.value("message") ?? flags.positionalsFrom(1).joined(separator: " ")
                _ = try await client.call("send", .object(["ref": .string(ref), "message": .string(msg)]))
                print("sent")

            case "status":
                let ref = flags.positional(0) ?? flags.require("ref")
                let r = try await client.call("status", .object(["ref": .string(ref)]))
                printJSON(r)

            case "archive":
                let ref = flags.positional(0) ?? flags.require("ref")
                _ = try await client.call("archive", .object(["ref": .string(ref)]))
                print("archived \(ref)")

            case "restart", "resume":
                let ref = flags.positional(0) ?? flags.require("ref")
                let task = try await client.call(verb, .object(["ref": .string(ref)]))
                printRef(task)

            case "exec":
                let ref = flags.positional(0) ?? flags.require("ref")
                let cmd = flags.value("cmd") ?? flags.positionalsFrom(1).joined(separator: " ")
                let r = try await client.call("exec", .object(["ref": .string(ref), "cmd": .string(cmd)]))
                let res = try r.decode(ExecResult.self)
                if !res.stdout.isEmpty { FileHandle.standardOutput.write(Data(res.stdout.utf8)) }
                if !res.stderr.isEmpty { FileHandle.standardError.write(Data(res.stderr.utf8)) }
                exit(res.exitCode)

            case "sessions":
                let ref = flags.positional(0) ?? flags.require("ref")
                let r = try await client.call("sessions", .object(["ref": .string(ref)]))
                if flags.has("json") { printJSON(r) } else { renderSessions(try r.decode(CardSessions.self)) }

            case "shell":
                let ref = flags.positional(0) ?? flags.require("ref")
                let r = try await client.call("sessions", .object(["ref": .string(ref)]))
                let cs = try r.decode(CardSessions.self)
                client.close()
                attach(socket: cs.tmuxSocket, target: "\(cs.session):agent")

            case "batch-spawn":
                try await batchSpawn(client, flags)

            case "ping":
                _ = try await client.call("ping"); print("pong")

            default:
                die("unknown command: \(verb)\n\n\(CLIHelp.text)")
            }
        } catch let e as OrchestraError {
            die(e.description)
        } catch let e as RPCError {
            die(e.message)
        } catch {
            die("\(error)")
        }
    }

    // MARK: rendering

    static func renderTasks(_ result: JSONValue) {
        guard let tasks = try? result.decode([Task].self) else { printJSON(result); return }
        if tasks.isEmpty { print("(no cards)"); return }
        for t in tasks {
            let pill = t.status.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
            print("\(t.shortId)  \(pill)  [\(t.column.rawValue)]  \(t.title)  ·  \((t.repo as NSString).lastPathComponent)/\(t.branch)")
        }
    }

    static func renderSessions(_ cs: CardSessions) {
        print("ref:        \(cs.ref)")
        print("worktree:   \(cs.worktree)")
        print("running:    \(cs.running)")
        if let sid = cs.agent.sessionId { print("session id: \(sid)") }
        if let tp = cs.agent.transcriptPath { print("transcript: \(tp)") }
        if !cs.agent.priorSessionIds.isEmpty { print("prior ids:  \(cs.agent.priorSessionIds.joined(separator: ", "))") }
        if let rc = cs.agent.resumeCmd { print("resume:     \(rc.joined(separator: " "))") }
        print("windows:")
        for t in cs.targets { print("  \(t.kind == .agent ? "●" : "○") \(t.window)\t\(t.attach)") }
    }

    static func printRef(_ task: JSONValue) {
        if let t = try? task.decode(Task.self) {
            print(t.ref())
        } else { printJSON(task) }
    }

    static func attach(socket: String, target: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["tmux", "-L", socket, "attach", "-t", target]
        try? p.run()
        p.waitUntilExit()
        exit(p.terminationStatus)
    }

    static func batchSpawn(_ client: ControlClient, _ flags: Flags) async throws {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(decoding: stdin, as: UTF8.self)
        var tasks: [JSONValue] = []
        // Try a JSON array first; else treat as one-prompt-per-line.
        if let jv = try? JSONValue.parse(stdin), let arr = jv.arrayValue {
            tasks = arr
        } else {
            let repo = flags.require("repo"); let branch = flags.require("branch")
            for line in text.split(whereSeparator: \.isNewline) {
                let prompt = line.trimmingCharacters(in: .whitespaces)
                if prompt.isEmpty { continue }
                tasks.append(.object(["prompt": .string(prompt), "repo": .string(repo), "branch": .string(branch)]))
            }
        }
        let r = try await client.call("batch-spawn", .object(["tasks": .array(tasks)]))
        let created = (try? r.decode([Task].self)) ?? []
        print("spawned \(created.count) card(s)")
        for t in created { print("  \(t.ref())") }
    }

    static func optional(_ key: String, _ value: String?) -> [String: JSONValue] {
        guard let v = value else { return [:] }
        return [key: .string(v)]
    }
}

/// Minimal argv flag/positional parser: `--key value`, `--flag`, and bare positionals.
struct Flags {
    private var values: [String: String] = [:]
    private var bools: Set<String> = []
    private var positionals: [String] = []

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    values[key] = args[i + 1]; i += 2
                } else { bools.insert(key); i += 1 }
            } else { positionals.append(a); i += 1 }
        }
    }
    func value(_ key: String) -> String? { values[key] }
    func has(_ key: String) -> Bool { bools.contains(key) || values[key] != nil }
    func positional(_ idx: Int) -> String? { idx < positionals.count ? positionals[idx] : nil }
    func positionalsFrom(_ idx: Int) -> [String] { idx < positionals.count ? Array(positionals[idx...]) : [] }
    func require(_ key: String) -> String {
        if let v = value(key) { return v }
        if let p = positional(0) { return p }
        die("missing --\(key)")
    }
}
