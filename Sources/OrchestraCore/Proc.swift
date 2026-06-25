import Foundation

/// Result of running a subprocess.
public struct ProcResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public var ok: Bool { exitCode == 0 }
}

/// Thin wrapper around `Process` for running git/tmux/agents with `[String]` argv (never an
/// interpolated shell string) — the security posture from the contract. `sh -c` is used *only* by
/// `exec`, where the command is the intended payload.
public enum Proc {
    /// Run `argv` (argv[0] resolved on PATH via /usr/bin/env), capturing stdout/stderr.
    @discardableResult
    public static func run(
        _ argv: [String],
        cwd: String? = nil,
        env extraEnv: [String: String] = [:],
        timeout: Duration? = nil
    ) throws -> ProcResult {
        guard let first = argv.first else { throw OrchestraError.invalidParams("empty argv") }

        let p = Process()
        // Resolve the binary on PATH using /usr/bin/env so adapters can name e.g. "claude".
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.augmentedPATH(env["PATH"])
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Drain both pipes with readability handlers (event-driven, on Foundation's own queues) and
        // detect exit via terminationHandler — NOT a blocking reader thread per pipe + a blocking
        // waitUntilExit thread. The old design burned ~3 GCD worker threads per call; under heavy
        // concurrency that starved the global pool so the wait dispatch never got scheduled, tripping
        // a FALSE timeout at exactly the configured value. Handlers still drain continuously, so a
        // large child can't deadlock on a full pipe buffer.
        let outBox = DataBox(), errBox = DataBox()
        let drained = DispatchGroup()
        for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {                 // EOF: the child closed its write end
                    fh.readabilityHandler = nil
                    drained.leave()
                } else {
                    box.append(chunk)
                }
            }
        }

        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }

        do {
            try p.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw OrchestraError.toolMissing(first)
        }

        // Wait for exit on the CALLING thread (no extra worker thread). On timeout, escalate.
        if let timeout {
            if exited.wait(timeout: .now() + .milliseconds(timeout.milliseconds)) == .timedOut {
                p.terminate()
                if exited.wait(timeout: .now() + .seconds(2)) == .timedOut {
                    kill(p.processIdentifier, SIGKILL)
                    exited.wait()
                }
            }
        } else {
            exited.wait()
        }
        drained.wait()   // let the readability handlers finish appending through EOF

        return ProcResult(
            stdout: String(decoding: outBox.data, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self),
            exitCode: p.terminationStatus
        )
    }

    /// Run, throwing if the exit code is non-zero (for control verbs where failure is an error).
    @discardableResult
    public static func checked(
        _ argv: [String],
        cwd: String? = nil,
        env: [String: String] = [:],
        mapError: (ProcResult) -> Error = { OrchestraError.io($0.stderr.isEmpty ? "exit \($0.exitCode)" : $0.stderr) }
    ) throws -> ProcResult {
        let r = try run(argv, cwd: cwd, env: env)
        if !r.ok { throw mapError(r) }
        return r
    }

    /// Is a tool resolvable on PATH?
    public static func toolExists(_ name: String) -> Bool {
        (try? run(["which", name]))?.ok ?? false
    }

    /// The inherited PATH plus the standard CLI install locations, so tools resolve even when the
    /// daemon/app was launched by launchd or Finder (a login session's PATH is minimal — typically
    /// just `/usr/bin:/bin:/usr/sbin:/sbin` — and omits Homebrew + per-user bins where `tmux`,
    /// `claude`, etc. actually live). Common dirs are appended (not prepended) so an explicitly-set
    /// PATH still wins. Public so the app (e.g. the embedded terminal launching tmux) shares it.
    public static func augmentedPATH(_ inherited: String?) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let common = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
                      "\(home)/.local/bin", "\(home)/bin"]
        var seen = Set<String>()
        var dirs: [String] = []
        for dir in (inherited?.split(separator: ":").map(String.init) ?? []) + common {
            if !dir.isEmpty, seen.insert(dir).inserted { dirs.append(dir) }
        }
        return dirs.joined(separator: ":")
    }
}

/// A tiny thread-safe data accumulator for pipe draining.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    func append(_ d: Data) { lock.lock(); _data.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return _data }
}

extension Duration {
    /// Whole milliseconds (floored), for bridging to DispatchTimeInterval.
    var milliseconds: Int {
        let (s, attos) = (components.seconds, components.attoseconds)
        return Int(s) * 1000 + Int(attos / 1_000_000_000_000_000)
    }
}
