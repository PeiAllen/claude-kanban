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

        do {
            try p.run()
        } catch {
            throw OrchestraError.toolMissing(first)
        }

        // Drain both pipes to EOF on background queues — avoids a pipe-buffer deadlock on large
        // output, and each read returns once the child closes its write end (exit or terminate).
        let outBox = DataBox(), errBox = DataBox()
        let drained = DispatchGroup()
        for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
            drained.enter()
            DispatchQueue.global().async {
                box.set(pipe.fileHandleForReading.readDataToEndOfFile())
                drained.leave()
            }
        }

        if let timeout, !waitUntilExit(p, within: timeout) {
            p.terminate()
            if !waitUntilExit(p, within: .seconds(2)) { kill(p.processIdentifier, SIGKILL) }
        } else if timeout == nil {
            p.waitUntilExit()
        }
        drained.wait()

        return ProcResult(
            stdout: String(decoding: outBox.data, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self),
            exitCode: p.terminationStatus
        )
    }

    /// Wait for the process to exit, up to `timeout`. Returns true if it exited in time.
    private static func waitUntilExit(_ p: Process, within timeout: Duration) -> Bool {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        return done.wait(timeout: .now() + .milliseconds(timeout.milliseconds)) == .success
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
    func set(_ d: Data) { lock.lock(); _data = d; lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return _data }
}

extension Duration {
    /// Whole milliseconds (floored), for bridging to DispatchTimeInterval.
    var milliseconds: Int {
        let (s, attos) = (components.seconds, components.attoseconds)
        return Int(s) * 1000 + Int(attos / 1_000_000_000_000_000)
    }
}
