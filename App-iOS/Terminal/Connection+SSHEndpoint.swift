import Foundation
import OrchestraKit

extension Connection {
    /// Parse this connection's SSH target into an endpoint. On iOS the daemon is reached over SSH, so a
    /// `.remote` connection's `sshTarget` is the single source for the endpoint.
    var sshEndpoint: SSHEndpoint? { sshTarget.flatMap(SSHEndpoint.init(target:)) }
}

extension SSHEndpoint {
    /// Derive the endpoint the board + terminals SSH to from the **active connection** — the single
    /// unified source (replaces the removed standalone `orch_ssh_target` setting). Falls back to
    /// `ORCH_SSH_TARGET` (env / Simulator launch arg — mirrors how F3 wires `ORCH_DEV_SOCKET`), which keeps
    /// the dev/Simulator/loopback-verify path working with no in-app config. Returns nil when neither is
    /// set, so the terminal shows a "configure the Mac connection" banner rather than failing silently.
    static func resolve(connection: Connection?,
                        env: [String: String] = ProcessInfo.processInfo.environment) -> SSHEndpoint? {
        if let ep = connection?.sshEndpoint { return ep }
        let target = (env["ORCH_SSH_TARGET"] ?? "").trimmingCharacters(in: .whitespaces)
        return target.isEmpty ? nil : SSHEndpoint(target: target)
    }
}
