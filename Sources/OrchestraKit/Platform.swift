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
