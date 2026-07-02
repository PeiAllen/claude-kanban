import Foundation
import OrchestraCore

/// Owns one multiplexed master ssh for a remote connection. Foreground child (no `-f`) so we get exit
/// callbacks and can kill it cleanly. Pre-spawn cleanup removes a stale control socket / forwarded
/// socket left by a crash, then waits (bounded) for the forwarded local socket to appear. Terminals and
/// the JSON-RPC transport both ride this one master, so auth happens once.
final class SSHMaster: @unchecked Sendable {
    private let connection: Connection
    private let dir: URL
    let controlPath: String
    let localSocketPath: String
    /// The SSH target (user@host) — exposed so terminals can attach over the control socket.
    var target: String? { connection.sshTarget }

    private var process: Process?
    private let lock = NSLock()
    private var stopping = false
    /// Fired when the master exits unexpectedly (not via `stop()`), off the process's termination thread.
    var onUnexpectedExit: (() -> Void)?

    init(connection: Connection) {
        self.connection = connection
        // Short unique dir under the system temp so both UDS paths stay well under sun_path (~104).
        let short = String(UUID().uuidString.prefix(8)).lowercased()
        self.dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orch-\(short)", isDirectory: true)
        self.controlPath = dir.appendingPathComponent("c").path
        self.localSocketPath = dir.appendingPathComponent("s").path
    }

    func start() async throws {
        guard let target = connection.sshTarget, let remoteSock = connection.remoteSocketPath else {
            throw OrchestraError.io("remote connection missing sshTarget/remoteSocketPath")
        }
        guard RemoteCommands.socketPathFits(localSocketPath), RemoteCommands.socketPathFits(controlPath) else {
            throw OrchestraError.io("tunnel socket path too long for AF_UNIX (\(localSocketPath))")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Pre-spawn cleanup: best-effort close any stale master, unlink stale sockets (avoids
        // "control socket already exists" after a crash).
        _ = try? Proc.run(RemoteCommands.sshExitArgs(target: target, controlPath: controlPath))
        try? FileManager.default.removeItem(atPath: controlPath)
        try? FileManager.default.removeItem(atPath: localSocketPath)

        let argv = RemoteCommands.sshMasterArgs(
            target: target, identityFile: connection.identityFile, controlPath: controlPath,
            localSocketPath: localSocketPath, remoteSocketPath: remoteSock)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = Array(argv.dropFirst())            // drop argv[0] "ssh"; executableURL is ssh
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Proc.augmentedPATH(env["PATH"])    // find ssh under a GUI-launched minimal PATH
        p.environment = env
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            let cb: (() -> Void)? = self.lock.withLock { self.stopping ? nil : self.onUnexpectedExit }
            cb?()
        }
        try p.run()
        lock.withLock { process = p }

        // Wait (bounded) for the forwarded local socket to appear.
        for _ in 0..<100 {                               // ~10s
            if FileManager.default.fileExists(atPath: localSocketPath) { return }
            if !p.isRunning { throw OrchestraError.io("ssh master exited before forwarding the socket") }
            try? await _Concurrency.Task.sleep(for: .milliseconds(100))
        }
        throw OrchestraError.io("timed out waiting for the forwarded socket")
    }

    func stop() {
        lock.withLock { stopping = true }
        if let target = connection.sshTarget {
            _ = try? Proc.run(RemoteCommands.sshExitArgs(target: target, controlPath: controlPath))
        }
        lock.withLock { process }?.terminate()
        lock.withLock { process = nil }
        try? FileManager.default.removeItem(at: dir)
    }
}
