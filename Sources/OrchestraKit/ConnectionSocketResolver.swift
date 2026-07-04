import Foundation

/// Decides which Unix-domain socket path a client should open for a given `Connection`.
///
/// F3 / iOS-Simulator dev transport: for the built-in **local** connection, an `ORCH_DEV_SOCKET`
/// override (set in the Xcode scheme, or `SIMCTL_CHILD_ORCH_DEV_SOCKET` via `simctl launch`) points the
/// Simulator app at the Mac's real daemon socket — because `Config.socketPath` on iOS resolves into the
/// app's sandbox container, not the user's home. Without the override (on macOS, or a device build) it
/// falls back to `Config.socketPath`. Remote connections resolve to their own remote socket path and
/// never consult the dev override (remote reachability is the SSH-forward transport in T1+).
public enum ConnectionSocketResolver {
    public static let devSocketEnvKey = "ORCH_DEV_SOCKET"

    public static func socketPath(
        for connection: Connection,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if connection.isLocal {
            if let override = env[devSocketEnvKey], !override.isEmpty { return override }
            return Config.socketPath
        }
        // Remote: use its configured remote socket path. F3 does not open remote connections, but the
        // resolver stays total so callers never have to special-case it.
        return connection.remoteSocketPath ?? Config.socketPath
    }
}
