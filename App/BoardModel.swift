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
    @Published var models: [AgentModel] = []
    @Published var connected = false
    @Published var connecting = false
    @Published var toasts: [Toast] = []

    // Sheet / popover UI state.
    @Published var showSpawn = false
    @Published var showDone = false
    @Published var showActivity = false
    @Published var showOnboarding = false
    @Published var spawnDefaultColumn: Column = .plan

    /// First-run flag: once the user has installed the daemon we skip the welcome screen.
    @AppStorage("orch_onboarded") var onboarded = false

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

    /// Other non-archived cards that share this card's worktree (any status). Multiple agents on one
    /// worktree is intentional — keeping them from clobbering each other is the user's job; this just
    /// surfaces the co-located cards. Oldest-first for a stable list.
    func worktreeSiblings(of task: Task) -> [Task] {
        tasks.filter { $0.worktree == task.worktree && $0.id != task.id }
             .sorted { $0.createdAt < $1.createdAt }
    }

    /// Hover-tooltip text listing the co-located cards (`<shortId>  <title>` per line). Empty when none.
    func worktreeSiblingsHelp(of task: Task) -> String {
        let sibs = worktreeSiblings(of: task)
        guard !sibs.isEmpty else { return "" }
        return "Also on this worktree:\n" + sibs.map { "\($0.shortId)  \($0.title)" }.joined(separator: "\n")
    }

    /// distinct agents with running/waiting cards (for the MCP chip count).
    var activeAgentCount: Int {
        Set(tasks.filter { $0.status == .running || $0.status == .waiting }.map(\.agentId)).count
    }

    // MARK: lifecycle

    private var streamStarted = false

    /// Launch-time bootstrap. We never install the background daemon implicitly — that's an explicit,
    /// approved step. Flow:
    ///   • daemon already running        → attach (and consider the user onboarded)
    ///   • first run, daemon not running → show the welcome / install screen
    ///   • returning user, daemon down   → stay offline; the banner offers a one-click restart
    func bootstrap() async {
        if DaemonLifecycle().isRunning() {
            onboarded = true
            await start()
        } else if !onboarded {
            showOnboarding = true
        } else {
            connected = false
        }
    }

    /// Invoked from the onboarding screen's primary button. Installs + starts the daemon and, on
    /// success, marks onboarding complete and dismisses the welcome screen.
    func installDaemon() async {
        await ensureDaemonAndStart()
        if connected {
            onboarded = true
            showOnboarding = false
        }
    }

    /// Ensure the background daemon is installed/running, then connect and start streaming. This is
    /// the user-approved path (button / banner) — it may install the LaunchAgent on first use.
    func ensureDaemonAndStart() async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }

        let life = DaemonLifecycle()
        if !life.isRunning() {
            try? life.ensureRunning(orchestradBin: Self.bundledDaemonBinary())
        }
        await start()
    }

    /// Path to the orchestrad we ship inside the app bundle (Contents/Resources/bin). Falls back to a
    /// sibling/PATH lookup for dev runs where the binary isn't embedded.
    static func bundledDaemonBinary() -> String {
        let embedded = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/orchestrad").path
        if FileManager.default.isExecutableFile(atPath: embedded) { return embedded }
        return siblingBinary("orchestrad")
    }

    func start() async {
        // Retry briefly — the daemon may still be binding its socket right after launch.
        connected = false
        for _ in 0..<25 {
            do { try client.connect(); connected = true; break }
            catch { try? await _Concurrency.Task.sleep(for: .milliseconds(200)) }
        }
        guard connected else { return }
        await refresh()
        // Live event stream. Re-wire it on every (re)connect: when the daemon restarts, the previous
        // stream ends, so a one-shot subscribe would leave the board doing a single refresh and then
        // going permanently silent. `streamStarted` only guards against double-subscribing while one
        // is already live; it's reset when the stream ends (below).
        guard !streamStarted else { return }
        streamStarted = true
        let stream = client.subscribe()
        _Concurrency.Task { [weak self] in
            for await event in stream { await self?.apply(event) }
            // Stream ended → the daemon connection dropped. Reflect offline and allow the next
            // (re)connect to wire a fresh stream.
            await self?.handleStreamEnded()
        }
    }

    /// The event stream ended (daemon went away). Surface offline and re-arm subscription.
    private func handleStreamEnded() {
        connected = false
        streamStarted = false
    }

    func refresh() async {
        if let list = try? await client.call("list", .object([:])).decode([Task].self) { tasks = list }
        if let arch = try? await client.call("archivedList").decode([Task].self) { archived = arch }
        if let cfg = try? await client.call("getConfig").decode(Config.self) { config = cfg }
        if let ms = try? await client.call("models").decode([AgentModel].self) { models = ms }
    }

    private func apply(_ event: Event) {
        switch event {
        case .taskUpserted(let t):
            if t.archived {
                tasks.removeAll { $0.id == t.id }
                if let idx = archived.firstIndex(where: { $0.id == t.id }) { archived[idx] = t }
                else { archived.insert(t, at: 0) }
                // Archived elsewhere (CLI/MCP/another client): it left the board, so don't keep the
                // inspector pinned to it (`selected` also searches `archived`, so it wouldn't clear
                // on its own).
                if selectedId == t.id { selectedId = nil }
            } else {
                archived.removeAll { $0.id == t.id }
                if let idx = tasks.firstIndex(where: { $0.id == t.id }) { tasks[idx] = t }
                else { tasks.append(t) }
            }
        case .taskRemoved(let id):
            tasks.removeAll { $0.id == id }
            archived.removeAll { $0.id == id }
            if selectedId == id { selectedId = nil }
            // Reap per-card shell state so it doesn't accumulate for the process's lifetime.
            shellOpen.remove(id); shellWindows[id] = nil; selectedShell[id] = nil
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
        do {
            _ = try await client.call("restart", .object(["ref": .string(id.uuidString)]))
            toast("Started a new session", sub: nil)
        } catch { toast("Couldn't start session", sub: "\(error)", color: .red) }
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

    /// Close one shell window, dropping it from the daemon and the per-card state. Selects a
    /// neighbouring tab if the closed one was active; hides the strip once the last shell is gone.
    func closeShell(_ id: UUID, _ window: String) async {
        _ = try? await client.call("closeShell", .object(["ref": .string(id.uuidString),
                                                          "window": .string(window)]))
        var ws = shellWindows[id] ?? []
        guard let idx = ws.firstIndex(of: window) else { return }
        ws.remove(at: idx)
        shellWindows[id] = ws.isEmpty ? nil : ws
        if selectedShell[id] == window {
            selectedShell[id] = ws.isEmpty ? nil : ws[min(idx, ws.count - 1)]
        }
        if ws.isEmpty { shellOpen.remove(id) }
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
