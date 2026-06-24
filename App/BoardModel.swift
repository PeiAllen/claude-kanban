import SwiftUI
import OrchestraCore

struct Toast: Identifiable {
    let id = UUID()
    let title: String
    let sub: String?
    var color: ToastColor = .green
    enum ToastColor { case green, blue, red }
}

/// The app's single source of view state. Subscribes to the daemon's event stream and drives all
/// SwiftUI views; every mutation is a thin call to the daemon (no business logic here).
@MainActor
final class BoardModel: ObservableObject {
    @Published var tasks: [Task] = []
    @Published var archived: [Task] = []
    @Published var activity: [ActivityItem] = []
    @Published var selectedId: UUID?
    @Published var config = Config()
    @Published var models: [String] = []
    @Published var connected = false
    @Published var toasts: [Toast] = []

    // Sheet / popover UI state.
    @Published var showSpawn = false
    @Published var showDone = false
    @Published var showActivity = false
    @Published var spawnDefaultColumn: Column = .impl

    // Per-card shell state (keyed by task id so it survives selecting away and back).
    @Published var shellOpen: Set<UUID> = []
    @Published var shellWindows: [UUID: [String]] = [:]
    @Published var selectedShell: [UUID: String] = [:]

    // Preferences (host props in the prototype).
    @AppStorage("orch_accent") var accentRaw = Accent.blue.rawValue
    @AppStorage("orch_density") var densityRaw = Density.comfortable.rawValue
    @AppStorage("orch_dark") var darkMode = false

    var accent: Accent { Accent(rawValue: accentRaw) ?? .blue }
    var density: Density { Density(rawValue: densityRaw) ?? .comfortable }

    let client: ControlClient

    init(socketPath: String = Config.socketPath) {
        client = ControlClient(socketPath: socketPath, source: .app)
    }

    var selected: Task? { tasks.first { $0.id == selectedId } ?? archived.first { $0.id == selectedId } }

    func cards(in column: Column) -> [Task] {
        tasks.filter { $0.column == column && !$0.archived }.sorted { $0.order < $1.order }
    }

    /// distinct agents with running/waiting cards (for the MCP chip count).
    var activeAgentCount: Int {
        Set(tasks.filter { $0.status == .running || $0.status == .waiting }.map(\.agentId)).count
    }

    // MARK: lifecycle

    func start() async {
        // Retry briefly — the daemon may still be binding its socket right after launch.
        for _ in 0..<15 {
            do { try client.connect(); connected = true; break }
            catch { connected = false; try? await _Concurrency.Task.sleep(for: .milliseconds(200)) }
        }
        await refresh()
        // live event stream
        let stream = client.subscribe()
        _Concurrency.Task { [weak self] in
            for await event in stream { await self?.apply(event) }
        }
    }

    func refresh() async {
        if let list = try? await client.call("list", .object([:])).decode([Task].self) { tasks = list }
        if let arch = try? await client.call("archivedList").decode([Task].self) { archived = arch }
        if let cfg = try? await client.call("getConfig").decode(Config.self) { config = cfg }
        if let ms = try? await client.call("models").decode([String].self) { models = ms }
    }

    private func apply(_ event: Event) {
        switch event {
        case .taskUpserted(let t):
            if t.archived {
                tasks.removeAll { $0.id == t.id }
                if let idx = archived.firstIndex(where: { $0.id == t.id }) { archived[idx] = t }
                else { archived.insert(t, at: 0) }
            } else {
                archived.removeAll { $0.id == t.id }
                if let idx = tasks.firstIndex(where: { $0.id == t.id }) { tasks[idx] = t }
                else { tasks.append(t) }
            }
        case .taskRemoved(let id):
            tasks.removeAll { $0.id == id }
            archived.removeAll { $0.id == id }
            if selectedId == id { selectedId = nil }
        case .activity(let item):
            activity.insert(item, at: 0)
            if activity.count > 200 { activity.removeLast(activity.count - 200) }
        }
    }

    // MARK: actions

    func spawn(prompt: String, repo: String, branch: String, model: String?, startIn: StartIn) async {
        var p: [String: JSONValue] = [
            "prompt": .string(prompt), "repo": .string(repo), "branch": .string(branch),
            "col": .string(startIn.rawValue),
        ]
        if let model { p["model"] = .string(model) }
        do {
            let t = try await client.call("spawn", .object(p)).decode(Task.self)
            apply(.taskUpserted(t))   // show the card immediately; the event stream is idempotent
            selectedId = t.id
            toast("Spawned “\(t.title)”", sub: "\((t.repo as NSString).lastPathComponent) · \(t.branch)")
        } catch { toast("Spawn failed", sub: "\(error)", color: .red) }
    }

    func move(_ id: UUID, to col: Column) async {
        _ = try? await client.call("move", .object(["ref": .string(id.uuidString), "col": .string(col.rawValue)]))
    }
    func archive(_ id: UUID) async {
        _ = try? await client.call("archive", .object(["ref": .string(id.uuidString)]))
        if selectedId == id { selectedId = nil }
        toast("Archived", sub: nil)
    }
    func send(_ id: UUID, _ message: String) async {
        _ = try? await client.call("send", .object(["ref": .string(id.uuidString), "message": .string(message)]))
    }
    func restart(_ id: UUID) async {
        _ = try? await client.call("restart", .object(["ref": .string(id.uuidString)]))
    }
    func resume(_ id: UUID) async {
        do { _ = try await client.call("resume", .object(["ref": .string(id.uuidString)])) }
        catch { toast("Resume failed", sub: "\(error)", color: .red) }
    }
    func openShell(_ id: UUID) async -> String? {
        guard let r = try? await client.call("shell", .object(["ref": .string(id.uuidString)])) else { return nil }
        return r["window"]?.stringValue
    }

    /// Open a new shell window for a card and track it (the one place that mutates shell state).
    func newShell(_ id: UUID) async {
        if let w = await openShell(id) {
            shellWindows[id, default: []].append(w)
            selectedShell[id] = w
            shellOpen.insert(id)
        }
    }
    func sessions(_ id: UUID) async -> CardSessions? {
        try? await client.call("sessions", .object(["ref": .string(id.uuidString)])).decode(CardSessions.self)
    }
    func openInZed(_ id: UUID) async {
        _ = try? await client.call("openInZed", .object(["ref": .string(id.uuidString)]))
        if let t = selected { toast("Opening changes in Zed…", sub: "\((t.repo as NSString).lastPathComponent) · \(t.branch)") }
    }
    func saveConfig(_ cfg: Config) async {
        if let saved = try? await client.call("setConfig", JSONValue(encodable: cfg)).decode(Config.self) { config = saved }
    }

    /// Focus a card from an `orchestra://task/<shortId>-<slug>` URL (the registered URL scheme).
    func select(ref: String) {
        let all = tasks + archived
        if let t = try? resolve(TaskRef(parsing: ref), in: all) { selectedId = t.id }
    }

    func toast(_ title: String, sub: String?, color: Toast.ToastColor = .green) {
        let t = Toast(title: title, sub: sub, color: color)
        toasts.append(t)
        _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .milliseconds(4200))
            self?.toasts.removeAll { $0.id == t.id }
        }
    }
}
