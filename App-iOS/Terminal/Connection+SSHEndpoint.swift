import Foundation
import OrchestraKit

extension Connection {
    /// Parse this connection's SSH target into an endpoint. On iOS the daemon is reached over SSH, so a
    /// `.remote` connection's `sshTarget` is the single source for the endpoint.
    var sshEndpoint: SSHEndpoint? { sshTarget.flatMap(SSHEndpoint.init(target:)) }
}

extension SSHEndpoint {
    /// Derive the endpoint from the active connection — the unified source that replaces the standalone
    /// `orch_ssh_target` setting (which P2 removes). The legacy `resolve(env:defaults:)` stays for
    /// terminals until they migrate in P2.
    static func resolve(connection: Connection?) -> SSHEndpoint? {
        connection?.sshEndpoint
    }
}
