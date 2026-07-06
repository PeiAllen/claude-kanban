import Foundation

/// Dependency-inversion seam so `BoardModel` (in OrchestraUI, which has no SSH stack) can obtain an
/// SSH-backed control `Transport` for a remote `Connection` without referencing the platform SSH types.
///
/// The iOS app provides an implementation (backed by its shared `IOSSSHSession`); the board just asks
/// for a transport factory and hands it to `ControlClient`, which re-invokes it on every reconnect.
@MainActor
public protocol RemoteControlTransportProvider: AnyObject {
    /// A `Transport` factory for reaching this connection's daemon over the platform transport, or `nil`
    /// to fall back to a local socket path.
    func controlTransportFactory(for connection: Connection) -> (@Sendable () -> Transport)?
}
