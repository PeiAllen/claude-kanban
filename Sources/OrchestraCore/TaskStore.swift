import Foundation

/// Serializes all reads/writes of `tasks.json`. Codable; atomic save (write temp + replaceItem).
/// Malformed file on load → moved to `.bak`, start `[]`.
public actor TaskStore {
    private let path: String
    private var tasks: [Task] = []
    private var loaded = false
    /// Monotonic board version, bumped in `persist()` and persisted in the `{rev, tasks}` payload.
    /// A pre-upgrade bare-array `tasks.json` loads as `rev = 0` (the one on-disk compat we keep).
    public private(set) var currentRev: Int = 0

    public init(path: String = Config.tasksPath) {
        self.path = path
    }

    /// On-disk payload shape (post-upgrade). Pre-upgrade files are a bare `[Task]` array.
    private struct StoredBoard: Codable { let rev: Int; let tasks: [Task] }

    /// Read + decode. `[]` if absent; malformed → `.bak` + `[]`.
    @discardableResult
    public func load() -> [Task] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            tasks = []; currentRev = 0; loaded = true; return tasks
        }
        do {
            let data = try Data(contentsOf: url)
            if let board = try? OrchestraJSON.decoder.decode(StoredBoard.self, from: data) {
                tasks = board.tasks; currentRev = board.rev            // post-upgrade
            } else {
                tasks = try OrchestraJSON.decoder.decode([Task].self, from: data)
                currentRev = 0                                          // pre-upgrade migration read
            }
        } catch {
            let bak = path + ".bak"
            try? FileManager.default.removeItem(atPath: bak)
            try? FileManager.default.moveItem(atPath: path, toPath: bak)
            tasks = []; currentRev = 0
        }
        loaded = true
        return tasks
    }

    /// Synchronous, actor-independent peek of the persisted `rev` — used by `OrchestraService.init`
    /// to seed its `lastRev` mirror BEFORE the control server accepts RPCs (no `await`, so it can run
    /// in the sync init). `nonisolated` is legal: it reads only the immutable `let path` and the file.
    /// Same decode order as `load`; defaults 0 for absent/bare-array/malformed.
    public nonisolated func peekPersistedRev() -> Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let board = try? OrchestraJSON.decoder.decode(StoredBoard.self, from: data)
        else { return 0 }
        return board.rev
    }

    private func ensureLoaded() {
        if !loaded { _ = load() }
    }

    public func all() -> [Task] {
        ensureLoaded()
        return tasks
    }

    public func get(_ id: UUID) -> Task? {
        ensureLoaded()
        return tasks.first { $0.id == id }
    }

    /// Atomic save: write to a temp file then `replaceItemAt`.
    public func save(_ newTasks: [Task]) throws {
        tasks = newTasks
        loaded = true
        try persist()
    }

    private func persist() throws {
        currentRev += 1                                                // single bump funnel
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try OrchestraJSON.pretty.encode(StoredBoard(rev: currentRev, tasks: tasks))
        let url = URL(fileURLWithPath: path)
        let tmp = URL(fileURLWithPath: path + ".tmp.\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    /// Insert a new task at the end of its column's order. Fills order; persists. Returns the created
    /// task ALONGSIDE the rev `persist()` just bumped to, atomically (no `await` in between) — so a
    /// caller can bind an event's `rev` to exactly this mutation (see the rev-binding design decision).
    @discardableResult
    public func create(_ task: Task) throws -> (task: Task, rev: Int) {
        ensureLoaded()
        var t = task
        t.order = nextOrder(in: t.column)
        t.updatedAt = Date()
        tasks.append(t)
        try persist()                     // bumps currentRev
        return (t, currentRev)
    }

    /// Next free order slot at the end of a column (excluding `ignoring`, e.g. the card being moved).
    public func nextOrder(in column: Column, ignoring: UUID? = nil) -> Int {
        ensureLoaded()
        let maxOrder = tasks
            .filter { $0.column == column && !$0.archived && $0.id != ignoring }
            .map(\.order).max() ?? -1
        return maxOrder + 1
    }

    /// Move a card to a column, appending it at the end of that column's order. One place owns the
    /// ordering invariant.
    @discardableResult
    public func move(_ id: UUID, to column: Column) throws -> (task: Task, rev: Int) {
        let order = nextOrder(in: column, ignoring: id)
        return try update(id) { $0.column = column; $0.order = order }   // inherits (task, rev)
    }

    /// Apply a mutation to the task with `id`, persist, and return the updated task ALONGSIDE the rev
    /// `persist()` just bumped to (see `create`).
    @discardableResult
    public func update(_ id: UUID, _ mutate: (inout Task) -> Void) throws -> (task: Task, rev: Int) {
        ensureLoaded()
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else {
            throw OrchestraError.unknownTask(id.uuidString)
        }
        let before = tasks[idx]
        mutate(&tasks[idx])
        guard tasks[idx] != before else { return (tasks[idx], currentRev) }  // no-op: no persist, no rev bump
        tasks[idx].updatedAt = Date()
        try persist()
        return (tasks[idx], currentRev)
    }

    public func remove(_ id: UUID) throws {
        ensureLoaded()
        tasks.removeAll { $0.id == id }
        try persist()
    }
}
