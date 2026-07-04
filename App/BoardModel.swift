import SwiftUI
import AppKit
import OrchestraCore

/// Which surface currently has keyboard focus, for the context chip + pane-focus moves. Distinct from
/// `KeyContext` (which is derived per-event): this is the app's coarse notion of "where am I."
enum FocusZone { case board, inspector, terminal, shell }

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
    @Published var agents: [AgentInfo] = []
    @Published var connected = false
    @Published var connecting = false
    @Published var toasts: [Toast] = []

    // Sheet / popover UI state.
    @Published var showSpawn = false
    @Published var showDone = false
    @Published var showActivity = false
    @Published var showOnboarding = false
    @Published var spawnDefaultColumn: Column = .plan

    // Keyboard-navigation state (see notes/plans/2026-07-02-keyboard-shortcuts.md).
    @Published var focusZone: FocusZone = .board
    @Published var showHelp = false
    /// Non-nil while the `/` card filter is active; the empty string means "field open, no query yet".
    @Published var searchQuery: String? = nil
    /// The inspector's Agent/Diff mode, kept *per card* (keyed by task id) so switching cards preserves
    /// each card's own choice instead of carrying one global mode everywhere. Defaults to `.agent`.
    @Published var inspectorModeByCard: [UUID: InspectorMode] = [:]
    /// The selected card's Agent/Diff mode. Hoisted here so the `d` verb can toggle it from the board;
    /// reads/writes route through `inspectorModeByCard` for the current selection.
    var inspectorMode: InspectorMode {
        get { selectedId.flatMap { inspectorModeByCard[$0] } ?? .agent }
        set { if let id = selectedId { inspectorModeByCard[id] = newValue } }
    }
    /// A one-shot pulse the inspector observes to open its Inbox popover (from the `I` verb).
    @Published var requestInboxOpen = false
    /// The `:` command palette overlay.
    @Published var showPalette = false
    /// `f` link-hint mode: labels overlaid on cards; typing a label jumps to it.
    @Published var hintActive = false
    @Published var hintLabels: [UUID: String] = [:]
    /// Non-nil while the archive-confirm dialog is up (keyboard `a` path only). Holds the card id
    /// awaiting confirmation; ⏎ archives, esc/⌘W cancels. Deliberate UI actions (buttons, palette)
    /// archive directly and never set this.
    @Published var archiveConfirm: UUID?

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

    /// Client-local connection list + which one is active (local by default).
    let connections = ConnectionStore()
    /// Owns the SSH tunnel for a remote connection; publishes tunnel state.
    let connectionController = ConnectionController()
    /// Live link state, mirrored from the client for the Connections pane's status chip.
    @Published var connectionState: ConnectionState = .down
    /// Rebuilt whenever the active connection changes (a fresh transport per connection).
    private(set) var client: ControlClient
    /// Posts a macOS notification / sound when an agent card flips to `.waiting` (needs the human).
    private let notifier = AgentNotifier()

    init() {
        client = ControlClient(socketPath: Config.socketPath, source: .app)
        wireState()
        notifier.onSelect = { [weak self] id in self?.selectedId = id }
    }

    /// Mirror the client's connection state onto the main actor (drives `connectionState` + `connected`).
    private func wireState() {
        client.onState = { [weak self] s in
            _Concurrency.Task { @MainActor in
                self?.connectionState = s
                switch s {
                case .live: self?.connected = true
                case .down: self?.connected = false
                case .connecting, .retrying: break   // transient — don't flap the board offline
                }
            }
        }
    }

    /// Terminal host for the active connection: local tmux, or the remote box over the SSH control socket.
    var terminalHost: AgentTerminalView.TerminalHost { connectionController.terminalHost }
    /// tmux `-L` socket name for the active connection (remote boxes may differ from the local default).
    var terminalTmuxSocket: String { connections.active.remoteTmuxSocket }

    var selected: Task? { tasks.first { $0.id == selectedId } ?? archived.first { $0.id == selectedId } }

    func cards(in column: Column) -> [Task] {
        tasks.filter { $0.column == column && !$0.archived && $0.origin == .worktree }
             .sorted { $0.order < $1.order }
    }

    /// Non-worktree cards (`.borrowed`/`.scratch`) live in the standalone freeform region, not the
    /// plan/impl/review lifecycle columns. Oldest-first for a stable order.
    var freeformTasks: [Task] {
        tasks.filter { $0.origin != .worktree && !$0.archived }
             .sorted { $0.createdAt < $1.createdAt }
    }

    /// Other non-archived cards that share this card's worktree (any status). Multiple agents on one
    /// worktree is intentional — keeping them from clobbering each other is the user's job; this just
    /// surfaces the co-located cards. Oldest-first for a stable list.
    func worktreeSiblings(of task: Task) -> [Task] {
        tasks.filter { $0.cwd == task.cwd && $0.id != task.id
                       && $0.origin == .worktree && task.origin == .worktree }
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
        notifier.requestAuthorization()
        await activate(connections.active)
    }

    /// Point the board at a connection: resolve its local socket (spinning the SSH tunnel for a remote),
    /// (re)build the client, then connect + stream. Preserves the local onboarding/daemon-install flow.
    func activate(_ conn: Connection) async {
        client.close()
        connectionController.deactivate()
        connectionController.onTunnelExit = { [weak self] in
            // The tunnel dropped: respawn the master + reconnect the client to the new forwarded socket.
            _Concurrency.Task { @MainActor in await self?.activate(conn) }
        }
        do {
            let sockPath = try await connectionController.localSocketPath(for: conn)
            client = ControlClient(socketPath: sockPath, source: .app)
            wireState()
            streamStarted = false
            if conn.isLocal {
                if DaemonLifecycle().isRunning() { onboarded = true; await start() }
                else if !onboarded { showOnboarding = true } else { connected = false }
            } else {
                await start()
            }
        } catch {
            connected = false
            toast("Couldn't connect", sub: "\(error)", color: .red)
        }
    }

    /// Switch the active connection (persisted) and re-point the board at it.
    func switchConnection(_ id: UUID) async {
        connections.activeId = id
        await activate(connections.active)
    }

    /// Connect/Disconnect toggle for the Connections pane.
    func disconnect() {
        client.close()
        connectionController.deactivate()
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
            for await event in stream { self?.apply(event) }
            // Stream ended → the daemon connection dropped. Reflect offline and allow the next
            // (re)connect to wire a fresh stream.
            self?.handleStreamEnded()
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
        if let ag = try? await client.call("agents").decode([AgentInfo].self) { agents = ag }
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
                if archiveConfirm == t.id { archiveConfirm = nil }
            } else {
                // Prior status of an *existing* card, captured before we overwrite it. `nil` for a
                // freshly-appended card — so new cards and the post-reconnect refresh (which sets
                // `tasks` wholesale, bypassing `apply`) never fire a notification.
                let prev = tasks.first { $0.id == t.id }?.status
                archived.removeAll { $0.id == t.id }
                if let idx = tasks.firstIndex(where: { $0.id == t.id }) { tasks[idx] = t }
                else { tasks.append(t) }
                // Genuine transitions → the matching notification trigger. `prev == nil` (fresh card)
                // and the post-reconnect wholesale set (which bypasses `apply`) never fire.
                if let prev {
                    if prev != .waiting, t.status == .waiting {
                        notifier.notify(t.waitReason == .permission ? .permission : .needsYou, task: t)
                    }
                    if prev != .dead, t.status == .dead {
                        notifier.notify(.died, task: t)
                    }
                }
            }
        case .taskRemoved(let id):
            tasks.removeAll { $0.id == id }
            archived.removeAll { $0.id == id }
            if selectedId == id { selectedId = nil }
            if archiveConfirm == id { archiveConfirm = nil }
            // Reap per-card shell state so it doesn't accumulate for the process's lifetime.
            shellOpen.remove(id); shellWindows[id] = nil; selectedShell[id] = nil
        case .activity(let item):
            activity.insert(item, at: 0)
            if activity.count > 200 { activity.removeLast(activity.count - 200) }
        }
    }

    // MARK: actions

    func spawn(prompt: String, repo: String, branch: String, model: String?, startIn: StartIn,
               agent: String? = nil,
               cwd: String? = nil, access: CardAccess = .readWrite, scratch: Bool = false) async {
        var p: [String: JSONValue] = [
            "prompt": .string(prompt), "repo": .string(repo), "branch": .string(branch),
            "col": .string(startIn.rawValue),
        ]
        if let model { p["model"] = .string(model) }
        if let agent { p["agent"] = .string(agent) }
        // Freeform card: a borrowed cwd (and its access mode) instead of a worktree.
        if let cwd { p["cwd"] = .string(cwd); p["access"] = .string(access.rawValue) }
        // Scratch card: a fresh throwaway dir the daemon mkdir's (and rm -rf's on archive).
        if scratch { p["scratch"] = .bool(true) }
        do {
            let t = try await client.call("spawn", .object(p)).decode(Task.self)
            apply(.taskUpserted(t))   // show the card immediately; the event stream is idempotent
            selectedId = t.id
            let sub = t.origin == .worktree
                ? "\((t.repo as NSString).lastPathComponent) · \(t.branch)"
                : (t.cwd as NSString).lastPathComponent
            toast("Spawned “\(t.title)”", sub: sub)
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
    /// Reopen a Done card: the daemon recreates its worktree + resumes the agent; we bring the card back
    /// onto the board, select it (so the live inspector opens), and close the Done popover.
    func reopen(_ id: UUID) async {
        do {
            let t = try await client.call("reopen", .object(["ref": .string(id.uuidString)])).decode(Task.self)
            apply(.taskUpserted(t))   // off the Done list onto the board immediately; the stream is idempotent
            selectedId = t.id
            showDone = false
            toast("Reopened “\(t.title)”", sub: nil)
        } catch { toast("Reopen failed", sub: "\(error)", color: .red) }
    }
    func send(_ id: UUID, _ message: String) async {
        _ = try? await client.call("send", .object(["ref": .string(id.uuidString), "message": .string(message)]))
    }

    /// Inbox editor: list a card's pending messages (empty on any error).
    func inboxPeek(_ id: UUID) async -> [InboxMessage] {
        (try? await client.call("inbox", .object(["ref": .string(id.uuidString)]))
            .decode([InboxMessage].self)) ?? []
    }
    /// Inbox editor: edit one queued message's text.
    func inboxEdit(_ id: UUID, messageId: UUID, text: String) async {
        _ = try? await client.call("inbox-edit", .object(["ref": .string(id.uuidString),
            "id": .string(messageId.uuidString), "text": .string(text)]))
    }
    /// Inbox editor: remove one queued message.
    func inboxRemove(_ id: UUID, messageId: UUID) async {
        _ = try? await client.call("inbox-remove", .object(["ref": .string(id.uuidString),
            "id": .string(messageId.uuidString)]))
    }
    /// Inbox editor: reorder a card's queued messages (full new order).
    func inboxReorder(_ id: UUID, orderedIds: [UUID]) async {
        _ = try? await client.call("inbox-reorder", .object(["ref": .string(id.uuidString),
            "ids": .array(orderedIds.map { .string($0.uuidString) })]))
    }

    /// Read-only trust check for the spawn sheet's freeform trust indicator (T1's ledger via the daemon).
    func trustState(path: String) async -> Bool {
        guard let r = try? await client.call("trustState", .object(["path": .string(path)])) else { return false }
        return r["trusted"]?.boolValue ?? false
    }

    /// Grant a human's trust for a borrowed directory (the T2 grant), so the freeform card can run
    /// read-write. The app is a human surface — the user clicking "Trust this directory" in the spawn
    /// sheet *is* the human gate the daemon's `SurfaceGrantResolver` requires for an `.app` source, so
    /// this succeeds without any further prompt. Returns whether the directory is now trusted; toasts on
    /// failure (a denial can only happen if the resolver policy changes under us).
    func trust(path: String) async -> Bool {
        do {
            let r = try await client.call("trust", .object(["path": .string(path)]))
            return r["granted"]?.boolValue ?? false
        } catch {
            toast("Couldn't trust directory", sub: "\(error)", color: .red)
            return false
        }
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

    /// Open a read-only inspect shell for a card (read-only claude in its worktree) and track its
    /// window like a normal shell tab.
    func inspect(_ id: UUID) async {
        guard let r = try? await client.call("inspect", .object(["ref": .string(id.uuidString)])),
              let w = r["window"]?.stringValue else { return }
        shellWindows[id, default: []].append(w)
        selectedShell[id] = w
        shellOpen.insert(id)
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
    /// Rendered git patch for the inspector Diff view (axis 7). App-only internal endpoint — agents
    /// read a diff by running `git diff` in the card's cwd. `""` for non-git cards.
    func diffText(_ id: UUID, base: String) async -> String {
        (try? await client.call("diffText",
            .object(["ref": .string(id.uuidString), "base": .string(base)])).decode(String.self)) ?? ""
    }
    func openInZed(_ id: UUID) async {
        let t = (tasks + archived).first { $0.id == id }
        do {
            _ = try await client.call("openInZed", .object(["ref": .string(id.uuidString)]))
            if let t { toast("Opening changes in Zed…", sub: "\((t.repo as NSString).lastPathComponent) · \(t.branch)") }
        } catch {
            toast("Couldn't open in Zed", sub: "\(error)", color: .red)
        }
    }
    func openNotes(_ id: UUID) async {
        let t = (tasks + archived).first { $0.id == id }
        do {
            let r = try await client.call("openNotes", .object(["ref": .string(id.uuidString)]))
            let opened = r["opened"]?.intValue ?? 0
            let total = r["total"]?.intValue ?? 0
            let where_ = t.map { ($0.cwd as NSString).lastPathComponent } ?? "worktree"
            let title: String
            if total == 0 { title = "Opening worktree notes…" }
            else if opened < total { title = "Opening \(opened) of \(total) changed notes…" }
            else { title = "Opening \(total) changed note\(total == 1 ? "" : "s")…" }
            toast(title, sub: where_)
        } catch {
            toast("Couldn't open notes", sub: "\(error)", color: .red)
        }
    }
    func saveConfig(_ cfg: Config) async {
        if let saved = try? await client.call("setConfig", JSONValue(encodable: cfg)).decode(Config.self) { config = saved }
    }

    /// Focus a card from an `orchestra://task/<shortId>-<slug>` URL (the registered URL scheme).
    func select(ref: String) {
        let all = tasks + archived
        if let t = try? resolve(TaskRef(parsing: ref), in: all) { selectedId = t.id }
    }

    // MARK: keyboard-navigation intents
    // Thin executors the KeyboardController calls; selection movement delegates to the pure
    // BoardNavigator, everything else reuses the existing daemon-backed actions above.

    func selectMove(_ dir: Direction) {
        selectedId = BoardNavigator.move(tasks, selected: selectedId, dir)
    }
    func selectEnd(first: Bool) {
        selectedId = BoardNavigator.end(tasks, selected: selectedId, first: first)
    }

    /// Carry the selected card one column left/right (Plan↔Impl↔Review).
    func carrySelected(_ dir: Direction) {
        guard let id = selectedId, let col = BoardNavigator.columnOf(tasks, id) else { return }
        let order: [Column] = [.plan, .impl, .review]
        guard let ci = order.firstIndex(of: col) else { return }
        let ti = dir == .left ? ci - 1 : ci + 1
        guard ti >= 0, ti < order.count else { return }
        _Concurrency.Task { await move(id, to: order[ti]) }
    }

    /// Descend the keyboard into the selected card's agent terminal (Enter / i). No-op with no
    /// selection so the focus ring never lights on an empty inspector.
    func enterTerminalZone() {
        guard selectedId != nil else { return }
        focusZone = .terminal
        FocusBridge.enterTerminal()
    }

    /// A mouse click on a card selects it AND descends into its agent terminal (matching Enter / i),
    /// so the card glow, the inspector ring, and the real first responder all agree after the click.
    /// Falls back to the board zone when the card has no mounted terminal (e.g. a dead agent showing
    /// RecoveryView), so `focusZone` never claims a terminal that isn't there.
    func selectAndEnterTerminal(_ id: UUID) {
        let sameCard = selectedId == id
        selectedId = id
        focusZone = .terminal
        if sameCard {
            if !FocusBridge.enterTerminal() { focusZone = .board }   // already mounted → claim now
        } else {
            // Selecting a different card remounts the inspector; its autofocus (focusZone == .terminal)
            // claims focus on mount. Re-assert once that terminal view exists, as a fallback.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                if !FocusBridge.enterTerminal() { self?.focusZone = .board }
            }
        }
    }

    func archiveSelected() { if let id = selectedId { _Concurrency.Task { await archive(id) } } }

    /// The keyboard `a` path: don't archive immediately — raise the confirm dialog. Archive is
    /// effectively permanent, and a bare `a` is too easy to fire when focus isn't where you think.
    func requestArchiveSelected() { if let id = selectedId { archiveConfirm = id } }
    /// ⏎ in the confirm dialog: perform the archive we were holding.
    func confirmArchive() { if let id = archiveConfirm { archiveConfirm = nil; _Concurrency.Task { await archive(id) } } }
    /// esc / ⌘W in the confirm dialog: back out, archive nothing.
    func cancelArchive() { archiveConfirm = nil }
    /// A card's title by id (searches board + archived), for confirm-dialog copy. "" if unknown.
    func cardTitle(_ id: UUID) -> String { (tasks + archived).first { $0.id == id }?.title ?? "" }
    func openZedSelected() { if let id = selectedId { _Concurrency.Task { await openInZed(id) } } }
    func openNotesSelected() { if let id = selectedId { _Concurrency.Task { await openNotes(id) } } }

    /// Yank a reference to the selected card to the pasteboard (chat link / tmux target / path).
    func copySelected(_ target: CopyTarget) {
        guard let t = selected else { return }
        let s: String
        switch target {
        case .chatLink: s = t.ref()
        case .tmux:     s = "\(t.tmuxSession):agent"
        case .path:     s = t.cwd
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        toast("Copied", sub: s)
    }

    /// Jump to a region: select the first card of a column / freeform, or open a popover / settings.
    func goTo(_ target: GoTarget) {
        switch target {
        case .plan:     selectedId = BoardNavigator.columnCards(tasks, .plan).first?.id
        case .impl:     selectedId = BoardNavigator.columnCards(tasks, .impl).first?.id
        case .review:   selectedId = BoardNavigator.columnCards(tasks, .review).first?.id
        case .freeform: selectedId = freeformTasks.first?.id; focusZone = .board
        case .activity: showActivity = true
        case .done:     showDone = true
        case .settings: NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    /// Cmd-W / Esc "close the frontmost thing," peeling most-transient-first.
    func closeFrontmost() {
        if archiveConfirm != nil { archiveConfirm = nil; return }   // the confirm dialog is frontmost
        if hintActive { endHint(); return }
        if showHelp { showHelp = false; return }
        if showPalette { showPalette = false; return }
        if showSpawn { showSpawn = false; return }
        if showDone { showDone = false; return }
        if showActivity { showActivity = false; return }
        if searchQuery != nil { searchQuery = nil; return }
        // A focused shell tab closes first.
        if focusZone == .shell, let id = selectedId, let w = selectedShell[id] {
            _Concurrency.Task { await closeShell(id, w) }
            return
        }
        // Keyboard inside the agent terminal → step back out to the board, keeping the card open so you
        // can carry on navigating (this is the Cmd-W path; a live terminal owns plain Esc itself).
        if focusZone != .board {
            focusZone = .board
            NSApp.keyWindow?.makeFirstResponder(nil)
            return
        }
        // On the board with a card open → close the inspector. Archiving is the `a` verb only, never
        // Esc — now that "board + selection" is the resting state, Esc-to-archive would be a footgun.
        if selectedId != nil { selectedId = nil }
    }

    // MARK: search / hints / resize / collapse

    /// Every visible card in navigation order: Plan → Impl → Review columns, then the freeform dock.
    var orderedVisibleCards: [Task] {
        BoardNavigator.columnCards(tasks, .plan)
            + BoardNavigator.columnCards(tasks, .impl)
            + BoardNavigator.columnCards(tasks, .review)
            + freeformTasks
    }

    /// Ids of cards matching the active `/` query (title / branch / repo substring, case-insensitive).
    var searchMatchIds: [UUID] {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespaces).lowercased(), !q.isEmpty else { return [] }
        return orderedVisibleCards.filter {
            $0.title.lowercased().contains(q) || $0.branch.lowercased().contains(q)
                || (($0.repo as NSString).lastPathComponent).lowercased().contains(q)
        }.map(\.id)
    }
    /// True when a search is active and this card matches (drives the dim of non-matches).
    func isSearchMatch(_ t: Task) -> Bool {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return true }
        return searchMatchIds.contains(t.id)
    }
    /// A search filter is active (a non-empty committed query).
    var searchActive: Bool {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespaces) else { return false }
        return !q.isEmpty
    }
    func searchNext() { cycleMatch(+1) }
    func searchPrev() { cycleMatch(-1) }
    private func cycleMatch(_ step: Int) {
        let ids = searchMatchIds
        guard !ids.isEmpty else { return }
        let cur = selectedId.flatMap { ids.firstIndex(of: $0) }
        let next = cur.map { ($0 + step + ids.count) % ids.count } ?? 0
        selectedId = ids[next]
    }

    // f link-hints: assign a short label to every visible card; the controller matches typed keys.
    private static let hintAlphabet = Array("asdfghjklqwertyuiopzxcvbnm")
    func beginHint() {
        let cards = orderedVisibleCards
        guard !cards.isEmpty else { return }
        let a = Self.hintAlphabet
        let width = cards.count <= a.count ? 1 : 2
        var labels: [UUID: String] = [:]
        for (i, c) in cards.enumerated() {
            labels[c.id] = width == 1 ? String(a[i]) : "\(a[i / a.count])\(a[i % a.count])"
        }
        hintLabels = labels
        hintActive = true
    }
    func endHint() { hintActive = false; hintLabels = [:] }
    /// The card whose hint label exactly equals `typed`, if any.
    func hintTarget(_ typed: String) -> UUID? { hintLabels.first { $0.value == typed }?.key }

    /// Grow/shrink the focused pane's movable edge (Ctrl-Shift-hjkl), writing the same @AppStorage the
    /// drag handles use so the views update live.
    func resizeFocusedPane(_ dir: Direction) {
        let d = UserDefaults.standard
        func bump(_ key: String, _ fallback: Double, _ delta: Double, _ lo: Double, _ hi: Double) {
            let cur = d.object(forKey: key) as? Double ?? fallback
            d.set(min(hi, max(lo, cur + delta)), forKey: key)
        }
        switch dir {
        case .left, .right:
            guard selectedId != nil else { return }         // inspector must be open
            bump("inspectorWidth", 392, dir == .left ? 40 : -40, 320, 1000)
        case .up, .down:
            let delta = dir == .up ? 30.0 : -30.0
            if focusZone == .shell || focusZone == .terminal {
                bump("shellPanelHeight", 220, delta, 80, 500)
            } else if !freeformTasks.isEmpty {
                bump("freeformPanelHeight", 208, delta, 140, 620)
            }
        }
    }

    /// Toggle the focused collapsible region (z): the shell panel when a terminal/shell is focused,
    /// else the freeform dock. Writes the same @AppStorage the chevrons use.
    func toggleCollapseFocused() {
        let key = (focusZone == .shell || focusZone == .terminal) ? "shellMinimized" : "freeformCollapsed"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    // MARK: command palette (:)

    @Published var paletteQuery = ""
    @Published var paletteIndex = 0

    struct PaletteCommand: Identifiable { let id = UUID(); let title: String; let keys: String; let run: () -> Void }

    func openPalette() { paletteQuery = ""; paletteIndex = 0; showPalette = true }

    /// The full command catalogue (label · shortcut · action). Rebuilt each access; closures capture
    /// `self` weakly-enough (transient values) to avoid a retained cycle.
    func paletteCommands() -> [PaletteCommand] {
        [
            .init(title: "New card", keys: "c") { [self] in spawnDefaultColumn = .plan; showSpawn = true },
            .init(title: "Search cards", keys: "/") { [self] in searchQuery = "" },
            .init(title: "Toggle Agent / Diff view", keys: "d") { [self] in inspectorMode = inspectorMode == .agent ? .diff : .agent },
            .init(title: "Archive card", keys: "a") { [self] in archiveSelected() },
            .init(title: "View changes in Zed", keys: "o") { [self] in openZedSelected() },
            .init(title: "Open inbox editor", keys: "I") { [self] in requestInboxOpen = true },
            .init(title: "New shell tab", keys: "t") { [self] in if let id = selectedId { _Concurrency.Task { await newShell(id) } } },
            .init(title: "Copy chat link", keys: "y c") { [self] in copySelected(.chatLink) },
            .init(title: "Copy tmux target", keys: "y t") { [self] in copySelected(.tmux) },
            .init(title: "Copy path", keys: "y p") { [self] in copySelected(.path) },
            .init(title: "Go to Plan", keys: "g p") { [self] in goTo(.plan) },
            .init(title: "Go to Implementation", keys: "g i") { [self] in goTo(.impl) },
            .init(title: "Go to Review", keys: "g r") { [self] in goTo(.review) },
            .init(title: "Go to Freeform", keys: "g f") { [self] in goTo(.freeform) },
            .init(title: "Open Activity", keys: "g a") { [self] in showActivity = true },
            .init(title: "Open Done", keys: "g d") { [self] in showDone = true },
            .init(title: "Open Settings", keys: "g s") { [self] in goTo(.settings) },
            .init(title: "Keyboard shortcuts", keys: "?") { [self] in showHelp = true },
        ]
    }

    /// Commands whose title fuzzily matches the query (case-insensitive subsequence).
    var filteredPaletteCommands: [PaletteCommand] {
        let q = paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return paletteCommands() }
        return paletteCommands().filter { fuzzySubsequence(q, $0.title.lowercased()) }
    }

    func paletteMove(_ delta: Int) {
        let n = filteredPaletteCommands.count
        guard n > 0 else { paletteIndex = 0; return }
        paletteIndex = (paletteIndex + delta + n) % n
    }
    func runPaletteSelection() {
        let cmds = filteredPaletteCommands
        guard paletteIndex >= 0, paletteIndex < cmds.count else { showPalette = false; return }
        let cmd = cmds[paletteIndex]
        showPalette = false
        cmd.run()
    }

    private func fuzzySubsequence(_ needle: String, _ haystack: String) -> Bool {
        var it = haystack.makeIterator()
        for ch in needle {
            var found = false
            while let h = it.next() { if h == ch { found = true; break } }
            if !found { return false }
        }
        return true
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
