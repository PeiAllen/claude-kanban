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
// Concurrency: NIO runs on its own event loops; SwiftTerm + the seam are `@MainActor`. All NIO objects
// are confined behind small `@unchecked Sendable` boxes, and every byte/event is delivered to the main
// actor **in order** via `DispatchQueue.main.async` (FIFO — `Task {}` would not preserve terminal byte
// order).

/// Carries the MainActor UI closures across the NIO boundary with ordered, main-thread delivery.
private final class TerminalCallbackBridge: @unchecked Sendable {
    // Written only on the main actor (in `SSHPTYChannel.start`); read only inside `assumeIsolated`.
    var onOutput: (([UInt8]) -> Void)?
    var onEvent: ((TerminalChannelEvent) -> Void)?

    func data(_ bytes: [UInt8]) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onOutput?(bytes) } }
    }
    func event(_ e: TerminalChannelEvent) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onEvent?(e) } }
    }
}

/// Confines a NIO `Channel` so the main actor can write to it (on the channel's own event loop).
private final class ChannelBox: @unchecked Sendable {
    let channel: Channel
    init(_ channel: Channel) { self.channel = channel }

    func sendBytes(_ bytes: [UInt8]) {
        let channel = self.channel
        channel.eventLoop.execute {
            var buf = channel.allocator.buffer(capacity: bytes.count)
            buf.writeBytes(bytes)
            channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buf)), promise: nil)
        }
    }
    func windowChange(cols: Int, rows: Int) {
        let channel = self.channel
        channel.eventLoop.execute {
            let ev = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols, terminalRowHeight: rows,
                terminalPixelWidth: 0, terminalPixelHeight: 0)
            channel.triggerUserOutboundEvent(ev, promise: nil)
        }
    }
    func close() { channel.close(promise: nil) }
}

/// Offers this device's Ed25519 public key for user auth (key-only; never a password prompt in-app).
private final class PubkeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let privateKey: NIOSSHPrivateKey
    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username; self.privateKey = privateKey
    }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)   // nothing else we can offer
            return
        }
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "",
                                          offer: .privateKey(.init(privateKey: privateKey))))
    }
}

/// Carries the host-key verdict from the NIO event loop (where `validateHostKey` runs) back to the main
/// actor's connect-completion handler, so a pin mismatch is reported as the distinct `.hostKeyChanged`
/// state exactly once (not also as a generic `.failed`).
private final class HostKeyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _changed = false
    func markChanged() { lock.lock(); _changed = true; lock.unlock() }
    var changed: Bool { lock.lock(); defer { lock.unlock() }; return _changed }
}

/// Host-key policy: **trust-on-first-use PINNING** (security #5). The first connect to a host pins the
/// server key (SHA-256 of its canonical OpenSSH form) in the Keychain; every later connect compares the
/// presented key to the pin and REFUSES on a mismatch — the terminal carries agent output *and* your
/// keystrokes, so an accept-any policy is MITM-able. A changed key emits the distinct `.hostKeyChanged`
/// event; a Keychain failure fails closed (we can't verify → don't connect). Reset a pin via Settings.
private final class PinningHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let store: SSHHostKeyPinStore
    private let bridge: TerminalCallbackBridge
    private let gate: HostKeyGate

    init(host: String, store: SSHHostKeyPinStore, bridge: TerminalCallbackBridge, gate: HostKeyGate) {
        self.host = host; self.store = store; self.bridge = bridge; self.gate = gate
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = SSHHostKeyPinStore.fingerprint(of: hostKey)
        do {
            switch try store.evaluate(host: host, fingerprint: fingerprint) {
            case .pinnedFirstUse, .matched:
                validationCompletePromise.succeed(())
            case .changed:
                gate.markChanged()
                bridge.event(.hostKeyChanged(host: host))
                validationCompletePromise.fail(HostKeyChangedError(host: host))
            }
        } catch {
            // Can't read/write the pin → we can't verify the host → fail closed. Surfaces via the
            // connect-completion handler's generic `.failed` path (gate stays unset).
            validationCompletePromise.fail(error)
        }
    }
}

/// The child-channel handler: requests a PTY, execs the attach command, and forwards remote bytes.
private final class PTYChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let cols: Int
    private let rows: Int
    private let bridge: TerminalCallbackBridge

    init(command: String, cols: Int, rows: Int, bridge: TerminalCallbackBridge) {
        self.command = command; self.cols = cols; self.rows = rows; self.bridge = bridge
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
        bridge.event(.closed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        bridge.event(.failed(String(describing: error)))
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
    private let bridge = TerminalCallbackBridge()

    private var state: State = .idle
    private var parentBox: ChannelBox?
    private var childBox: ChannelBox?
    private var size: (cols: Int, rows: Int) = (80, 24)

    /// - Parameters:
    ///   - endpoint: the Mac to SSH to.
    ///   - command: the remote command to exec under the PTY — a `/bin/sh`-runnable string, typically a
    ///     `TmuxAttach.attachScript(...)` wrapped with a PATH/locale prelude (see `RemoteTmuxCommand`).
    ///   - group: shared event-loop group (owned by the app so channels don't each spin up threads).
    init(endpoint: SSHEndpoint, command: String, group: EventLoopGroup) {
        self.endpoint = endpoint
        self.command = command
        self.group = group
    }

    func start(cols: Int, rows: Int) {
        // Idempotent: no-op while already connecting/open. A fresh start is allowed from idle/closed,
        // which is exactly the reconnect path (server-side the attach recipe is idempotent too).
        guard state == .idle || state == .closed else { return }
        state = .connecting
        size = (cols, rows)
        bridge.onOutput = onOutput
        bridge.onEvent = onEvent
        onEvent?(.connecting)

        // Tailscale-trust guard (review #5), defense-in-depth with `PinningHostKeyDelegate`'s host-key
        // pinning below: only ever connect to a tailnet target — refuse a LAN/localhost/public host
        // before connecting, so the pinned SSH channel is only ever established over the trusted tailnet.
        if let reason = SSHEndpoint.tailnetRejectionReason(for: endpoint.host) {
            state = .closed
            onEvent?(.failed(reason))
            return
        }

        let key: NIOSSHPrivateKey
        do {
            key = NIOSSHPrivateKey(ed25519Key: try SSHKeyStore.loadOrCreateIdentity())
        } catch {
            state = .closed
            onEvent?(.failed("SSH key unavailable: \(error)"))
            return
        }

        let endpoint = self.endpoint, command = self.command, bridge = self.bridge
        let group = self.group
        let pinStore = SSHHostKeyPinStore()
        let gate = HostKeyGate()

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                let config = SSHClientConfiguration(
                    userAuthDelegate: PubkeyAuthDelegate(username: endpoint.user, privateKey: key),
                    serverAuthDelegate: PinningHostKeyDelegate(
                        host: endpoint.host, store: pinStore, bridge: bridge, gate: gate))
                return channel.pipeline.addHandler(
                    NIOSSHHandler(role: .client(config), allocator: channel.allocator,
                                  inboundChildChannelInitializer: nil))
            }

        // Connect → resolve the SSH handler → open a session child channel → install the PTY handler.
        let childFuture: EventLoopFuture<(Channel, Channel)> = bootstrap
            .connect(host: endpoint.host, port: endpoint.port)
            .flatMap { parent -> EventLoopFuture<(Channel, Channel)> in
                let childPromise = parent.eventLoop.makePromise(of: Channel.self)
                parent.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                    switch result {
                    case .failure(let e):
                        childPromise.fail(e)
                    case .success(let ssh):
                        ssh.createChannel(childPromise, channelType: .session) { child, _ in
                            child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                                child.pipeline.addHandler(
                                    PTYChannelHandler(command: command, cols: cols, rows: rows, bridge: bridge))
                            }
                        }
                    }
                }
                return childPromise.futureResult.map { (parent, $0) }
            }

        childFuture.whenComplete { result in
            switch result {
            case .success(let (parent, child)):
                let parentB = ChannelBox(parent), childB = ChannelBox(child)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.attached(parent: parentB, child: childB) }
                }
            case .failure(let error):
                // A host-key change already emitted the distinct `.hostKeyChanged` state — don't also
                // report it as a generic connection failure (which would trigger a reconnect loop).
                if !gate.changed {
                    bridge.event(.failed(String(describing: error)))
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if self.state == .connecting { self.state = .closed }
                    }
                }
            }
        }
    }

    private func attached(parent: ChannelBox, child: ChannelBox) {
        guard state == .connecting else { child.close(); parent.close(); return }
        parentBox = parent
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
        parentBox?.close()
        childBox = nil
        parentBox = nil
    }
}
