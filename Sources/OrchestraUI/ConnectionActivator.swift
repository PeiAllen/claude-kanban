import Foundation
import OrchestraKit
#if os(macOS)
import OrchestraCore
#endif

// Per-platform `ConnectionActivator` conformers (the F2 seam that collapses the two `#if os(...)`
// `activate()` bodies BoardModel used to carry). Each builds a `ControlClient` for a `Connection` and
// tells `BoardStore.activate` how to proceed. Behaviour is byte-for-byte the pre-split logic — only its
// home changed (out of a fork inside `activate`, into a protocol conformer per platform).

#if os(macOS)
/// macOS: resolve the LOCAL socket (spinning the SSH master for a remote via `ConnectionController`),
/// then honour the local-daemon onboarding/install flow. Owns nothing — it drives the store's
/// `ConnectionController`, so a dropped tunnel routes back through `onTunnelExit`.
@MainActor
final class MacConnectionActivator: ConnectionActivator {
    private let controller: ConnectionController
    init(controller: ConnectionController) { self.controller = controller }

    func activate(_ conn: Connection, clientId: String, onboarded: Bool,
                  onTunnelExit: @escaping @Sendable () -> Void) async throws -> ClientActivation {
        controller.deactivate()
        controller.onTunnelExit = { onTunnelExit() }
        let sockPath = try await controller.localSocketPath(for: conn)
        let client = ControlClient(socketPath: sockPath, source: .app, clientId: clientId)
        if conn.isLocal {
            if DaemonLifecycle().isRunning() {
                return ClientActivation(client: client, next: .connect, markOnboarded: true)
            } else if !onboarded {
                return ClientActivation(client: client, next: .onboarding)
            } else {
                return ClientActivation(client: client, next: .offline)
            }
        }
        return ClientActivation(client: client, next: .connect)
    }
}
#else
/// iOS: a `.remote` connection reaches the Mac daemon over SSH (the transport provider builds an
/// `SSHControlTransport` from the shared session); Simulator/dev falls back to the direct-UDS path
/// (`ConnectionSocketResolver` / `ORCH_DEV_SOCKET`). There is no local daemon or SSH master on the phone,
/// so onboarding never applies — always `.connect`.
@MainActor
final class IOSConnectionActivator: ConnectionActivator {
    /// Read the provider LAZILY: the app sets `BoardStore.remoteControlTransportProvider` after `init`,
    /// so the activator must fetch it at activate-time, not capture a (still-nil) value at construction.
    private let provider: () -> RemoteControlTransportProvider?
    init(provider: @escaping () -> RemoteControlTransportProvider?) { self.provider = provider }

    func activate(_ conn: Connection, clientId: String, onboarded: Bool,
                  onTunnelExit: @escaping @Sendable () -> Void) async throws -> ClientActivation {
        let client: ControlClient
        if let factory = provider()?.controlTransportFactory(for: conn) {
            client = ControlClient(transport: factory, source: .app, clientId: clientId)
        } else {
            let sockPath = ConnectionSocketResolver.socketPath(for: conn)
            client = ControlClient(socketPath: sockPath, source: .app, clientId: clientId)
        }
        return ClientActivation(client: client, next: .connect)
    }
}
#endif
