import Foundation
import SwiftUI
import Crypto
@preconcurrency import NIOCore
@preconcurrency import NIOSSH
import OrchestraKit

/// Thread-safe holder for the current session so an off-main consumer (the `ControlClient` transport
/// factory, invoked on a background connect thread) can read it without touching the `@MainActor`
/// controller. This box IS the "read current session lazily, never cache" indirection.
final class CurrentSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: IOSSSHSession?
    func current() -> IOSSSHSession? { lock.lock(); defer { lock.unlock() }; return session }
    func set(_ s: IOSSSHSession?) { lock.lock(); session = s; lock.unlock() }
}

/// Owns the shared `IOSSSHSession` for the active connection — the iOS analog of desktop's
/// `ConnectionController`. Rebuilds the session on connection-switch, reconnects on foreground, and vends
/// the *current* session (via `sessionProvider`) to the board's control transport (and, in P2, terminals).
@MainActor
final class IOSConnectionController: ObservableObject, RemoteControlTransportProvider {
    @Published private(set) var state: ConnectionState = .down

    private let group: EventLoopGroup
    private let box = CurrentSessionBox()
    private var activeTarget: String?

    init(group: EventLoopGroup = TerminalRuntime.group) { self.group = group }

    /// A `@Sendable` accessor for the current session — safe to call off the main actor.
    var sessionProvider: @Sendable () -> IOSSSHSession? { { [box] in box.current() } }

    /// Build (or reuse) the session for `conn`. Tears down a session for a different target first.
    func configure(_ conn: Connection) {
        guard let endpoint = conn.sshEndpoint else { teardown(); return }
        if activeTarget == conn.sshTarget, box.current() != nil { return }   // reuse the live session
        box.current()?.close()

        let key: NIOSSHPrivateKey
        do {
            key = NIOSSHPrivateKey(ed25519Key: try SSHKeyStore.loadOrCreateIdentity())
        } catch {
            state = .down; box.set(nil); activeTarget = nil
            return
        }
        let session = IOSSSHSession(endpoint: endpoint, group: group, privateKey: key)
        session.onStateChange { [weak self] s in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.state = s } }
        }
        box.set(session)
        activeTarget = conn.sshTarget
    }

    /// Reconnect eagerly when the app returns to the foreground (iOS suspends the socket in the background).
    func onScenePhase(_ phase: ScenePhase) {
        guard phase == .active, let session = box.current() else { return }
        if session.state == .down { _ = session.connect() }
    }

    func teardown() {
        box.current()?.close()
        box.set(nil)
        activeTarget = nil
        state = .down
    }

    // MARK: RemoteControlTransportProvider

    func controlTransportFactory(for connection: Connection) -> (@Sendable () -> Transport)? {
        guard connection.kind == .remote, connection.sshEndpoint != nil else { return nil }
        configure(connection)
        let provider = sessionProvider
        let sock = connection.remoteSocketPath ?? Connection.defaultMacSocketPath
        return { SSHControlTransport(session: provider, remoteSocketPath: sock) }
    }
}
