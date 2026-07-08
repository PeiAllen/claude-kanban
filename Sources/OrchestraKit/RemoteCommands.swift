import Foundation

/// Pure argv builders for SSH connection multiplexing. No process spawning here (that lives in the app's
/// SSHMaster) so the command shape is unit-tested. One master `ssh -M` owns the control socket; the
/// forwarded local UDS carries the JSON-RPC, and terminals attach over the SAME control socket (`-S`),
/// so auth happens once on the master and everything else multiplexes over it.
public enum RemoteCommands {
    /// Shared ssh options: key-only auth, keepalives to notice a dead link, fail-fast forwarding.
    static let commonOpts = [
        "-o", "BatchMode=yes",              // key-only; never prompt for a password inside the app
        "-o", "ServerAliveInterval=15",     // detect a dead link within ~45s
        "-o", "ServerAliveCountMax=3",
        "-o", "ExitOnForwardFailure=yes",   // fail fast if the -L forward can't be set up
    ]

    /// Master ssh argv: a multiplexed control master forwarding the remote daemon socket to a local
    /// socket. Foreground (`-N`, no `-f`) so the app owns the Process and gets exit callbacks.
    public static func sshMasterArgs(target: String, identityFile: String?, controlPath: String,
                                     localSocketPath: String, remoteSocketPath: String) -> [String] {
        var a = ["ssh", "-M", "-S", controlPath, "-N",
                 "-L", "\(localSocketPath):\(remoteSocketPath)"]
        a += commonOpts
        if let id = identityFile, !id.isEmpty { a += ["-i", id] }
        a.append(target)
        return a
    }

    /// Tear down the master's control socket.
    public static func sshExitArgs(target: String, controlPath: String) -> [String] {
        ["ssh", "-S", controlPath, "-O", "exit", target]
    }

    /// A terminal child command that attaches to the REMOTE tmux over the shared control socket. Returns
    /// (executable, args) for SwiftTerm's startProcess. `-tt` forces a pty so tmux attaches.
    public static func remoteTmuxAttach(target: String, controlPath: String,
                                        script: String) -> (executable: String, args: [String]) {
        let args = ["-S", controlPath, "-tt"] + commonOpts + [target, "/bin/sh", "-c", script]
        return ("/usr/bin/ssh", args)
    }

    /// sun_path is ~104 bytes incl. NUL; keep a margin so tunnel socket paths never overflow.
    public static func socketPathFits(_ path: String) -> Bool { path.utf8.count < 100 }
}
