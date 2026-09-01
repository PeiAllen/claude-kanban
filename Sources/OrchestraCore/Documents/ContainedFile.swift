import Foundation

/// Reads a file by OPENING IT ONCE and proving everything from the open descriptor.
///
/// The rule this type exists to enforce: **validate the object, never the name.** Checking a pathname
/// with `realpath` and then re-opening that same pathname with `FileManager.contents(atPath:)` is a
/// TOCTOU. Between the two calls the name can be replaced by a symlink pointing at any file the daemon
/// can read, and the second open follows it — so a containment check on the name proves nothing about
/// the bytes that come back. A descriptor cannot be swapped underneath its holder, so every check here
/// is made against the fd and the bytes are read from that same fd.
///
/// Three failure modes are closed together because one open answers all of them:
///
///  - **Escape.** `F_GETPATH` names the file the descriptor actually refers to, with symlinks already
///    followed and `..` already collapsed. That path is what the containment test uses.
///  - **Blocking.** A FIFO named `stall.md` makes a plain `open` wait forever for a writer, which would
///    park the caller — and, for the watch actor, every other workspace behind it. `O_NONBLOCK` makes
///    the open return, and the regular-file test then rejects it.
///  - **Size.** `contents(atPath:)` loads the whole file before anyone can apply a cap, so a
///    multi-gigabyte document exhausts the daemon before it is refused. `fstat` gives the true size
///    before a single byte is read.
enum ContainedFile {

    /// Open `path`, prove it is a regular file whose real location is inside `root`, and return at most
    /// `limit` bytes together with the file's TRUE size (so a caller can tell a truncated read from a
    /// complete one).
    ///
    /// - Parameters:
    ///   - root: the containing directory, already canonical.
    ///   - limit: read no more than this many bytes. A longer file is truncated, not refused.
    ///   - maxSize: when set, a file bigger than this is refused outright before it is read. Documents
    ///     truncate (a long document is still worth reading); an oversized image is an error.
    static func read(_ path: String, containedIn root: String,
                     limit: Int, maxSize: Int? = nil) throws -> (data: Data, size: Int) {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw OrchestraError.io("cannot open \(path)") }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { throw OrchestraError.io("cannot stat \(path)") }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw OrchestraError.invalidParams("\(path) is not a regular file")
        }

        // CONTAINMENT, on the descriptor. `realpath(path)` would describe whatever the name points at
        // right now, which is not necessarily what is open.
        let real = try realPath(of: fd, fallback: path)
        let rootSlash = root.hasSuffix("/") ? root : root + "/"
        guard real.hasPrefix(rootSlash) else { throw OrchestraError.pathNotAllowed(path) }

        let size = Int(st.st_size)
        if let maxSize, size > maxSize {
            throw OrchestraError.invalidParams("\(path) is \(size) bytes; the cap is \(maxSize)")
        }

        var data = Data()
        let want = min(size, limit)
        if want > 0 {
            data.reserveCapacity(want)
            let chunk = min(want, 64 * 1024)
            var buf = [UInt8](repeating: 0, count: chunk)
            while data.count < want {
                let ask = min(chunk, want - data.count)
                // Fully qualified: inside this type, a bare `read` binds to the static method above.
                let n = buf.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress, ask) }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw OrchestraError.io("cannot read \(path)")
                }
                if n == 0 { break }                     // the file shrank under us; short is fine
                data.append(contentsOf: buf[0..<n])
            }
        }
        return (data, size)
    }

    /// The path a descriptor actually refers to. Darwin answers directly; elsewhere `/proc` does.
    private static func realPath(of fd: Int32, fallback: String) throws -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        #if canImport(Darwin)
        guard fcntl(fd, F_GETPATH, &buf) != -1 else {
            throw OrchestraError.io("cannot resolve \(fallback)")
        }
        return decode(buf)
        #else
        let n = buf.withUnsafeMutableBufferPointer { readlink("/proc/self/fd/\(fd)", $0.baseAddress!, $0.count - 1) }
        guard n > 0 else { throw OrchestraError.io("cannot resolve \(fallback)") }
        return decode(buf)
        #endif
    }

    private static func decode(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
