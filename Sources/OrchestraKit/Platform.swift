// Platform POSIX shims. macOS imports Darwin; Linux imports Glibc (glibc) or Musl (the static SDK).
// Defined at file scope, where no enclosing type shadows the C `close`, so a single `closeFD` works on
// every platform and every call site — no `Darwin.`/`Glibc.` qualification, no shadowing by a type's
// own `close()` method.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@inline(__always) public func closeFD(_ fd: Int32) { _ = close(fd) }

/// Half-close BOTH directions of a socket to WAKE any thread parked in a blocking `read(2)`/`write(2)`
/// on it — without releasing the fd. On Linux `close(2)` does NOT unblock a thread already blocked in
/// `read(2)`, so a bare close leaks the reader thread; `shutdown(SHUT_RDWR)` makes the blocked read
/// return EOF. The fd number stays reserved, so the *reader* can own the actual `closeFD` — preventing a
/// closed-and-recycled fd from being read by a zombie reader (cross-wiring a new connection's bytes).
@inline(__always) public func shutdownFD(_ fd: Int32) { _ = shutdown(fd, Int32(SHUT_RDWR)) }
