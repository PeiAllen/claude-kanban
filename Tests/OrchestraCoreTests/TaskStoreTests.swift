import Foundation
import Testing
@testable import OrchestraCore

@Suite("TaskStore — atomic Codable persistence")
struct TaskStoreTests {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "orch-store-\(UUID().uuidString)/tasks.json"
    }

    private func sample(_ title: String = "Fix login", column: Column = .plan) -> Task {
        Task(title: title, repo: "/repos/app", branch: "feature", cwd: "/wt/app/feature",
             model: AgentModel(id: "claude-sonnet-4-5"), startIn: .plan, column: column, order: 0, initialPrompt: title)
    }

    @Test("create fills id + timestamps + order and persists")
    func createFillsFields() async throws {
        let store = TaskStore(path: tempPath())
        let t = try await store.create(sample()).task
        #expect(t.order == 0)
        #expect(t.status == .running)
        let t2 = try await store.create(sample("Second")).task
        #expect(t2.order == 1)  // appended after the first in the same column
    }

    @Test("update merges only via the mutation and persists")
    func updateMerges() async throws {
        let store = TaskStore(path: tempPath())
        let t = try await store.create(sample()).task
        let updated = try await store.update(t.id) { $0.status = .waiting; $0.desc = "Editing Foo.swift" }.task
        #expect(updated.status == .waiting)
        #expect(updated.desc == "Editing Foo.swift")
        #expect(updated.updatedAt >= t.updatedAt)
    }

    @Test("load returns [] when the file is absent")
    func loadEmptyWhenAbsent() async throws {
        let store = TaskStore(path: tempPath())
        let tasks = await store.load()
        #expect(tasks.isEmpty)
    }

    @Test("a saved store round-trips through a fresh store on disk")
    func roundTrips() async throws {
        let path = tempPath()
        let store = TaskStore(path: path)
        let t = try await store.create(sample("Persisted")).task
        // Fresh store, same path → loads the persisted task.
        let store2 = TaskStore(path: path)
        let loaded = await store2.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == t.id)
        #expect(loaded.first?.title == "Persisted")
    }

    @Test("malformed file is moved to .bak and load yields []")
    func malformedToBak() async throws {
        let path = tempPath()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "{ not json".write(toFile: path, atomically: true, encoding: .utf8)
        let store = TaskStore(path: path)
        let tasks = await store.load()
        #expect(tasks.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path + ".bak"))
    }

    @Test("atomic save survives concurrent writers without corruption")
    func atomicConcurrent() async throws {
        let store = TaskStore(path: tempPath())
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { _ = try? await store.create(self.sample("T\(i)")) }
            }
        }
        let all = await store.all()
        #expect(all.count == 20)
    }
}

@Suite("TaskStore rev") struct TaskStoreRevTests {
    private func sample(_ title: String = "a", column: Column = .plan) -> Task {
        Task(title: title, repo: "/repos/app", branch: "b", cwd: "/wt/app/b",
             model: AgentModel(id: "claude-sonnet-4-5"), startIn: .plan, column: column, order: 0,
             initialPrompt: title)
    }
    private func tmpPath() -> String { NSTemporaryDirectory() + "orch-rev-\(UUID().uuidString)/tasks.json" }

    @Test("every mutation bumps rev monotonically; no two mutations share a rev")
    func test_everyMutationBumpsRev() async throws {
        let store = TaskStore(path: tmpPath())
        var seen: [Int] = []
        let t = try await store.create(sample()).task
        seen.append(await store.currentRev)
        _ = try await store.update(t.id) { $0.desc = "b" }
        seen.append(await store.currentRev)
        _ = try await store.move(t.id, to: .impl)
        seen.append(await store.currentRev)
        try await store.remove(t.id)
        seen.append(await store.currentRev)
        #expect(seen == seen.sorted())            // strictly increasing (monotonic)
        #expect(Set(seen).count == seen.count)    // unique — no two mutations share a rev
        #expect(seen.first! >= 1)
    }

    @Test("a no-op update does not bump rev")
    func test_noOpUpdateDoesNotBumpRev() async throws {
        let store = TaskStore(path: tmpPath())
        let t = try await store.create(sample()).task
        let revAfterCreate = await store.currentRev

        // No-op closure: leaves the task byte-for-byte identical.
        let (unchanged, revAfterNoOp) = try await store.update(t.id) { _ in }
        #expect(revAfterNoOp == revAfterCreate)
        #expect(await store.currentRev == revAfterCreate)
        #expect(unchanged == t)

        // Setting a field to its current value is also a no-op.
        let (stillUnchanged, revAfterNoOp2) = try await store.update(t.id) { $0.desc = t.desc }
        #expect(revAfterNoOp2 == revAfterCreate)
        #expect(await store.currentRev == revAfterCreate)
        #expect(stillUnchanged == t)

        // A real change still bumps rev.
        let (changed, revAfterRealChange) = try await store.update(t.id) { $0.desc = "actually different" }
        #expect(revAfterRealChange == revAfterCreate + 1)
        #expect(await store.currentRev == revAfterCreate + 1)
        #expect(changed.desc == "actually different")
    }

    @Test("a pre-upgrade bare-array tasks.json reads back rev = 0")
    func test_preUpgradeBareArrayDefaultsRevZero() async throws {
        let path = tmpPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let legacy = try OrchestraJSON.pretty.encode([sample("old")])   // legacy = top-level array, no {rev,tasks}
        try legacy.write(to: URL(fileURLWithPath: path))
        let store = TaskStore(path: path)
        let loaded = await store.load()
        #expect(loaded.count == 1)
        #expect(await store.currentRev == 0)
    }
}
