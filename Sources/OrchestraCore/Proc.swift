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
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Drain pipes concurrently to avoid deadlock on large output.
        let outBox = DataBox(), errBox = DataBox()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { outBox.append(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { errBox.append(d) }
        }

        do {
            try p.run()
        } catch {
            throw OrchestraError.toolMissing(first)
        }

        if let timeout {
            let deadline = DispatchTime.now() + .milliseconds(Int(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000))
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { p.waitUntilExit(); group.leave() }
            if group.wait(timeout: deadline) == .timedOut {
                p.terminate()
                _ = group.wait(timeout: .now() + .seconds(2))
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        } else {
            p.waitUntilExit()
        }

        // Drain any remainder synchronously.
        let outRest = (try? outPipe.fileHandleForReading.readToEnd()) ?? nil
        let errRest = (try? errPipe.fileHandleForReading.readToEnd()) ?? nil
        if let outRest { outBox.append(outRest) }
        if let errRest { errBox.append(errRest) }

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
}

/// A tiny thread-safe data accumulator for pipe draining.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    func append(_ d: Data) { lock.lock(); _data.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return _data }
}
