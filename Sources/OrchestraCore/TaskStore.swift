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
    /// Set true (once, at load) when the on-disk `tasks.json` was top-level-UNPARSEABLE and had to be
    /// side-lined to a timestamped `.corrupt-<ISO8601>` backup, booting the board empty. The daemon reads
    /// this at boot to enter conservative worktree mode (carry #3) — a corrupt board can't prove ownership
    /// of any pre-existing tree, so no reclaim may run until a later clean restart re-establishes the map.
    public private(set) var loadWasCorrupt = false

    /// Test-visible count of ACTUAL `tasks.json` disk writes (bumped in `writeToDisk`). Debounced
    /// telemetry mutations bump `currentRev` synchronously but coalesce into ONE write, so this lags
    /// `currentRev` while a telemetry burst is pending.
    var diskWriteCount = 0

    // MARK: Persist debounce (telemetry-origin writes) — bug #13
    // Telemetry (`report()` field deltas) bumps `rev` + updates memory + emits SYNCHRONOUSLY; only the
    // `tasks.json` FILE WRITE is coalesced through this debounce, so the wire/event stream is byte-identical.
    /// The scheduled coalesce timer (nil when no write is pending or an immediate write superseded it).
    private var persistDebounce: _Concurrency.Task<Void, Never>? = nil
    /// True while a debounced write is owed (memory is ahead of disk).
    private var pendingDirty = false
    /// Quiet-period after which a coalesced burst is flushed (test-tunable).
    private var debounceInterval: Duration = .milliseconds(500)
    /// Hard cap: an always-active card is checkpointed at least this often since its first deferred write.
    private var maxDeferral: Duration = .seconds(2)
    /// The hard-cap sleeper, armed at the burst's FIRST deferred write and racing the debounce
    /// timer: whichever fires first flushes and cancels the other. Both sleep on the injected
    /// clock — one timeline, so a TestClock advance exercises debounce AND cap deterministically.
    private var persistCap: _Concurrency.Task<Void, Never>? = nil

    /// Test seam: tune the debounce quiet-period.
    func setPersistDebounce(_ d: Duration) { debounceInterval = d }
    /// Test seam: tune the max-deferral checkpoint.
    func setMaxDeferral(_ d: Duration) { maxDeferral = d }

    /// Scheduling runs on `clock` (production: ContinuousClock — monotonic, wall-clock-jump-proof);
    /// `now()` stamps PERSISTED timestamps only (updatedAt, corrupt-backup names), never scheduling.
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date

    public init(path: String = Config.tasksPath,
                clock: any Clock<Duration> = ContinuousClock(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.path = path
        self.clock = clock
        self.now = now
    }

    /// On-disk payload shape (post-upgrade). Pre-upgrade files are a bare `[Task]` array.
    /// Decoded ELEMENT-WISE via `FailableTask` so one throwing record (only an id-less one now) drops just
    /// itself, never the whole board.
    private struct StoredBoard: Decodable { let rev: Int; let tasks: [FailableTask] }

    /// The on-disk envelope we WRITE — same `{rev, tasks}` shape, encoding real `[Task]`.
    private struct BoardEnvelope: Encodable { let rev: Int; let tasks: [Task] }

    /// A single record wrapper whose decode NEVER throws: a record that fails `Task.init(from:)` — which,
    /// after the tolerant-field fix, happens ONLY when `id` is absent — becomes `nil` and is dropped,
    /// instead of failing the array decode and stranding the entire board to `.bak`.
    private struct FailableTask: Decodable {
        let task: Task?
        init(from decoder: Decoder) throws { self.task = try? Task(from: decoder) }
    }

    /// Read + decode. `[]` if absent. The board reaches `.bak` ONLY when the top-level JSON is itself
    /// unparseable — a single corrupt record is dropped element-wise, never `.bak`'d. An id-less record
    /// (the sole unrecoverable case) is logged and dropped; every other record is kept (fields defaulted).
    @discardableResult
    public func load() -> [Task] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            tasks = []; currentRev = 0; loaded = true; return tasks
        }
        do {
            let data = try Data(contentsOf: url)
            if let board = try? OrchestraJSON.decoder.decode(StoredBoard.self, from: data) {
                tasks = Self.compact(board.tasks); currentRev = board.rev   // post-upgrade envelope
            } else {
                tasks = Self.compact(try OrchestraJSON.decoder.decode([FailableTask].self, from: data))
                currentRev = 0                                              // pre-upgrade bare array → rev 0
            }
        } catch {
            // Top-level unparseable: side-line to a TIMESTAMPED backup so a second corruption never
            // clobbers the first (`.corrupt-<ISO8601>`), then boot empty and raise `loadWasCorrupt` so the
            // daemon enters conservative worktree mode (carry #3). Never `removeItem` the prior corrupt file.
            let stamp = Self.corruptStamp(now())
            let backup = path + ".corrupt-\(stamp)"
            try? FileManager.default.moveItem(atPath: path, toPath: backup)
            FileHandle.standardError.write(Data(
                "TaskStore.load: tasks.json is corrupt (top-level unparseable) — moved to \(backup); booting empty in conservative mode\n".utf8))
            tasks = []; currentRev = 0; loadWasCorrupt = true
        }
        loaded = true
        return tasks
    }

    /// A filesystem-safe ISO8601 timestamp for the corrupt-backup suffix (`:` replaced so the name is
    /// portable). Collision-resistant enough that two corruptions in the same second still don't clobber —
    /// each rename targets a fresh name and `moveItem` refuses to overwrite an existing file.
    static func corruptStamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    /// Keep the recoverable records; log-and-drop the id-less ones (the only records `FailableTask` yields
    /// `nil` for). Record-level corruption never `.bak`'s the board — the fail-safe binding contract.
    private static func compact(_ records: [FailableTask]) -> [Task] {
        let dropped = records.filter { $0.task == nil }.count
        if dropped > 0 {
            FileHandle.standardError.write(
                Data("TaskStore.load: dropped \(dropped) id-less record(s) (unrecoverable); board preserved\n".utf8))
        }
        return records.compactMap(\.task)
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

    /// Whether the on-disk board was corrupt at load (top-level unparseable → side-lined + booted empty).
    /// Forces a load so a boot caller reads the real signal even before the first `all()`.
    public func wasCorrupt() -> Bool {
        ensureLoaded()
        return loadWasCorrupt
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

    /// Immediate persist: bump `currentRev`, cancel any pending debounced write (memory already holds the
    /// pending telemetry deltas, so this write absorbs them — this is what BOUNDS the cross-restart rev
    /// regression), and write to disk now.
    private func persist() throws {
        currentRev += 1                                                // single bump funnel
        cancelPendingFlush()                                           // an immediate write supersedes + absorbs pending telemetry
        try writeToDisk()
    }

    /// The actual `tasks.json` write: `createDirectory` + encode + atomic replace. Bumps `diskWriteCount`.
    /// Callers own the `currentRev` bump and the debounce bookkeeping — this only touches the file.
    private func writeToDisk() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try OrchestraJSON.pretty.encode(BoardEnvelope(rev: currentRev, tasks: tasks))
        let url = URL(fileURLWithPath: path)
        let tmp = URL(fileURLWithPath: path + ".tmp.\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        diskWriteCount += 1
    }

    /// Telemetry-origin persist: bump `currentRev` + mark the file dirty SYNCHRONOUSLY (memory/rev/emit are
    /// unchanged — the wire is byte-identical), but COALESCE the `tasks.json` write. Flushes immediately at
    /// the `maxDeferral` checkpoint (bounding an always-active card's on-disk lag); otherwise (re)schedules a
    /// debounce timer that flushes after `debounceInterval` of quiet.
    private func persistDebounced() {
        currentRev += 1
        pendingDirty = true
        if persistCap == nil {                                   // burst's first deferral arms the cap
            persistCap = _Concurrency.Task { [maxDeferral, clock] in
                try? await clock.sleep(for: maxDeferral)
                guard !_Concurrency.Task.isCancelled else { return }
                await self.flushPendingWrites()                  // max-deferral checkpoint
            }
        }
        persistDebounce?.cancel()
        persistDebounce = _Concurrency.Task { [debounceInterval, clock] in
            try? await clock.sleep(for: debounceInterval)
            guard !_Concurrency.Task.isCancelled else { return }
            await self.flushPendingWrites()
        }
    }

    /// Flush any coalesced telemetry write NOW (debounce fire, max-deferral checkpoint, SIGTERM/shutdown,
    /// or explicit test call). A write failure RE-ARMS the dirty bit + logs to stderr (never a silent drop)
    /// so a later mutation retries.
    public func flushPendingWrites() {
        persistDebounce?.cancel(); persistDebounce = nil
        persistCap?.cancel(); persistCap = nil
        guard pendingDirty else { return }
        pendingDirty = false
        do {
            try writeToDisk()
        } catch {
            pendingDirty = true                                        // re-arm: a later mutation retries the write
            FileHandle.standardError.write(Data(
                "TaskStore.flushPendingWrites: tasks.json write failed (\(error)); keeping dirty bit for retry\n".utf8))
        }
    }

    /// Drop a pending debounced write WITHOUT writing — an immediate `persist()` is about to `writeToDisk()`
    /// and memory already includes the deferred deltas, so its write absorbs them.
    private func cancelPendingFlush() {
        persistDebounce?.cancel(); persistDebounce = nil
        persistCap?.cancel(); persistCap = nil
        pendingDirty = false
    }

    /// Insert a new task at the end of its column's order. Fills order; persists. Returns the created
    /// task ALONGSIDE the rev `persist()` just bumped to, atomically (no `await` in between) — so a
    /// caller can bind an event's `rev` to exactly this mutation (see the rev-binding design decision).
    @discardableResult
    public func create(_ task: Task) throws -> (task: Task, rev: Int) {
        ensureLoaded()
        var t = task
        t.order = nextOrder(in: t.column)
        t.updatedAt = now()
        tasks.append(t)
        try persist()                     // bumps currentRev
        return (t, currentRev)
    }

    /// Atomic get-or-create keyed on `task.id`: returns the existing card (created:false) if the id is
    /// already present, else appends it (created:true). No `await` between the presence check and the
    /// append (the actor owns `tasks`, so get+append is atomic) — this is THE idempotency boundary: a
    /// check-then-act across the service actor is NOT atomic because every `await` re-enters, so two
    /// concurrent same-id spawns could both pass a bare `get`-then-`create`. Here they cannot both append.
    @discardableResult
    public func createIfAbsent(_ task: Task) throws -> (task: Task, rev: Int, created: Bool) {
        ensureLoaded()
        if let existing = tasks.first(where: { $0.id == task.id }) { return (existing, currentRev, false) }
        var t = task
        t.order = nextOrder(in: t.column)
        t.updatedAt = now()
        tasks.append(t)
        try persist()                     // bumps currentRev
        return (t, currentRev, true)
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
    ///
    /// `debounceFlush: true` (telemetry-origin) keeps the `rev` bump + memory update SYNCHRONOUS but
    /// COALESCES the `tasks.json` write through the persist debounce; the returned `rev` is still fresh and
    /// monotonic. A no-op mutation neither bumps `rev` nor schedules a flush.
    @discardableResult
    public func update(_ id: UUID, debounceFlush: Bool = false, _ mutate: (inout Task) -> Void) throws -> (task: Task, rev: Int) {
        ensureLoaded()
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else {
            throw OrchestraError.unknownTask(id.uuidString)
        }
        let before = tasks[idx]
        mutate(&tasks[idx])
        guard tasks[idx] != before else { return (tasks[idx], currentRev) }  // no-op: no persist, no rev bump, no flush
        tasks[idx].updatedAt = now()
        if debounceFlush { persistDebounced() } else { try persist() }
        return (tasks[idx], currentRev)
    }

    public func remove(_ id: UUID) throws {
        ensureLoaded()
        tasks.removeAll { $0.id == id }
        try persist()
    }
}
