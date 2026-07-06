import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

// Shared swift-nio-ssh client primitives, used by BOTH the per-terminal `SSHPTYChannel` and the shared
// `IOSSSHSession` (the board's control transport). Extracted so auth, the host-key pinning policy, and
// the write box exist once. `PinningHostKeyDelegate` reports a host-key change via a plain closure so it
// is agnostic to who consumes the verdict (a terminal's bridge, or the session's fan-out).

/// Confines a NIO `Channel` so the main actor can write to it (on the channel's own event loop).
final class ChannelBox: @unchecked Sendable {
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
///
/// We have exactly ONE key to offer. If the server rejects it, NIOSSH calls back here again — so without a
/// guard we'd re-offer the SAME key unboundedly (#9): the server keeps rejecting, auth never terminates,
/// and the terminal hangs on `[connecting…]`. `hasOffered` makes the second call give up (`succeed(nil)`),
/// which fails auth promptly — the unauthorized-key first-run case surfaces as a clear failure the tail
/// error handler turns into `.failed`, not an infinite handshake. Confined to the connection's event loop.
final class PubkeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let privateKey: NIOSSHPrivateKey
    private var hasOffered = false
    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username; self.privateKey = privateKey
    }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey), !hasOffered else {
            nextChallengePromise.succeed(nil)   // no pubkey method, or our one key was already rejected
            return
        }
        hasOffered = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "",
                                          offer: .privateKey(.init(privateKey: privateKey))))
    }
}

/// Tail of the SSH connection pipeline: guarantees an unhandled inbound error CLOSES the parent channel
/// instead of vanishing (#5). A handshake failure — an unauthorized key (the common first-run case) or a
/// non-sshd endpoint — otherwise fires `errorCaught` into a pipeline with no terminal handler, so the TCP
/// connection is never torn down (one leak per attempt) and any pending child-channel open hangs forever
/// (`[connecting…]` that never resolves, dead Retry/Detach). Closing here fires `closeFuture`, which fails
/// the in-flight `connect()`/`openChannel` so the failure actually surfaces.
final class SSHErrorCloseHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Carries the host-key verdict from the NIO event loop back to the connect-completion handler, so a pin
/// mismatch is reported as the distinct "host key changed" state exactly once (not also as `.failed`).
final class HostKeyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _changed = false
    func markChanged() { lock.lock(); _changed = true; lock.unlock() }
    var changed: Bool { lock.lock(); defer { lock.unlock() }; return _changed }
}

/// Host-key policy: **trust-on-first-use PINNING**. The first connect to a host pins the server key in
/// the Keychain; later connects refuse on a mismatch (the channel carries agent output *and* keystrokes,
/// so accept-any is MITM-able). A changed key invokes `onHostKeyChanged`; a Keychain failure fails closed.
final class PinningHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let store: SSHHostKeyPinStore
    private let onHostKeyChanged: @Sendable (String) -> Void
    private let gate: HostKeyGate

    init(host: String, store: SSHHostKeyPinStore,
         onHostKeyChanged: @escaping @Sendable (String) -> Void, gate: HostKeyGate) {
        self.host = host; self.store = store
        self.onHostKeyChanged = onHostKeyChanged; self.gate = gate
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = SSHHostKeyPinStore.fingerprint(of: hostKey)
        do {
            switch try store.evaluate(host: host, fingerprint: fingerprint) {
            case .pinnedFirstUse, .matched:
                validationCompletePromise.succeed(())
            case .changed:
                gate.markChanged()
                onHostKeyChanged(host)
                validationCompletePromise.fail(HostKeyChangedError(host: host))
            }
        } catch {
            validationCompletePromise.fail(error)   // can't verify → fail closed
        }
    }
}
