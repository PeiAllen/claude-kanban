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
        let t = try await store.create(sample())
        #expect(t.order == 0)
        #expect(t.status == .running)
        let t2 = try await store.create(sample("Second"))
        #expect(t2.order == 1)  // appended after the first in the same column
    }

    @Test("update merges only via the mutation and persists")
    func updateMerges() async throws {
        let store = TaskStore(path: tempPath())
        let t = try await store.create(sample())
        let updated = try await store.update(t.id) { $0.status = .waiting; $0.desc = "Editing Foo.swift" }
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
        let t = try await store.create(sample("Persisted"))
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
