import Foundation
import Dispatch
import Crypto
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSH

// The real iOS terminal transport: a SwiftTerm view ⇄ an SSH **exec channel with a PTY** that runs the
// tmux attach recipe on the Mac. This is the design's "iOS terminals over SSH PTY … the daemon still
// proxies no bytes" (phone-client 01-design). iOS apps can't fork/exec the system `ssh` binary, so the
// SSH client is in-process (swift-nio-ssh, Apple's first-party implementation — provider-neutral).
//
// P2 multiplex fold: a terminal opens its PTY child channel on the **shared `IOSSSHSession`** (the same
// authenticated connection the board's control transport uses) whenever that session targets the same
// endpoint — so auth + the tailnet guard + TOFU pinning happen ONCE for the board and every terminal.
// The env/dev path (no connection-backed shared session — e.g. `ORCH_SSH_TARGET` in the T1 harness) falls
// back to a private, terminal-owned session for the same endpoint.
//
// Concurrency: NIO runs on its own event loops; SwiftTerm + the seam are `@MainActor`. All NIO objects
// are confined behind small `@unchecked Sendable` boxes, and every byte/event is delivered to the main
// actor **in order** via `DispatchQueue.main.async` (FIFO — `Task {}` would not preserve terminal byte
// order).

/// Carries the MainActor UI closures across the NIO boundary with ordered, main-thread delivery. Events
/// are generation-stamped: the child handler tags each event with the connection attempt that produced it
/// so `SSHPTYChannel` can drop events from a superseded attempt (the reconnect anti-flap guard, #6).
private final class TerminalCallbackBridge: @unchecked Sendable {
    // Written only on the main actor (in `SSHPTYChannel.start`); read only inside `assumeIsolated`.
    var onOutput: (([UInt8]) -> Void)?
    var onEvent: ((TerminalChannelEvent, Int) -> Void)?

    func data(_ bytes: [UInt8]) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onOutput?(bytes) } }
    }
    func event(_ e: TerminalChannelEvent, generation: Int) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onEvent?(e, generation) } }
    }
}

// `ChannelBox`, `PubkeyAuthDelegate`, `HostKeyGate`, and `PinningHostKeyDelegate` live in
// `SSHClientPrimitives.swift`; the tailnet guard + TOFU pinning now happen inside `IOSSSHSession.connect`.

/// The child-channel handler: requests a PTY, execs the attach command, and forwards remote bytes.
private final class PTYChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let cols: Int
    private let rows: Int
    private let bridge: TerminalCallbackBridge
    private let generation: Int
    /// Set once `errorCaught` has reported `.failed` and closed us — so the `channelInactive` that follows
    /// (the SAME failure) doesn't ALSO emit `.closed` and schedule a second reconnect timer (#6).
    private var erroredOut = false

    init(command: String, cols: Int, rows: Int, bridge: TerminalCallbackBridge, generation: Int) {
        self.command = command; self.cols = cols; self.rows = rows
        self.bridge = bridge; self.generation = generation
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        context.triggerUserOutboundEvent(pty, promise: nil)
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        context.triggerUserOutboundEvent(exec, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = channelData.data else { return }
        // Both stdout (.channel) and stderr (.stdErr) are shown — an attach error should be visible.
        bridge.data(Array(buf.readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !erroredOut { bridge.event(.closed, generation: generation) }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        erroredOut = true
        bridge.event(.failed(String(describing: error)), generation: generation)
        context.close(promise: nil)
    }
}

/// A single SSH-PTY terminal session. One instance backs one `IOSTerminalView`; reconnect reuses the
/// same instance (and the same server-side tmux view session), never stacking a second client.
@MainActor
final class SSHPTYChannel: TerminalByteChannel {
    var onOutput: (([UInt8]) -> Void)?
    var onEvent: ((TerminalChannelEvent) -> Void)?

    private enum State { case idle, connecting, open, closed }

    private let endpoint: SSHEndpoint
    private let command: String
    private let group: EventLoopGroup
    /// The board's shared session (nil in the env/dev path). Read fresh on each `start` — never cached —
    /// so a reconnect after a connection switch picks up the current session.
    private let sharedSession: @Sendable () -> IOSSSHSession?
    private let bridge = TerminalCallbackBridge()

    private var state: State = .idle
    private var childBox: ChannelBox?
    /// Non-nil only when THIS terminal created a private session (env/dev fallback). We close it on
    /// `close()`; a shared session is never closed here (the board + other terminals still use it).
    private var ownedSession: IOSSSHSession?
    private var size: (cols: Int, rows: Int) = (80, 24)
    /// Monotonic connection-attempt counter. Every `start()` bumps it; events are stamped with the attempt
    /// that produced them, so a late event from a superseded child (a stale `.closed` after a reconnect
    /// already began) is dropped instead of flapping the reconnect loop forever (#6).
    private var generation = 0

    /// - Parameters:
    ///   - endpoint: the Mac to SSH to.
    ///   - command: the remote command to exec under the PTY — a `/bin/sh`-runnable string, typically a
    ///     `TmuxAttach.attachScript(...)` wrapped with a PATH/locale prelude (see `RemoteTmuxCommand`).
    ///   - group: shared event-loop group (owned by the app so channels don't each spin up threads).
    ///   - sharedSession: the board's shared `IOSSSHSession` provider (defaults to none — the T1 harness /
    ///     dev path, which makes a private session for `endpoint`).
    init(endpoint: SSHEndpoint, command: String, group: EventLoopGroup,
         sharedSession: @escaping @Sendable () -> IOSSSHSession? = { nil }) {
        self.endpoint = endpoint
        self.command = command
        self.group = group
        self.sharedSession = sharedSession
    }

    /// Choose the session to back this terminal: the shared session when it targets the SAME endpoint
    /// (production — one auth for board + all terminals), otherwise nil, meaning "make a private session"
    /// (the env/dev path where no connection-backed shared session exists, or it targets a different Mac).
    nonisolated static func sharedSessionIfMatching(_ shared: IOSSSHSession?,
                                                    endpoint: SSHEndpoint) -> IOSSSHSession? {
        guard let shared, shared.endpoint == endpoint else { return nil }
        return shared
    }

    func start(cols: Int, rows: Int) {
        // Idempotent: no-op while already connecting/open. A fresh start is allowed from idle/closed,
        // which is exactly the reconnect path (server-side the attach recipe is idempotent too).
        guard state == .idle || state == .closed else { return }
        generation += 1
        let gen = generation
        state = .connecting
        size = (cols, rows)
        bridge.onOutput = onOutput
        // Filter bridge events through generation + intentional-close awareness before they reach the UI.
        bridge.onEvent = { [weak self] e, g in self?.handleBridgeEvent(e, generation: g) }
        onEvent?(.connecting)

        // Reuse the board's shared session when it targets this Mac; otherwise make a private one. Either
        // way, `IOSSSHSession.connect()` performs the tailnet guard + TOFU host-key pinning once, and its
        // failure surfaces here as `.failed` (or, for a host-key change, the distinct `.hostKeyChanged`).
        let session: IOSSSHSession
        if let shared = Self.sharedSessionIfMatching(sharedSession(), endpoint: endpoint) {
            session = shared
            ownedSession = nil
        } else {
            let key: NIOSSHPrivateKey
            do {
                key = NIOSSHPrivateKey(ed25519Key: try SSHKeyStore.loadOrCreateIdentity())
            } catch {
                state = .closed
                onEvent?(.failed("SSH key unavailable: \(error)"))
                return
            }
            let owned = IOSSSHSession(endpoint: endpoint, group: group, privateKey: key)
            ownedSession = owned
            session = owned
        }

        // Distinguish a host-key-change failure from a generic one so we don't ALSO emit `.failed` (which
        // would drive a reconnect loop). We only subscribe on a session we own — a per-attach subscriber on
        // the shared session would accumulate; a shared-session host-key change still surfaces via the
        // connect failure below.
        let gate = HostKeyGate()
        if ownedSession != nil {
            session.onHostKeyChanged { [bridge, gate] host in
                gate.markChanged(); bridge.event(.hostKeyChanged(host: host), generation: gen)
            }
        }

        let command = self.command, bridge = self.bridge
        session.openChannel { child in
            child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                child.pipeline.addHandler(
                    PTYChannelHandler(command: command, cols: cols, rows: rows, bridge: bridge, generation: gen))
            }
        }.whenComplete { result in
            switch result {
            case .success(let child):
                let childB = ChannelBox(child)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.attached(child: childB, generation: gen) }
                }
            case .failure(let error):
                if !gate.changed { bridge.event(.failed(String(describing: error)), generation: gen) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard gen == self.generation else { return }   // a newer attempt already superseded us
                        if self.state == .connecting { self.state = .closed }
                        // #5: a failed child-open on a session WE created would otherwise leak its parent TCP
                        // connection (one per attempt). The shared board session is never ours to close.
                        self.ownedSession?.close()
                        self.ownedSession = nil
                    }
                }
            }
        }
    }

    /// Route a generation-stamped bridge event to the UI, dropping the ones a healthy channel must not see.
    private func handleBridgeEvent(_ e: TerminalChannelEvent, generation gen: Int) {
        guard gen == generation else { return }   // #6: stale attempt — drop (don't reconnect on its echo)
        // A `.closed` while we're already `.closed` is the tail of OUR OWN close()/reconnect teardown, not
        // a remote drop — surfacing it would drive yet another reconnect (the self-inflicted flap).
        if case .closed = e, state == .closed { return }
        onEvent?(e)
    }

    private func attached(child: ChannelBox, generation gen: Int) {
        // A stale success (its reconnect already superseded) must not resurrect an old child (#6).
        guard gen == generation, state == .connecting else { child.close(); return }
        childBox = child
        state = .open
        onEvent?(.connected)
        // Apply any resize that landed while connecting.
        child.windowChange(cols: size.cols, rows: size.rows)
    }

    func send(_ bytes: [UInt8]) {
        guard state == .open, let childBox else { return }
        childBox.sendBytes(bytes)
    }

    func resize(cols: Int, rows: Int) {
        size = (cols, rows)
        guard state == .open, let childBox else { return }
        childBox.windowChange(cols: cols, rows: rows)
    }

    func close() {
        state = .closed
        childBox?.close()
        childBox = nil
        // Only tear down a session WE created. A shared session outlives this terminal (board + peers).
        ownedSession?.close()
        ownedSession = nil
    }
}
