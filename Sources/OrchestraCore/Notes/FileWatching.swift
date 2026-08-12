import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// A cancellable registration returned by `FileWatching.watch`.
public protocol FileWatchToken: Sendable { func cancel() }

/// One coalesced batch from the OS.
///
/// `needsRescan` carries FSEvents' OVERFLOW flags (`MustScanSubDirs`, `UserDropped`, `KernelDropped`).
/// When the kernel or the framework drops events, the reported paths are incomplete — the batch may
/// even name only `/`. A consumer that exact-matches paths would then miss the edit permanently and
/// leave the reader stale forever, with no error and no failing test. On `needsRescan` the consumer
/// must re-check everything it owns instead of trusting `paths`.
public struct FileWatchEvent: Sendable {
    public let paths: Set<String>
    public let needsRescan: Bool
    public init(paths: Set<String>, needsRescan: Bool) {
        self.paths = paths; self.needsRescan = needsRescan
    }
}

/// The injectable filesystem-watch seam.
///
/// The logic layered on top is unit-tested against a FAKE conformer; the real event stream is
/// irreducible OS behavior and is pinned in ContractTests — the same split `Launcher`'s real-git calls
/// already use.
public protocol FileWatching: Sendable {
    /// Watch `directory` and everything under it. `onChange` receives the ABSOLUTE paths the OS
    /// reported, already coalesced by the implementation's latency window, plus the overflow signal.
    func watch(directory: String,
               onChange: @escaping @Sendable (FileWatchEvent) -> Void) -> FileWatchToken
}

/// A watcher that never fires. The Linux daemon has no FSEvents, so live note refresh degrades to
/// manual there; every other note surface keeps working.
public struct NoopFileWatcher: FileWatching {
    public init() {}
    private struct Token: FileWatchToken { func cancel() {} }
    public func watch(directory: String,
                      onChange: @escaping @Sendable (FileWatchEvent) -> Void) -> FileWatchToken {
        Token()
    }
}

#if canImport(CoreServices)
/// FSEvents-backed watcher.
///
/// Watches a DIRECTORY TREE, never a file descriptor: an atomic write-then-rename save (what agents and
/// editors do) replaces the inode, so a vnode watch would go silent after the first save. One stream
/// therefore covers a whole worktree.
///
/// The stream's own `latency` does the coalescing, so an agent's write burst arrives as ONE callback and
/// no second debounce is needed anywhere above this.
public struct FSEventsFileWatcher: FileWatching {
    private let latency: TimeInterval
    public init(latency: TimeInterval = 0.3) { self.latency = latency }

    /// Boxes the callback so it can cross the C function-pointer boundary via the stream's `info`.
    final class Box {
        let cb: @Sendable (FileWatchEvent) -> Void
        init(_ cb: @escaping @Sendable (FileWatchEvent) -> Void) { self.cb = cb }
    }

    private final class Token: FileWatchToken, @unchecked Sendable {
        private let lock = NSLock()
        private var stream: FSEventStreamRef?
        private var box: Unmanaged<Box>?

        init(stream: FSEventStreamRef, box: Unmanaged<Box>) { self.stream = stream; self.box = box }

        func cancel() {
            // Take both out under the lock so a double cancel (or a cancel racing deinit) stops,
            // invalidates, and releases exactly once.
            let (s, b): (FSEventStreamRef?, Unmanaged<Box>?) = lock.withLock {
                let s = stream, b = box; stream = nil; box = nil; return (s, b)
            }
            guard let s else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            b?.release()
        }

        deinit { cancel() }
    }

    public func watch(directory: String,
                      onChange: @escaping @Sendable (FileWatchEvent) -> Void) -> FileWatchToken {
        let box = Unmanaged.passRetained(Box(onChange))
        var ctx = FSEventStreamContext(version: 0, info: box.toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            // `eventPaths` is a CFArrayRef of CFStringRef ONLY because the stream below is created with
            // `kFSEventStreamCreateFlagUseCFTypes`. WITHOUT that flag the SDK hands back a raw
            // `char **` (FSEvents.h:215-219), and bridging it as an NSArray dereferences invalid
            // memory on the very first event. The flag and this bridge are a matched pair: change
            // both or neither.
            let arr = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            let overflow = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
                         | UInt32(kFSEventStreamEventFlagUserDropped)
                         | UInt32(kFSEventStreamEventFlagKernelDropped)
            var out = Set<String>()
            var rescan = false
            for i in 0..<count {
                if let p = arr[i] as? String { out.insert(p) }
                if flags[i] & overflow != 0 { rescan = true }
            }
            guard !out.isEmpty || rescan else { return }
            box.cb(FileWatchEvent(paths: out, needsRescan: rescan))
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx, [directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                                     | kFSEventStreamCreateFlagFileEvents
                                     | kFSEventStreamCreateFlagNoDefer)) else {
            box.release()
            return NoopFileWatcher().watch(directory: directory, onChange: onChange)
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        return Token(stream: stream, box: box)
    }
}
#endif
