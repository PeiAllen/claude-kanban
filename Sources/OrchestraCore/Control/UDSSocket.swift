import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Low-level AF_UNIX (SOCK_STREAM) helpers. The control plane uses these directly so it has no
/// network dependency and works identically locally and over an SSH-forwarded socket.
enum UDS {

    /// Create a listening server socket bound to `path` (dir 0700, socket user-only). Unlinks a stale
    /// socket first. Returns the listening fd.
    static func listen(path: String, backlog: Int32 = 64) throws -> Int32 {
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
        guard bindRes == 0 else { close(fd); throw OrchestraError.io("bind() failed: \(errnoString())") }
        chmod(path, 0o600)   // user-only

        guard Darwin.listen(fd, backlog) == 0 else {
            close(fd); throw OrchestraError.io("listen() failed: \(errnoString())")
        }
        return fd
    }

    /// Connect to a server socket at `path`. Returns the connected fd.
    static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OrchestraError.io("socket() failed: \(errnoString())") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        try setPath(&addr, path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        guard res == 0 else { close(fd); throw OrchestraError.io("connect() failed: \(errnoString())") }
        return fd
    }

    static func accept(_ serverFd: Int32) -> Int32 {
        Darwin.accept(serverFd, nil, nil)
    }

    /// Write all bytes (handles partial writes / EINTR).
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var off = 0
            let total = raw.count
            while off < total {
                let n = Darwin.write(fd, base + off, total - off)
                if n > 0 { off += n; continue }
                if n < 0 && (errno == EINTR) { continue }
                return false
            }
            return true
        }
    }

    /// Read available bytes into a buffer; returns nil on EOF/error.
    static func read(_ fd: Int32, into buf: inout [UInt8]) -> Int? {
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n > 0 { return n }
        if n == 0 { return nil }          // EOF
        if errno == EINTR { return 0 }    // retry
        return nil
    }

    // MARK: helpers

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
final class LineReader {
    private let fd: Int32
    private var pending = Data()
    private var buf = [UInt8](repeating: 0, count: 64 * 1024)

    init(fd: Int32) { self.fd = fd }

    /// Block-read the next complete line (without the trailing '\n'); nil on EOF.
    func next() -> Data? {
        while true {
            if let nl = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<nl)
                pending.removeSubrange(pending.startIndex...nl)
                return line
            }
            guard let n = UDS.read(fd, into: &buf) else {
                // EOF: flush any trailing partial as a final line if non-empty.
                if !pending.isEmpty { let l = pending; pending.removeAll(); return l }
                return nil
            }
            if n > 0 { pending.append(contentsOf: buf[0..<n]) }
        }
    }
}
