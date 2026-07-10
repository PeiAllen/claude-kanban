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
                // Scratch: `--scratch` runs in a fresh throwaway ~/.orchestra/scratch/<id> dir Orchestra
                // makes and deletes on archive (no repo/branch/cwd).
                // Freeform: `--cwd <dir>` runs in an existing directory (no worktree, sandbox-trusted),
                // optionally `--read-only`. Otherwise repo + branch are required (the worktree path).
                // Client-minted id (required wire field). Honour a caller-supplied `--id` so a script that
                // retries `spawn` after a timeout reuses its id → the daemon dedups (idempotent retry);
                // else mint a fresh one.
                let spawnId = flags.value("id").flatMap(UUID.init(uuidString:)) ?? UUID()
                var fields: [String: JSONValue] = [
                    "id": .string(spawnId.uuidString),
                    "prompt": .string(flags.require("prompt")),
                ]
                if flags.has("scratch") {
                    fields["scratch"] = .bool(true)
                    if let r = flags.value("repo") { fields["repo"] = .string(r) }       // optional context
                } else if let cwd = flags.value("cwd") {
                    fields["cwd"] = .string(cwd)
                    if flags.has("read-only") { fields["access"] = .string(CardAccess.readOnly.rawValue) }
                    if let r = flags.value("repo") { fields["repo"] = .string(r) }       // optional context
                } else {
                    fields["repo"] = .string(flags.require("repo"))
                    fields["branch"] = .string(flags.require("branch"))
                }
                let p = JSONValue.object(fields
                    .merging(optional("model", flags.value("model"))) { a, _ in a }
                    .merging(optional("col", flags.value("col"))) { a, _ in a }
                    .merging(optional("seed", flags.value("seed"))) { a, _ in a }
                    .merging(optional("base", flags.value("base"))) { a, _ in a })
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

            case "wait":
                // Watch one or more child cards; block until one concludes, print it, and EXIT — the
                // Claude harness re-invokes the caller in-session (nativeReinvoke wake). The caller
                // re-issues `orchestra wait` on the cards that remain.
                let refs = flags.value("refs").map { $0.split(separator: ",").map(String.init) }
                    ?? flags.positionalsFrom(0)
                guard !refs.isEmpty else { die("wait needs at least one card ref") }
                var waitParams: [String: JSONValue] = ["refs": .array(refs.map { .string($0) })]
                // The watching (parent) card is this session's own id, if launched by Orchestra.
                if let selfId = ProcessInfo.processInfo.environment["ORCHESTRA_TASK_ID"], !selfId.isEmpty {
                    waitParams["watcher"] = .string(selfId)
                }
                let r = try await client.call("wait", .object(waitParams))
                if r["cancelled"]?.boolValue == true { print("wait cancelled") }
                else if let ref = r["ref"]?.stringValue, let kind = r["kind"]?.stringValue {
                    print("concluded: \(ref) (\(kind))")
                } else { printJSON(r) }

            case "handoff":
                // Clean-context handoff of THIS card: resume in place, seeded with the given context.
                // `orchestra handoff <ref> <context...>` (context may also be `--context <text>`).
                let ref = flags.positional(0) ?? flags.require("ref")
                let context = flags.value("context") ?? flags.positionalsFrom(1).joined(separator: " ")
                guard !context.isEmpty else { die("handoff needs context text: orchestra handoff <ref> <context...>") }
                let task = try await client.call("handoff", .object(["ref": .string(ref), "context": .string(context)]))
                printRef(task)

            case "trust":
                // Human-only grant. There is NO --trust flag: trust is a decision a human makes at a
                // tty (or via the MCP elicitation dialog), never a switch an agent can pass.
                let rawPath = flags.positional(0) ?? flags.require("path")
                let path = PathResolver.canonical(rawPath)
                guard isatty(FileHandle.standardInput.fileDescriptor) != 0 else {
                    die(TrustPrompt.nonInteractiveHelp(path))   // exits 1
                }
                FileHandle.standardError.write(Data("Grant agents write trust for \(path)? [y/N] ".utf8))
                guard TrustPrompt.isAffirmative(readLine()) else {
                    die("trust: declined — \(path) stays untrusted")
                }
                let r = try await client.call("trust", .object(["path": .string(path)]))
                if try r.decode(TrustGrantResult.self).granted { print("trusted \(path)") }

            case "set-parent":
                let ref = flags.positional(0) ?? flags.require("ref")
                var params: [String: JSONValue] = ["ref": .string(ref)]
                if let parent = flags.value("parent") ?? flags.positional(1) {
                    params["parent"] = .string(parent)
                }
                if let mode = flags.value("mode") { params["mode"] = .string(mode) }
                if flags.has("watch") { params["watch"] = .bool(true) }
                let task = try await client.call("set-parent", .object(params))
                printRef(task)

            case "tree":
                var params: [String: JSONValue] = [:]
                if let ref = flags.value("ref") ?? flags.positional(0) { params["ref"] = .string(ref) }
                if let repo = flags.value("repo") { params["repo"] = .string(repo) }
                let r = try await client.call("tree", .object(params))
                printJSON(r)

            case "synced":
                let ref = flags.positional(0) ?? flags.require("ref")
                let task = try await client.call("synced", .object(["ref": .string(ref)]))
                printRef(task)

            case "shipped":
                let ref = flags.positional(0) ?? flags.require("ref")
                var shippedParams: [String: JSONValue] = ["ref": .string(ref)]
                // The caller card (this session), so the daemon can skip the parent self-echo (S1-3).
                if let selfId = ProcessInfo.processInfo.environment["ORCHESTRA_TASK_ID"], !selfId.isEmpty {
                    shippedParams["by"] = .string(selfId)
                }
                if flags.has("force") { shippedParams["force"] = .bool(true) }
                let task = try await client.call("shipped", .object(shippedParams))
                printRef(task)

            case "merge-request":
                let ref = flags.positional(0) ?? flags.require("ref")
                let task = try await client.call("merge-request", .object(["ref": .string(ref)]))
                printRef(task)

            case "borrow":
                let ref = flags.positional(0) ?? flags.require("ref")
                let r = try await client.call("borrow", .object(["ref": .string(ref)]))
                if let wt = r["worktree"]?.stringValue { print(wt) } else { printJSON(r) }

            case "release":
                let ref = flags.positional(0) ?? flags.require("ref")
                _ = try await client.call("release", .object(["ref": .string(ref)]))
                print("released")

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
                var execParams: [String: JSONValue] = ["ref": .string(ref), "cmd": .string(cmd)]
                if let t = flags.value("timeout").flatMap(Int.init) { execParams["timeout"] = .int(t) }
                let r = try await client.call("exec", .object(execParams))
                let res = try r.decode(ExecResult.self)
                if !res.stdout.isEmpty { FileHandle.standardOutput.write(Data(res.stdout.utf8)) }
                if !res.stderr.isEmpty { FileHandle.standardError.write(Data(res.stderr.utf8)) }
                exit(res.exitCode)

            case "send-keys":
                // Parse the chord in ARGV ORDER (see SendKeysArgv): `send-keys <ref> Enter --text y`
                // sends Enter THEN the literal `y`. A known key name (Esc, Up, C-c, …) becomes a named
                // key; anything else is literal text; `--text` forces a literal at its position; `--`
                // makes the rest literal text.
                let parsed = SendKeysArgv.parse(args)
                let ref = parsed.ref ?? flags.require("ref")
                guard !parsed.tokens.isEmpty else { die("send-keys needs at least one key or --text") }
                let keys = try parsed.tokens.map { try JSONValue(encodable: $0) }
                _ = try await client.call("send-keys", .object([
                    "ref": .string(ref), "keys": .array(keys), "window": .string(parsed.window),
                ]))
                print("sent-keys")

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

            case "inspect":
                let ref = flags.positional(0) ?? flags.require("ref")
                let r = try await client.call("inspect", .object(["ref": .string(ref)]))
                let session = r["session"]?.stringValue ?? ""
                let window = r["window"]?.stringValue ?? ""
                client.close()
                attach(socket: Config.tmuxSocket, target: "\(session):\(window)")

            case "open-notes":
                // Same path as the inspector's "Open notes" button: open the card's worktree as an
                // Obsidian vault, jumped to the notes its branch changed. Defaults to THIS card via
                // `ORCHESTRA_TASK_ID`, so `/open-notes` inside a card session just works with no ref.
                let ref = flags.positional(0) ?? flags.value("ref")
                    ?? ProcessInfo.processInfo.environment["ORCHESTRA_TASK_ID"]
                guard let ref, !ref.isEmpty else {
                    die("open-notes needs a card ref (or run inside an Orchestra card session)")
                }
                let r = try await client.call("openNotes", .object(["ref": .string(ref)]))
                let opened = r["opened"]?.intValue ?? 0
                let total = r["total"]?.intValue ?? 0
                if total == 0 { print("opened worktree vault in Obsidian (no changed notes)") }
                else if opened < total { print("opened \(opened) of \(total) changed notes in Obsidian") }
                else { print("opened \(total) changed note\(total == 1 ? "" : "s") in Obsidian") }

            case "trustState":
                // Read-only trust query (the SpawnSheet's indicator, from the CLI). Never grants.
                let path = flags.positional(0) ?? flags.require("path")
                let r = try await client.call("trustState", .object(["path": .string(path)]))
                print(r["trusted"]?.boolValue == true ? "trusted" : "untrusted")

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
        // Pad to the longest PhaseDisplayKey rawValue so no key is truncated (e.g. `needsPermission`,
        // `relaunching`) and the column stays aligned; self-maintaining as keys evolve.
        let pillWidth = PhaseDisplayKey.allCases.map(\.rawValue.count).max() ?? 7
        for t in tasks {
            let pill = t.phaseDisplay.rawValue.padding(toLength: pillWidth, withPad: " ", startingAt: 0)
            print("\(t.shortId)  \(pill)  [\(t.column.rawValue)]  \(t.title)  ·  \((t.repo as NSString).lastPathComponent)/\(t.branch)")
        }
    }

    static func renderSessions(_ cs: CardSessions) {
        print("ref:        \(cs.ref)")
        print("cwd:        \(cs.worktree)")
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
        // Stamp a client-minted id on every item that lacks one (required wire field); preserve a
        // caller-supplied item `id` so a retried batch reuses its per-item ids → per-item dedup.
        tasks = tasks.map { item in
            if case .object(var f) = item, f["id"] == nil {
                f["id"] = .string(UUID().uuidString)
                return .object(f)
            }
            return item
        }
        let r = try await client.call("batch-spawn", .object(["tasks": .array(tasks)]))
        let result = try r.decode(BatchSpawnResult.self)
        print("spawned \(result.spawned.count) card(s)")
        for t in result.spawned { print("  \(t.ref())") }
        if !result.failed.isEmpty {
            FileHandle.standardError.write(Data("failed \(result.failed.count):\n".utf8))
            for f in result.failed {
                FileHandle.standardError.write(Data("  [\(f.index)] \(f.prompt): \(f.error)\n".utf8))
            }
            exit(1)   // non-zero so scripts can detect partial/total failure
        }
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
            if a == "--" {   // end-of-flags: everything after is a literal positional
                positionals.append(contentsOf: args[(i + 1)...]); break
            }
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
        // No positional(0) fallback: it made multiple required flags collide onto the same bare
        // positional (e.g. `spawn foo` → prompt=repo=branch=foo). Ref-style commands that DO accept a
        // bare positional already do `positional(0) ?? require("ref")` at the call site.
        die("missing --\(key)")
    }
}
