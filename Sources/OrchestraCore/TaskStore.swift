import Foundation

/// Serializes all reads/writes of `tasks.json`. Codable; atomic save (write temp + replaceItem).
/// Malformed file on load → moved to `.bak`, start `[]`.
public actor TaskStore {
    private let path: String
    private var tasks: [Task] = []
    private var loaded = false

    public init(path: String = Config.tasksPath) {
        self.path = path
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Read + decode. `[]` if absent; malformed → `.bak` + `[]`.
    @discardableResult
    public func load() -> [Task] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            tasks = []; loaded = true; return tasks
        }
        do {
            let data = try Data(contentsOf: url)
            tasks = try Self.decoder.decode([Task].self, from: data)
        } catch {
            let bak = path + ".bak"
            try? FileManager.default.removeItem(atPath: bak)
            try? FileManager.default.moveItem(atPath: path, toPath: bak)
            tasks = []
        }
        loaded = true
        return tasks
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
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(tasks)
        let url = URL(fileURLWithPath: path)
        let tmp = URL(fileURLWithPath: path + ".tmp.\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    /// Insert a new task at the end of its column's order. Fills order; persists.
    @discardableResult
    public func create(_ task: Task) throws -> Task {
        ensureLoaded()
        var t = task
        t.order = nextOrder(in: t.column)
        t.updatedAt = Date()
        tasks.append(t)
        try persist()
        return t
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
    public func move(_ id: UUID, to column: Column) throws -> Task {
        let order = nextOrder(in: column, ignoring: id)
        return try update(id) { $0.column = column; $0.order = order }
    }

    /// Apply a mutation to the task with `id`, persist, and return the updated task.
    @discardableResult
    public func update(_ id: UUID, _ mutate: (inout Task) -> Void) throws -> Task {
        ensureLoaded()
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else {
            throw OrchestraError.unknownTask(id.uuidString)
        }
        mutate(&tasks[idx])
        tasks[idx].updatedAt = Date()
        try persist()
        return tasks[idx]
    }

    public func remove(_ id: UUID) throws {
        ensureLoaded()
        tasks.removeAll { $0.id == id }
        try persist()
    }
}
