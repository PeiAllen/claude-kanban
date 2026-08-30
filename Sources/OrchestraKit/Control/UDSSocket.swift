import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Module-neutral POSIX shims. Defined at file scope, where the `UDS` enum's own static
// `listen`/`connect`/`accept`/`read` methods do NOT shadow the C globals, so one set of calls works on
// Darwin and Linux (glibc/musl) alike. `posixSend` carries the SIGPIPE guard: Darwin suppresses it
// per-socket via SO_NOSIGPIPE (set in `suppressSIGPIPE`), while Linux passes MSG_NOSIGNAL on every send.
@inline(__always) private func posixListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
@inline(__always) private func posixConnect(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { connect(fd, a, l) }
@inline(__always) private func posixAccept(_ fd: Int32) -> Int32 { accept(fd, nil, nil) }
@inline(__always) private func posixRead(_ fd: Int32, _ b: UnsafeMutableRawPointer, _ n: Int) -> Int { read(fd, b, n) }
@inline(__always) @discardableResult private func posixClose(_ fd: Int32) -> Int32 { close(fd) }
@inline(__always) private func posixFcntl(_ fd: Int32, _ command: Int32, _ value: Int32) -> Int32 {
    fcntl(fd, command, value)
}
@inline(__always) private func posixPoll(_ fds: UnsafeMutablePointer<pollfd>, _ count: nfds_t,
                                         _ timeout: Int32) -> Int32 {
    poll(fds, count, timeout)
}
#if canImport(Darwin)
@inline(__always) private func posixSend(_ fd: Int32, _ b: UnsafeRawPointer, _ n: Int) -> Int { write(fd, b, n) }
#else
@inline(__always) private func posixSend(_ fd: Int32, _ b: UnsafeRawPointer, _ n: Int) -> Int { send(fd, b, n, Int32(MSG_NOSIGNAL)) }
#endif

/// Low-level AF_UNIX (SOCK_STREAM) helpers. The control plane uses these directly so it has no
/// network dependency and works identically locally and over an SSH-forwarded socket.
public enum UDS {

    /// Create a listening server socket bound to `path` (dir 0700, socket user-only). Unlinks a stale
    /// socket first. Returns the listening fd.
    public static func listen(path: String, backlog: Int32 = 64) throws -> Int32 {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)   // remove a stale socket file

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OrchestraError.io("socket() failed: \(errnoString())") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        try setPath(&addr, path)

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bindRes == 0 else { posixClose(fd); throw OrchestraError.io("bind() failed: \(errnoString())") }
        chmod(path, 0o600)   // user-only

        guard posixListen(fd, backlog) == 0 else {
            posixClose(fd); throw OrchestraError.io("listen() failed: \(errnoString())")
        }
        return fd
    }

    /// Connect to a server socket at `path`. With `ioTimeout`, the connect itself runs nonblocking and waits
    /// through `poll(2)` only until its monotonic deadline; `SO_*TIMEO` then bounds peer reads and writes.
    public static func connect(path: String, ioTimeout: TimeInterval? = nil) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OrchestraError.io("socket() failed: \(errnoString())") }
        if let ioTimeout {
            do { try setIOTimeout(fd, seconds: ioTimeout) }
            catch { posixClose(fd); throw error }
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        try setPath(&addr, path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        do {
            if let ioTimeout {
                try connectUntilDeadline(fd, addr: &addr, length: len, timeout: ioTimeout)
            } else {
                let res = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { posixConnect(fd, $0, len) }
                }
                guard res == 0 else { throw OrchestraError.io("connect() failed: \(errnoString())") }
            }
        } catch {
            posixClose(fd)
            throw error
        }
        suppressSIGPIPE(fd)
        return fd
    }

    /// Bound both directions of one connected descriptor. This is deliberately descriptor-level instead
    /// of a task-race: cancellation alone cannot unblock a synchronous `read(2)` or `write(2)`.
    public static func setIOTimeout(_ fd: Int32, seconds: TimeInterval) throws {
        guard seconds > 0 else { return }
        let whole = floor(seconds)
        var timeout = timeval()
        timeout.tv_sec = numericCast(Int(whole))
        timeout.tv_usec = numericCast(max(1, Int((seconds - whole) * 1_000_000)))
        let length = socklen_t(MemoryLayout<timeval>.size)
        let receive = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, length)
        guard receive == 0 else { throw OrchestraError.io("setsockopt(SO_RCVTIMEO) failed: \(errnoString())") }
        let send = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, length)
        guard send == 0 else { throw OrchestraError.io("setsockopt(SO_SNDTIMEO) failed: \(errnoString())") }
    }

    public static func accept(_ serverFd: Int32) -> Int32 {
        let fd = posixAccept(serverFd)
        if fd >= 0 { suppressSIGPIPE(fd) }
        return fd
    }

    /// Set `SO_NOSIGPIPE` so a `write(2)` to a socket whose peer has gone away returns `EPIPE`
    /// instead of raising `SIGPIPE` — whose default disposition would terminate the daemon. This is
    /// the routine case: a client (app/CLI/agent MCP) disconnects while we're writing its response
    /// or a pushed event. Without this, `archive`-ing a card from the agent running *inside* that
    /// card's session kills the session (and its client), then the response write SIGPIPEs the
    /// daemon — which launchd then relaunches. `writeAll` already turns the `EPIPE` into a clean
    /// "connection broken" (drops the subscriber); this just stops the signal from firing first.
    private static func suppressSIGPIPE(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        // Linux has no per-socket SIGPIPE suppression; UDS.writeAll passes MSG_NOSIGNAL per send instead.
    }

    /// Write all bytes (handles partial writes / EINTR).
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var off = 0
            let total = raw.count
            while off < total {
                let n = posixSend(fd, base + off, total - off)
                if n > 0 { off += n; continue }
                if n < 0 && (errno == EINTR) { continue }
                return false
            }
            return true
        }
    }

    /// Write all bytes without allowing partial writes to restart a caller's absolute deadline. This uses
    /// nonblocking `send(2)` plus `poll(2)` rather than a task race, then restores the descriptor flags for
    /// the protocol peer that owns it.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data, deadline: DispatchTime) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            return writeUntilDeadline(fd, base: base, count: raw.count, deadline: deadline)
        }
    }

    /// Read available bytes into a buffer; returns nil on EOF/error.
    public static func read(_ fd: Int32, into buf: inout [UInt8]) -> Int? {
        let n = buf.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return posixRead(fd, base, raw.count)
        }
        if n > 0 { return n }
        if n == 0 { return nil }          // EOF
        if errno == EINTR { return 0 }    // retry
        return nil
    }

    // MARK: helpers

    /// `SO_SNDTIMEO`/`SO_RCVTIMEO` do not govern `connect(2)`. Keep the descriptor nonblocking only for
    /// the connection handshake, then restore its flags so the peer's ordinary reads and writes retain their
    /// expected blocking semantics and socket-level deadlines.
    private static func connectUntilDeadline(_ fd: Int32, addr: inout sockaddr_un, length: socklen_t,
                                             timeout: TimeInterval) throws {
        guard timeout > 0 else { throw OrchestraError.io("connect() timed out") }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { throw OrchestraError.io("fcntl(F_GETFL) failed: \(errnoString())") }
        guard posixFcntl(fd, F_SETFL, flags | Int32(O_NONBLOCK)) == 0 else {
            throw OrchestraError.io("fcntl(F_SETFL) failed: \(errnoString())")
        }
        defer { _ = posixFcntl(fd, F_SETFL, flags) }

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { posixConnect(fd, $0, length) }
        }
        if res == 0 { return }
        let initialError = errno
        guard initialError == EINPROGRESS || initialError == EALREADY || initialError == EINTR
            || initialError == EWOULDBLOCK
        else { throw OrchestraError.io("connect() failed: \(errnoString())") }

        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw OrchestraError.io("connect() timed out") }
            let remaining = deadline - now
            let milliseconds = Int32(min(
                (remaining + 999_999) / 1_000_000,
                UInt64(Int32.max)
            ))
            let ready = posixPoll(&pollFD, 1, max(1, milliseconds))
            if ready == 0 { throw OrchestraError.io("connect() timed out") }
            if ready < 0 {
                if errno == EINTR { continue }
                throw OrchestraError.io("poll() failed: \(errnoString())")
            }

            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0 else {
                throw OrchestraError.io("getsockopt(SO_ERROR) failed: \(errnoString())")
            }
            if socketError == 0 || socketError == EISCONN { return }
            if socketError == EINPROGRESS || socketError == EALREADY { continue }
            errno = socketError
            throw OrchestraError.io("connect() failed: \(errnoString())")
        }
    }

    private static func writeUntilDeadline(_ fd: Int32, base: UnsafeRawPointer, count: Int,
                                           deadline: DispatchTime) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        let changedFlags = flags & Int32(O_NONBLOCK) == 0
        if changedFlags, posixFcntl(fd, F_SETFL, flags | Int32(O_NONBLOCK)) != 0 { return false }
        defer {
            if changedFlags { _ = posixFcntl(fd, F_SETFL, flags) }
        }

        var offset = 0
        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        while offset < count {
            guard DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds else { return false }
            let written = posixSend(fd, base + offset, count - offset)
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }

            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline.uptimeNanoseconds else { return false }
                let remaining = deadline.uptimeNanoseconds - now
                let milliseconds = Int32(min(
                    (remaining + 999_999) / 1_000_000,
                    UInt64(Int32.max)
                ))
                let ready = posixPoll(&pollFD, 1, max(1, milliseconds))
                if ready > 0 { break }
                if ready == 0 { return false }
                if errno != EINTR { return false }
            }
        }
        return true
    }

    private static func setPath(_ addr: inout sockaddr_un, _ path: String) throws {
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < maxLen else { throw OrchestraError.io("socket path too long (\(bytes.count) >= \(maxLen))") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
    }

    private static func errnoString() -> String { String(cString: strerror(errno)) }
}

/// A buffered line reader over a socket fd. Splits the stream on '\n' into NDJSON frames.
public final class LineReader {
    private let fd: Int32
    private var pending = Data()
    private var buf = [UInt8](repeating: 0, count: 64 * 1024)

    public init(fd: Int32) { self.fd = fd }

    /// Block-read the next complete line (without the trailing '\n'); nil on EOF.
    public func next() -> Data? {
        while true {
            if let nl = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<nl)
                pending.removeSubrange(pending.startIndex...nl)
                return line
            }
            guard let n = UDS.read(fd, into: &buf) else {
                // EOF or read error. Every wire frame is newline-terminated, so any bytes left in
                // `pending` are an INCOMPLETE frame — drop them rather than deliver a truncated line
                // that would parse-error (or, worse, decode into a malformed request).
                return nil
            }
            if n > 0 { pending.append(contentsOf: buf[0..<n]) }
        }
    }
}
