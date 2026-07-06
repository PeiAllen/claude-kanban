import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSH
import OrchestraKit

enum SSHSessionError: Error, CustomStringConvertible {
    case rejected(String)
    case notConnected
    var description: String {
        switch self {
        case .rejected(let r): return r
        case .notConnected: return "SSH session not connected"
        }
    }
}

/// The phone's shared, authenticated SSH connection to the Mac — the in-process analog of the desktop
/// `SSHMaster`. One instance == one live SSH connection; it vends `.session` child channels to both the
/// board's control transport and the terminals, so auth + the tailnet guard + TOFU host-key pinning
/// happen exactly once (at connect) instead of per channel.
///
/// Lazy reconnect: `connect()` is idempotent and connect-once (concurrent callers share one in-flight
/// attempt); on drop the connection resets so the next `connect()` re-establishes. The session never runs
/// its own reconnect loop — the controller (`scenePhase`) and `ControlClient` (its retry loop) drive
/// re-`open()`, and each re-open awaits `connect()`, so the two never fight.
final class IOSSSHSession: @unchecked Sendable {
    private let endpoint: SSHEndpoint
    private let group: EventLoopGroup
    private let privateKey: NIOSSHPrivateKey
    private let pinStore: SSHHostKeyPinStore

    private let lock = NSLock()
    private var _state: ConnectionState = .down
    private var parent: Channel?
    private var inFlight: EventLoopFuture<Void>?
    private var stateSubs: [(ConnectionState) -> Void] = []
    private var hostKeySubs: [(String) -> Void] = []

    init(endpoint: SSHEndpoint, group: EventLoopGroup, privateKey: NIOSSHPrivateKey,
         pinStore: SSHHostKeyPinStore = SSHHostKeyPinStore()) {
        self.endpoint = endpoint; self.group = group
        self.privateKey = privateKey; self.pinStore = pinStore
    }

    var state: ConnectionState { lock.lock(); defer { lock.unlock() }; return _state }
    func onStateChange(_ cb: @escaping (ConnectionState) -> Void) {
        lock.lock(); stateSubs.append(cb); lock.unlock()
    }
    func onHostKeyChanged(_ cb: @escaping (String) -> Void) {
        lock.lock(); hostKeySubs.append(cb); lock.unlock()
    }

    private func setState(_ s: ConnectionState) {
        lock.lock(); _state = s; let subs = stateSubs; lock.unlock()
        subs.forEach { $0(s) }
    }
    private func fireHostKey(_ host: String) {
        lock.lock(); let subs = hostKeySubs; lock.unlock()
        subs.forEach { $0(host) }
    }

    /// Establish the connection once; concurrent callers share one in-flight attempt; `.live` returns
    /// immediately.
    func connect() -> EventLoopFuture<Void> {
        let group = self.group
        lock.lock()
        if _state == .live, parent != nil { lock.unlock(); return group.any().makeSucceededVoidFuture() }
        if let f = inFlight { lock.unlock(); return f }
        _state = .connecting
        lock.unlock()
        setState(.connecting)

        // Tailnet-trust guard (defense-in-depth with host-key pinning): only ever connect to a tailnet
        // target — refuse LAN/localhost/public hosts before connecting (DEBUG loopback allowance aside).
        if let reason = SSHEndpoint.tailnetRejectionReason(for: endpoint.host),
           !SSHEndpoint.isTestLoopbackAllowed(endpoint.host) {
            setState(.down)
            return group.any().makeFailedFuture(SSHSessionError.rejected(reason))
        }

        let gate = HostKeyGate()
        let key = privateKey, endpoint = self.endpoint, pinStore = self.pinStore
        let bootstrap = ClientBootstrap(group: group).channelInitializer { channel in
            let config = SSHClientConfiguration(
                userAuthDelegate: PubkeyAuthDelegate(username: endpoint.user, privateKey: key),
                serverAuthDelegate: PinningHostKeyDelegate(
                    host: endpoint.host, store: pinStore,
                    onHostKeyChanged: { [weak self] h in self?.fireHostKey(h) }, gate: gate))
            return channel.pipeline.addHandler(
                NIOSSHHandler(role: .client(config), allocator: channel.allocator,
                              inboundChildChannelInitializer: nil))
        }

        let f: EventLoopFuture<Void> = bootstrap
            .connect(host: endpoint.host, port: endpoint.port)
            .flatMap { parent -> EventLoopFuture<Channel> in
                // Ensure the SSH handler is installed/resolvable, but don't carry it out of the future —
                // `NIOSSHHandler` is not Sendable. `openChannel` fetches it on demand on the parent loop.
                parent.pipeline.handler(type: NIOSSHHandler.self).map { _ in parent }
            }
            .map { [weak self] (parent: Channel) in
                guard let self else { parent.close(promise: nil); return }
                self.lock.lock()
                self.parent = parent; self._state = .live; self.inFlight = nil
                self.lock.unlock()
                self.setState(.live)
                parent.closeFuture.whenComplete { [weak self] _ in
                    guard let self else { return }
                    self.lock.lock()
                    self.parent = nil; self._state = .down; self.inFlight = nil
                    self.lock.unlock()
                    self.setState(.down)
                }
            }
            .flatMapErrorThrowing { [weak self] error in
                self?.lock.lock(); self?.inFlight = nil; self?.lock.unlock()
                if !gate.changed { self?.setState(.down) }   // a host-key change already surfaced distinctly
                throw error
            }

        lock.lock(); inFlight = f; lock.unlock()
        return f
    }

    /// Open a `.session` child channel on the live connection, installing `initializer`'s handler.
    func openChannel(_ initializer: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        let group = self.group
        return connect().flatMap { [weak self] () -> EventLoopFuture<Channel> in
            guard let self else { return group.any().makeFailedFuture(SSHSessionError.notConnected) }
            self.lock.lock(); let parent = self.parent; self.lock.unlock()
            guard let parent else { return group.any().makeFailedFuture(SSHSessionError.notConnected) }
            let promise = parent.eventLoop.makePromise(of: Channel.self)
            parent.eventLoop.execute {
                parent.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                    switch result {
                    case .failure(let e): promise.fail(e)
                    case .success(let handler):
                        handler.createChannel(promise, channelType: .session) { child, _ in initializer(child) }
                    }
                }
            }
            return promise.futureResult
        }
    }

    func close() {
        lock.lock()
        let p = parent
        parent = nil; _state = .down; inFlight = nil
        lock.unlock()
        p?.close(promise: nil)
        setState(.down)
    }
}
