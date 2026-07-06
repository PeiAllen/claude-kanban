import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOSSH
import OrchestraKit

/// The board's control channel over the shared SSH session: a non-PTY `.session` child channel that
/// execs a UDS bridge (`nc -U <daemon.sock>`, `socat` fallback) so the channel's stdio *is* the daemon's
/// NDJSON control stream. Conforms to `Transport`, so the **unchanged** `ControlClient` drives it via its
/// existing `transport:` factory.
///
/// Concurrency: `Transport` is `Sendable` with a **blocking** `readLine()`, called off the NIO loop by
/// `ControlClient`. Inbound bytes arrive asynchronously on the channel; `ControlLineBuffer` bridges the
/// two. The `session` is read via a `@Sendable` provider (never cached) so a reconnect picks up the
/// current session.
final class SSHControlTransport: Transport, @unchecked Sendable {
    private let session: @Sendable () -> IOSSSHSession?
    private let remoteSocketPath: String
    private let buffer = ControlLineBuffer()
    private let lock = NSLock()
    private var childBox: ChannelBox?
    private var closed = false

    init(session: @escaping @Sendable () -> IOSSSHSession?, remoteSocketPath: String) {
        self.session = session
        self.remoteSocketPath = remoteSocketPath
    }

    func open() throws {
        guard let s = session() else { throw SSHSessionError.notConnected }
        try s.connect().wait()
        let command = Self.bridgeCommand(sock: remoteSocketPath)
        let buffer = self.buffer
        let child = try s.openChannel { channel in
            channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                channel.pipeline.addHandler(ControlChannelHandler(command: command, buffer: buffer))
            }
        }.wait()
        lock.lock(); childBox = ChannelBox(child); closed = false; lock.unlock()
    }

    func write(_ data: Data) -> Bool {
        lock.lock(); let box = childBox; let isClosed = closed; lock.unlock()
        guard let box, !isClosed else { return false }
        box.sendBytes([UInt8](data))
        return true
    }

    func readLine() -> Data? { buffer.readLine() }

    /// Close only THIS control channel — never the shared session (terminals may still use it).
    func close() {
        lock.lock(); let box = childBox; childBox = nil; closed = true; lock.unlock()
        box?.close()
        buffer.signalEOF()
    }

    /// The remote command whose stdio is the NDJSON control stream. `nc -U` is always present on macOS;
    /// `socat` is the fallback. A leading `~/` is rewritten to `"$HOME/…"` (double-quoted for the space in
    /// "Application Support") so the path both expands and survives word-splitting in the remote shell.
    static func bridgeCommand(sock: String) -> String {
        let arg = shellArg(sock)
        return "nc -U \(arg) 2>/dev/null || socat - UNIX-CONNECT:\(arg)"
    }

    static func shellArg(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return "\"$HOME/\(path.dropFirst(2))\""
        }
        return "'\(path)'"
    }
}

/// Execs the UDS bridge and pumps the daemon's stdout (`.channel`) into the line buffer. No PTY request —
/// raw stdio, exactly what an NDJSON stream needs. `.stdErr` is diagnostic and ignored by the buffer.
private final class ControlChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let buffer: ControlLineBuffer

    init(command: String, buffer: ControlLineBuffer) {
        self.command = command; self.buffer = buffer
    }

    func channelActive(context: ChannelHandlerContext) {
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        context.triggerUserOutboundEvent(exec, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard channelData.type == .channel, case .byteBuffer(let buf) = channelData.data else { return }
        buffer.append(Array(buf.readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        buffer.signalEOF()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        buffer.signalEOF()
        context.close(promise: nil)
    }
}
