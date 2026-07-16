import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOTransportServices
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
/// board's control transport and the terminals, so auth + the tailnet-shape guard happen exactly once
/// (at connect) instead of per channel.
///
/// Lazy reconnect: `connect()` is idempotent and connect-once (concurrent callers share one in-flight
/// attempt); on drop the connection resets so the next `connect()` re-establishes. The session never runs
/// its own reconnect loop — the controller (`scenePhase`) and `ControlClient` (its retry loop) drive
/// re-`open()`, and each re-open awaits `connect()`, so the two never fight.
final class IOSSSHSession: @unchecked Sendable {
    /// The Mac this session authenticates to. Read by terminals to decide whether the shared session
    /// matches their target (the multiplex fold) — see `SSHPTYChannel.sharedSessionIfMatching`.
    let endpoint: SSHEndpoint
    private let group: EventLoopGroup
    private let privateKey: NIOSSHPrivateKey

    private let lock = NSLock()
    private var _state: ConnectionState = .down
    private var parent: Channel?
    private var inFlight: EventLoopFuture<Void>?
    /// Monotonic attempt id. Every callback that clears `inFlight` (success, failure, later disconnect)
    /// does so only if it still owns the latest attempt — so a stale completion can't wipe a newer
    /// attempt's in-flight future (the #9 livelock: a sub-ms failure clearing an in-flight slot the next
    /// connect() just filled, then serving that dead future to every caller forever).
    private var connectGen = 0
    private var stateSubs: [(ConnectionState) -> Void] = []

    init(endpoint: SSHEndpoint, group: EventLoopGroup, privateKey: NIOSSHPrivateKey) {
        self.endpoint = endpoint; self.group = group
        self.privateKey = privateKey
    }

    var state: ConnectionState { lock.lock(); defer { lock.unlock() }; return _state }
    func onStateChange(_ cb: @escaping (ConnectionState) -> Void) {
        lock.lock(); stateSubs.append(cb); lock.unlock()
    }

    private func setState(_ s: ConnectionState) {
        lock.lock(); _state = s; let subs = stateSubs; lock.unlock()
        subs.forEach { $0(s) }
    }

    /// Establish the connection once; concurrent callers share one in-flight attempt; `.live` returns
    /// immediately.
    func connect() -> EventLoopFuture<Void> {
        let group = self.group
        lock.lock()
        if _state == .live, parent != nil { lock.unlock(); return group.any().makeSucceededVoidFuture() }
        if let f = inFlight { lock.unlock(); return f }
        // Reserve the in-flight slot BEFORE any async work can complete (#9). The connect future's
        // callbacks clear `inFlight`, and a sub-ms failure ("connection refused") can fire them before we
        // ever store the future — leaving a stale failed future cached that every later connect() returns
        // without re-dialing. So we hand callers a promise we own, publish it as `inFlight` up front, and
        // cascade the real attempt into it. `gen` stamps this attempt; clears are generation-guarded.
        connectGen += 1
        let gen = connectGen
        let promise = group.any().makePromise(of: Void.self)
        inFlight = promise.futureResult
        _state = .connecting
        lock.unlock()
        setState(.connecting)

        // Tailnet-shape guard: only ever connect to a tailnet target — refuse LAN/localhost/public hosts
        // before connecting (DEBUG loopback allowance aside). This is what makes accept-any host-key
        // acceptance safe: the peer is authenticated by Tailscale's WireGuard layer, not the SSH host key.
        if let reason = SSHEndpoint.tailnetRejectionReason(for: endpoint.host),
           !SSHEndpoint.isTestLoopbackAllowed(endpoint.host) {
            clearInFlight(gen)
            setState(.down)
            promise.fail(SSHSessionError.rejected(reason))
            return promise.futureResult
        }

        let key = privateKey, endpoint = self.endpoint
        // Network.framework-backed bootstrap (NIOTransportServices), NOT NIO's POSIX `ClientBootstrap`.
        // On iOS a raw BSD socket never brings up / selects the cellular data interface — Apple routes
        // cellular (and is VPN/Tailscale-aware) only through `NWConnection`, so a POSIX dial goes
        // dead-silent on cellular (zero SYNs) while working on WiFi. NIOTS's default `NWParameters` allow
        // cellular; we deliberately impose no interface restriction. NIOSSH runs identically over either
        // channel, so only the socket layer changes — the tailnet guard above and the pipeline below are
        // untouched.
        let bootstrap = NIOTSConnectionBootstrap(group: group).channelInitializer { channel in
            let config = SSHClientConfiguration(
                userAuthDelegate: PubkeyAuthDelegate(username: endpoint.user, privateKey: key),
                serverAuthDelegate: AcceptAnyHostKeyDelegate())
            return channel.pipeline.addHandler(
                NIOSSHHandler(role: .client(config), allocator: channel.allocator,
                              inboundChildChannelInitializer: nil)
            ).flatMap {
                // Tail handler: an unhandled SSH-handshake error (unauthorized key / non-sshd endpoint)
                // must close the parent so `connect()` fails instead of hanging + leaking the TCP conn (#5).
                channel.pipeline.addHandler(SSHErrorCloseHandler())
            }
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
                // A close()/newer connect() bumped the generation while we were dialing → this attempt is
                // stale; drop the freshly-opened parent instead of resurrecting a torn-down session.
                guard self.connectGen == gen else {
                    self.lock.unlock(); parent.close(promise: nil); return
                }
                self.parent = parent; self._state = .live; self.inFlight = nil
                self.lock.unlock()
                self.setState(.live)
                parent.closeFuture.whenComplete { [weak self] _ in
                    guard let self else { return }
                    self.lock.lock()
                    self.parent = nil; self._state = .down
                    if self.connectGen == gen { self.inFlight = nil }
                    self.lock.unlock()
                    self.setState(.down)
                }
            }
            .flatMapErrorThrowing { [weak self] error in
                self?.clearInFlight(gen)
                self?.setState(.down)
                throw error
            }

        f.cascade(to: promise)
        return promise.futureResult
    }

    /// Clear the in-flight slot only if this attempt is still the latest (generation-guarded, #9).
    private func clearInFlight(_ gen: Int) {
        lock.lock(); if connectGen == gen { inFlight = nil }; lock.unlock()
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
        // Invalidate any in-flight attempt so a late-completing dial can't resurrect a torn-down session
        // (its gen-guarded callbacks become no-ops).
        connectGen += 1
        parent = nil; _state = .down; inFlight = nil
        lock.unlock()
        p?.close(promise: nil)
        setState(.down)
    }
}
