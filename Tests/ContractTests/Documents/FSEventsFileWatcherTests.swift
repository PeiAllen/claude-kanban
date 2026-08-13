import Foundation
import Testing
@testable import OrchestraCore
import TestSupport

/// The REAL FSEvents watcher against a real filesystem. This tier exists because the OS event stream is
/// irreducible — the same split `Launcher`'s real-git calls already use: the primitive is pinned here,
/// and the logic layered on top (`DocumentWatchService`) is unit-tested against a fake.
///
/// These tests also cover a memory-safety contract that no unit test can reach. Without
/// `kFSEventStreamCreateFlagUseCFTypes`, the SDK hands the callback a raw `char **` (FSEvents.h:215-219)
/// and bridging it as an NSArray dereferences invalid memory. If the flag and the bridge ever drift
/// apart, the first event crashes here rather than in the app.
@Suite struct FSEventsFileWatcherTests {

    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "orch-fsw-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a write to a watched tree is reported")
    func firesForAWriteToAWatchedDirectory() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let seen = Locked<Set<String>>([])
        let token = FSEventsFileWatcher(latency: 0.05)
            .watch(directory: dir) { ev in seen.withLock { $0.formUnion(ev.paths) } }
        defer { token.cancel() }

        try "hello".write(toFile: dir + "/note.md", atomically: true, encoding: .utf8)
        try await pollUntil("the write is reported") {
            seen.withLock { $0.contains { $0.hasSuffix("note.md") } }
        }
    }

    @Test("cancel stops delivery")
    func stopsFiringAfterCancel() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let count = Locked(0)
        let token = FSEventsFileWatcher(latency: 0.05)
            .watch(directory: dir) { _ in count.withLock { $0 += 1 } }
        try "a".write(toFile: dir + "/a.md", atomically: true, encoding: .utf8)
        try await pollUntil("the first write lands") { count.withLock { $0 } > 0 }

        token.cancel()
        let after = count.withLock { $0 }
        try "b".write(toFile: dir + "/b.md", atomically: true, encoding: .utf8)
        // A deliberate settle window: proving "no FURTHER callback arrives" needs real time, which is
        // legitimate in ContractTests — `lint-tests.sh` rule 1 scans only the unit tier.
        // `_Concurrency.Task` because a bare `Task` resolves to OrchestraKit's card model.
        try await _Concurrency.Task.sleep(for: .milliseconds(400))
        #expect(count.withLock { $0 } == after)
    }
}
