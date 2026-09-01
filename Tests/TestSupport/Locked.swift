import Foundation

/// A lock-guarded box for a value a test observes across threads — an OS callback, a detached Task, a
/// dispatch queue. `@unchecked Sendable` is carried by the lock, which guards every access.
///
/// The tree already had `LockedBool`, private to one ContractTests file. This is the generic form, in
/// TestSupport so both tiers share one implementation.
public final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    public init(_ initial: T) { value = initial }

    @discardableResult
    public func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
