import SwiftUI
import OrchestraKit
#if os(macOS)
// Host-only: the daemon-lifecycle helpers (DaemonLifecycle, siblingBinary) live in OrchestraCore,
// reached via OrchestraUI's macOS-conditional dependency. Every use is behind `#if os(macOS)` so the
// iOS build never pulls OrchestraCore. The AppKit UI operations that used to live here (pasteboard,
// settings window, focus) are now injected through the `PlatformUI` protocols — no `import AppKit`.
import OrchestraCore
#endif

/// Which surface currently has keyboard focus, for the context chip + pane-focus moves. Distinct from
/// `KeyContext` (which is derived per-event): this is the app's coarse notion of "where am I."
public enum FocusZone { case board, inspector, terminal, shell }

public struct Toast: Identifiable {
    public let id = UUID()
    public let title: String
    public let sub: String?
    public var color: ToastColor = .green
    public enum ToastColor { case green, blue, red }
}

/// A request to present the phone's live **takeover** surface for a card (see `BoardModel.phoneTakeoverRequest`).
/// The card id doubles as the `Identifiable` id so a `fullScreenCover(item:)` presents (and re-presents for a
/// different card) correctly.
public struct PhoneTakeoverRequest: Identifiable, Equatable {
    public let id: UUID
    public init(cardId: UUID) { self.id = cardId }
}

/// The app's single source of view state. Subscribes to the daemon's event stream and drives all
/// SwiftUI views; every mutation is a thin call to the daemon (no business logic here).
@MainActor
public final class BoardModel: ObservableObject {
    @Published public var tasks: [Task] = []
    @Published public var archived: [Task] = []
    @Published public var activity: [ActivityItem] = []
    @Published public var selectedId: UUID?
    @Published public var config = Config()
    @Published public var models: [AgentModel] = []
    @Published public var agents: [AgentInfo] = []
    @Published public var connected = false
    @Published public var connecting = false
    @Published public var toasts: [Toast] = []

    // Spawn-sheet autofill: repos/dirs the daemon can spawn into (enumerated from its disk, which a
    // remote client can't see). Refreshed when the Spawn sheet opens; branches are fetched lazily per
    // repo via `spawnBranches(forRepo:)`.
    @Published public var spawnRepoCandidates: [RepoCandidate] = []
    @Published public var spawnDirCandidates: [String] = []

    // Sheet / popover UI state.
    @Published public var showSpawn = false
    @Published public var showDone = false
    @Published public var showActivity = false
    @Published public var showOnboarding = false
    @Published public var spawnDefaultColumn: Column = .plan
    /// A request to drop straight into the phone's live **takeover** surface for a card. Set when the phone
    /// SPAWNS a card (iOS): the phone that spawned it is the intended driver, so it auto-owns the agent
    /// terminal instead of requiring a separate "Take Over" tap (App-iOS presents `AgentTakeoverView` on
    /// this). `Identifiable` so a `fullScreenCover(item:)` drives it. Desktop leaves it nil (it owns
    /// terminals directly), so this is inert there.
    @Published public var phoneTakeoverRequest: PhoneTakeoverRequest?

    // Keyboard-navigation state (see notes/plans/2026-07-02-keyboard-shortcuts.md).
    @Published public var focusZone: FocusZone = .board {
        didSet {
            // A committed `/` search bar stays up so `n`/`N` cycle matches while you browse the board.
            // But once focus descends into a card (terminal/shell) it can't be Esc-dismissed anymore
            // (Esc belongs to the pty), and `n`/`N` no longer apply — so the search has served its
            // purpose. Clear it the moment focus leaves the board so the bar never strands itself.
            if focusZone != .board, searchQuery != nil { searchQuery = nil }
        }
    }
    @Published public var showHelp = false
    /// Non-nil while the `/` card filter is active; the empty string means "field open, no query yet".
    @Published public var searchQuery: String? = nil
    /// The inspector's Agent/Diff mode, kept *per card* (keyed by task id) so switching cards preserves
    /// each card's own choice instead of carrying one global mode everywhere. Defaults to `.agent`.
    @Published public var inspectorModeByCard: [UUID: InspectorMode] = [:]
    /// The selected card's Agent/Diff mode. Hoisted here so the `d` verb can toggle it from the board;
    /// reads/writes route through `inspectorModeByCard` for the current selection.
    public var inspectorMode: InspectorMode {
        get { selectedId.flatMap { inspectorModeByCard[$0] } ?? .agent }
        set { if let id = selectedId { inspectorModeByCard[id] = newValue } }
    }

    public func capabilities(for agentId: String) -> AgentCapabilities {
        agents.first { $0.id == agentId }?.capabilities ?? .claudeCode
    }

    /// A one-shot pulse the inspector observes to open its Inbox popover (from the `I` verb).
    @Published public var requestInboxOpen = false
    /// The `:` command palette overlay.
    @Published public var showPalette = false
    /// `f` link-hint mode: labels overlaid on cards; typing a label jumps to it.
    @Published public var hintActive = false
    @Published public var hintLabels: [UUID: String] = [:]
    /// Non-nil while the archive-confirm dialog is up (keyboard `a` path only). Holds the card id
    /// awaiting confirmation; ⏎ archives, esc/⌘W cancels. Deliberate UI actions (buttons, palette)
    /// archive directly and never set this.
    @Published public var archiveConfirm: UUID?

    /// First-run flag: once the user has installed the daemon we skip the welcome screen.
    @AppStorage("orch_onboarded") public var onboarded = false

    // Per-card shell state (keyed by task id so it survives selecting away and back).
    @Published public var shellOpen: Set<UUID> = []
    @Published public var shellWindows: [UUID: [String]] = [:]
    @Published public var selectedShell: [UUID: String] = [:]

    /// Daemon-authoritative agent-terminal ownership (PR D4), mirrored per card so the inspector can
    /// render the live terminal vs the "Taken over by phone" placeholder (PR D5). Ephemeral UI
    /// coordination only — rebuilt from `agentTerminalOwner` events (and a reconcile query on every
    /// (re)connect), never persisted. The stored snapshot's `owner == nil` means *available* (mount);
    /// a `.phone` owner means the desktop shows the placeholder and stays detached from the tmux window.
    @Published public var agentOwners: [UUID: AgentTerminalOwnerState] = [:]

    // Preferences (host props in the prototype).
    @AppStorage("orch_accent") public var accentRaw = Accent.blue.rawValue
    @AppStorage("orch_density") public var densityRaw = Density.comfortable.rawValue
    @AppStorage("orch_dark") public var darkMode = false

    public var accent: Accent { Accent(rawValue: accentRaw) ?? .blue }
    public var density: Density { Density(rawValue: densityRaw) ?? .comfortable }

    /// The platform seam — the three host UI operations (pasteboard, settings window, focus) that the
    /// desktop backs with AppKit and the iOS client backs with UIKit. Injected so `BoardModel` itself
    /// stays AppKit-free. Injected explicitly at every call site (no `.noop` default — see `init`); previews
    /// and tests pass `.noop` or a spy bundle deliberately.
    public let platform: PlatformUI

    /// Client-local connection list + which one is active (local by default).
    public let connections = ConnectionStore()
    /// Live link state, mirrored from the client for the Connections pane's status chip.
    @Published public var connectionState: ConnectionState = .down
    /// Rebuilt whenever the active connection changes (a fresh transport per connection).
    private(set) var client: ControlClient

    /// iOS only: supplies an SSH-backed control `Transport` for a `.remote` connection (the phone reaches
    /// the Mac daemon over SSH, not a local socket). Set by the app at launch; `nil` on macOS (which uses
    /// its own `connectionController`/SSH master). See `RemoteControlTransportProvider`.
    public weak var remoteControlTransportProvider: RemoteControlTransportProvider?

    /// Stable per-install identity sent to the daemon so it can attribute ownership + detect this
    /// client's disconnect (D3/D4). Resolved once; the same id is reused for local and remote links.
    private let clientId = ClientIdentity.persistentId(at: Config.clientIdPath)

    /// The last APNs device token handed to `registerForPush`, retained so a reconnect can re-assert the
    /// registration (N1). The token routinely arrives before `bootstrap()` finishes connecting, and the
    /// F3 dev transport can drop and rebuild `client` against a fresh socket (see `activate`); if the
    /// token registration landed while the link was down it's lost for the session. We keep the token and
    /// re-register on the `connectionState → .live` edge (`wireState`). `nil` until the phone hands one
    /// over; stays `nil` on macOS (no push token path there). Internal for test visibility.
    private(set) var pushToken: String?

    #if os(macOS)
    /// Owns the SSH tunnel for a remote connection; publishes tunnel state. Host-only: iOS reaches the
    /// daemon over the dev transport (F3), not an SSH master.
    public let connectionController = ConnectionController()
    /// Posts a macOS notification / sound when an agent card flips to `.waiting` (needs the human).
    /// Host-only: iOS notifications are N1. Built lazily (with its banner-click wiring) so a headless
    /// test process — which has no app bundle for `UNUserNotificationCenter.current()` — never
    /// constructs it; the app touches it first on `bootstrap()`.
    private lazy var notifier: AgentNotifier = {
        let n = AgentNotifier()
        n.onSelect = { [weak self] id in self?.selectedId = id }
        return n
    }()
    #endif

    /// No `.noop` default on purpose: every construction site must pass its platform bundle (desktop
    /// `MacPlatform.ui`, iOS `.ios`) so a future macOS call site can't silently no-op clipboard/settings/
    /// focus. Tests pass an explicit spy bundle; `.noop` stays available for those that want it.
    public init(platform: PlatformUI) {
        self.platform = platform
        client = ControlClient(socketPath: Config.socketPath, source: .app, clientId: clientId)
        wireState()
    }

    /// Mirror the client's connection state onto the main actor (drives `connectionState` + `connected`),
    /// and install the reconnect re-assert hook. `onState` fires on EVERY (re)open; `onReconnect` fires
    /// only on a genuine reconnect (drop → re-open), which is where the board must reconcile.
    private func wireState() {
        client.onState = { [weak self] s in
            _Concurrency.Task { @MainActor in
                guard let self else { return }
                let previous = self.connectionState
                self.connectionState = s
                switch s {
                case .live:
                    self.offlineGraceToken &+= 1        // cancel any pending offline-grace
                    self.connected = true
                    // Re-assert push registration on the (re)connected link: the token may have arrived
                    // before we were live, or a tunnel drop rebuilt `client` against a new socket.
                    self.reregisterPushOnConnect()
                case .down:
                    self.offlineGraceToken &+= 1
                    self.connected = false
                case .connecting:
                    break                                // first-connect in progress — not yet offline
                case .retrying:
                    // The link dropped and is retrying. Don't flap offline instantly (a brief blip
                    // usually recovers), but a DEAD daemon retries forever — so after a grace window,
                    // if still retrying, publish offline (#2) instead of showing "connected" indefinitely.
                    // Anchor the grace to the FIRST retrying transition: the reconnect loop re-emits
                    // `.retrying` on every failed attempt (~backoff apart), and restarting the timer each
                    // time would keep pushing it past the outage forever.
                    if previous != .retrying { self.scheduleOfflineIfStillRetrying() }
                }
            }
        }
        // The one "re-assert on reconnect" hook (#1). ControlClient reconnects transparently WITHOUT
        // ending the event stream, so the stream consumer never re-runs `refresh()`; this fires on the
        // reconnect edge to reconcile the board (task list + shell/owner state via `boardSnapshot`).
        client.onReconnect = { [weak self] in
            _Concurrency.Task { @MainActor in
                guard let self else { return }
                self.connected = true
                await self.refresh()
            }
        }
    }

    /// After the offline grace, if the link is STILL retrying (same token — no `.live`/`.down` since),
    /// publish offline so a dead daemon stops reading as connected (#2).
    private func scheduleOfflineIfStillRetrying() {
        offlineGraceToken &+= 1
        let token = offlineGraceToken
        let grace = offlineGrace
        _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: grace)
            guard let self, self.offlineGraceToken == token,
                  self.connectionState == .retrying else { return }
            self.connected = false
        }
    }

    // The desktop terminal accessors (`terminalHost` / `terminalTmuxSocket`) reference App-side types
    // (AgentTerminalView) and so live in `App/BoardModelPlatform.swift` as a `#if os(macOS)` extension.

    public var selected: Task? { tasks.first { $0.id == selectedId } ?? archived.first { $0.id == selectedId } }

    public func cards(in column: Column) -> [Task] {
        tasks.filter { $0.column == column && !$0.archived && $0.origin == .worktree }
             .sorted { $0.order < $1.order }
    }

    /// Non-worktree cards (`.borrowed`/`.scratch`) live in the standalone freeform region, not the
    /// plan/impl/review lifecycle columns. Oldest-first for a stable order.
    public var freeformTasks: [Task] {
        tasks.filter { $0.origin != .worktree && !$0.archived }
             .sorted { $0.createdAt < $1.createdAt }
    }

    /// Other non-archived cards that share this card's worktree (any status). Multiple agents on one
    /// worktree is intentional — keeping them from clobbering each other is the user's job; this just
    /// surfaces the co-located cards. Oldest-first for a stable list.
    public func worktreeSiblings(of task: Task) -> [Task] {
        tasks.filter { $0.cwd == task.cwd && $0.id != task.id
                       && $0.origin == .worktree && task.origin == .worktree }
             .sorted { $0.createdAt < $1.createdAt }
    }

    /// Hover-tooltip text listing the co-located cards (`<shortId>  <title>` per line). Empty when none.
    public func worktreeSiblingsHelp(of task: Task) -> String {
        let sibs = worktreeSiblings(of: task)
        guard !sibs.isEmpty else { return "" }
        return "Also on this worktree:\n" + sibs.map { "\($0.shortId)  \($0.title)" }.joined(separator: "\n")
    }

    /// distinct agents with running/waiting cards (for the MCP chip count).
    public var activeAgentCount: Int {
        Set(tasks.filter { $0.status == .running || $0.status == .waiting }.map(\.agentId)).count
    }

    // MARK: lifecycle

    private var streamStarted = false

    /// Bumped on every `activate()`/`start()`. Stamps the event-stream consumer + `handleStreamEnded`
    /// so a superseded connection's late teardown can't clobber the current one's state (#6, the
    /// activate() stale-teardown race). Also gates the offline-grace timer.
    private var connGeneration = 0

    /// Monotonic token for the "publish offline after a grace window" timer (#2). Bumped whenever the
    /// link reaches `.live` or `.down` (which cancels any in-flight grace). A `.retrying` transition
    /// captures the current token, waits the grace, then flips `connected = false` only if the token is
    /// still current AND the link is still retrying — so a genuinely-dead daemon stops showing as
    /// "connected forever", while a brief blip that recovers within the window never flaps the board.
    private var offlineGraceToken = 0
    /// How long a `.retrying` link may persist before the board is shown offline.
    private let offlineGrace: Duration = .seconds(6)

    /// Launch-time bootstrap. We never install the background daemon implicitly — that's an explicit,
    /// approved step. Flow:
    ///   • daemon already running        → attach (and consider the user onboarded)
    ///   • first run, daemon not running → show the welcome / install screen
    ///   • returning user, daemon down   → stay offline; the banner offers a one-click restart
    public func bootstrap() async {
        #if os(macOS)
        notifier.requestAuthorization()
        #endif
        await activate(connections.active)
    }

    #if os(macOS)
    /// Point the board at a connection: resolve its local socket (spinning the SSH tunnel for a remote),
    /// (re)build the client, then connect + stream. Preserves the local onboarding/daemon-install flow.
    public func activate(_ conn: Connection) async {
        client.close()
        connectionController.deactivate()
        connectionController.onTunnelExit = { [weak self] in
            // The tunnel dropped: respawn the master + reconnect the client to the new forwarded socket.
            _Concurrency.Task { @MainActor in await self?.activate(conn) }
        }
        do {
            let sockPath = try await connectionController.localSocketPath(for: conn)
            client = ControlClient(socketPath: sockPath, source: .app, clientId: clientId)
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
    #else
    /// iOS connection path (F3, reconcile #3). Resolves the dev-transport socket
    /// (`ConnectionSocketResolver` / `ORCH_DEV_SOCKET`), rebuilds `client` against it, re-wires state,
    /// then streams via `start()`. There is no local daemon or SSH master on the phone, so none of the
    /// macOS `connectionController` / `DaemonLifecycle` / onboarding machinery applies — the phone is a
    /// pure client of an already-running daemon reached over the dev transport (Simulator: a direct UDS
    /// at the Mac's absolute socket path; a real device needs T1's SSH-forwarded socket).
    public func activate(_ conn: Connection) async {
        client.close()
        // A `.remote` connection reaches the Mac daemon over SSH (the transport provider builds an
        // `SSHControlTransport` from the shared session). Simulator/dev falls back to the direct-UDS path.
        if let factory = remoteControlTransportProvider?.controlTransportFactory(for: conn) {
            client = ControlClient(transport: factory, source: .app, clientId: clientId)
        } else {
            let sockPath = ConnectionSocketResolver.socketPath(for: conn)
            client = ControlClient(socketPath: sockPath, source: .app, clientId: clientId)
        }
        wireState()
        streamStarted = false
        await start()
    }
    #endif

    /// Switch the active connection (persisted) and re-point the board at it.
    public func switchConnection(_ id: UUID) async {
        connections.activeId = id
        await activate(connections.active)
    }

    /// Connect/Disconnect toggle for the Connections pane.
    public func disconnect() {
        client.close()
        #if os(macOS)
        connectionController.deactivate()
        #endif
    }

    /// The connected daemon's version string (About section), via the `version` RPC. `nil` when offline
    /// or the call fails — the caller shows a placeholder rather than fabricating a value.
    public func daemonVersion() async -> String? {
        struct VersionInfo: Decodable { let version: String }
        return try? await client.call("version").decode(VersionInfo.self).version
    }

    #if os(macOS)
    /// Invoked from the onboarding screen's primary button. Installs + starts the daemon and, on
    /// success, marks onboarding complete and dismisses the welcome screen. Host-only: iOS has no
    /// local daemon to install (F3/N1).
    public func installDaemon() async {
        await ensureDaemonAndStart()
        if connected {
            onboarded = true
            showOnboarding = false
        }
    }

    /// Ensure the background daemon is installed/running, then connect and start streaming. This is
    /// the user-approved path (button / banner) — it may install the LaunchAgent on first use.
    public func ensureDaemonAndStart() async {
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
    #endif

    public func start() async {
        // Stamp this activation so a superseded connection's late stream teardown can't clobber us (#6).
        connGeneration &+= 1
        let gen = connGeneration
        // Retry briefly — the daemon may still be binding its socket right after launch. `connectAsync`
        // runs the (possibly slow SSH) first open OFF the @MainActor (#8), so an unreachable Mac never
        // freezes the UI during this loop.
        connected = false
        for _ in 0..<25 {
            do { try await client.connectAsync(); connected = true; break }
            catch { try? await _Concurrency.Task.sleep(for: .milliseconds(200)) }
        }
        guard gen == connGeneration else { return }   // a newer activate() superseded this one
        guard connected else { return }
        // Subscribe FIRST, then snapshot (#5): the daemon registers us as a subscriber before we read the
        // board, so an event racing the snapshot is either reflected in it or delivered live (apply is
        // idempotent) — no startup gap. The stream persists across transport reconnects (ControlClient
        // never ends it on a drop); `refresh()` is re-run on the reconnect edge by `onReconnect`, not by
        // re-subscribing. `streamStarted` guards against double-subscribing within one activation.
        if !streamStarted {
            streamStarted = true
            let stream = client.subscribe()
            _Concurrency.Task { [weak self] in
                for await event in stream {
                    guard let self, self.connGeneration == gen else { break }
                    self.apply(event)
                }
                self?.handleStreamEnded(gen: gen)
            }
        }
        await refresh()
    }

    /// The event stream ended (this client was `close()`d — a transport drop does NOT end it). Surface
    /// offline + re-arm subscription, but only if this is still the current connection: a stale consumer
    /// from a superseded `activate()` must not clobber the fresh connection's state (#6).
    private func handleStreamEnded(gen: Int) {
        guard gen == connGeneration else { return }
        connected = false
        streamStarted = false
    }

    public func refresh() async {
        // One round trip for the whole board (#7): tasks + archived + config + models + agents + every
        // card's shell sessions + owner. Falls back to the individual RPCs if the daemon predates
        // `boardSnapshot` (version skew during an upgrade).
        if let snap = try? await client.boardSnapshot() {
            tasks = snap.tasks
            archived = snap.archived
            config = snap.config
            models = snap.models
            agents = snap.agents
            applyBulkSessions(snap.sessions, activeCards: snap.tasks)
            applyBulkOwners(snap.owners, activeCards: snap.tasks)
            return
        }
        // Legacy fallback: piecemeal calls + the per-card N+1 fan-out.
        if let list = try? await client.call("list", .object([:])).decode([Task].self) {
            tasks = list
            await refreshShellPanels(for: list)
            await refreshAgentOwners(for: list)
        }
        if let arch = try? await client.call("archivedList").decode([Task].self) { archived = arch }
        if let cfg = try? await client.call("getConfig").decode(Config.self) { config = cfg }
        if let ms = try? await client.call("models").decode([AgentModel].self) { models = ms }
        if let ag = try? await client.call("agents").decode([AgentInfo].self) { agents = ag }
    }

    /// Apply the bulk shell-session snapshot from `boardSnapshot` — the batched form of
    /// `refreshShellPanels`: drop stale keys for gone cards, then set each card's panel from its sessions.
    private func applyBulkSessions(_ sessions: [CardSessions], activeCards: [Task]) {
        let activeIds = Set(activeCards.map(\.id))
        var knownIds = shellOpen
        knownIds.formUnion(shellWindows.keys)
        knownIds.formUnion(selectedShell.keys)
        for id in knownIds where !activeIds.contains(id) {
            applyShellPanelState(ShellPanelState(targets: [], previousSelection: nil), for: id)
        }
        for s in sessions {
            applyShellPanelState(ShellPanelState(targets: s.targets, previousSelection: selectedShell[s.id]),
                                 for: s.id)
        }
    }

    /// Apply the bulk owner snapshot from `boardSnapshot` — the batched form of `refreshAgentOwners`.
    private func applyBulkOwners(_ owners: [AgentTerminalOwnerState], activeCards: [Task]) {
        let activeIds = Set(activeCards.map(\.id))
        for id in Array(agentOwners.keys) where !activeIds.contains(id) { agentOwners[id] = nil }
        for state in owners { agentOwners[state.cardId] = state }
    }

    private func refreshShellPanels(for cards: [Task]) async {
        let activeIds = Set(cards.map(\.id))
        var knownIds = shellOpen
        knownIds.formUnion(shellWindows.keys)
        knownIds.formUnion(selectedShell.keys)
        for id in knownIds where !activeIds.contains(id) {
            applyShellPanelState(ShellPanelState(targets: [], previousSelection: nil), for: id)
        }

        for card in cards {
            guard let sessions = await sessions(card.id) else { continue }
            let state = ShellPanelState(targets: sessions.targets, previousSelection: selectedShell[card.id])
            applyShellPanelState(state, for: card.id)
        }
    }

    /// Reconcile the shared per-card shell list from a broadcast `shellsChanged` event so every surface
    /// renders the same set — preserving the current selection when it survives. Internal (not private)
    /// so it can be unit-tested without a live daemon. Events are LIVE-ONLY, so `refreshShellPanels`
    /// still does the one-shot pull on (re)connect.
    func ingestShellsChanged(_ state: ShellWindowsState) {
        applyShellPanelState(ShellPanelState(shells: state.shells, previousSelection: selectedShell[state.cardId]),
                             for: state.cardId)
    }

    private func applyShellPanelState(_ state: ShellPanelState, for id: UUID) {
        if state.isOpen {
            shellWindows[id] = state.windows
            selectedShell[id] = state.selected
            shellOpen.insert(id)
        } else {
            shellWindows[id] = nil
            selectedShell[id] = nil
            shellOpen.remove(id)
        }
    }

    /// Reconcile agent-terminal ownership on (re)connect. Owner events are live-only (not replayed from
    /// the ring), so a client that connects mid-takeover would never learn the phone owns a card without
    /// this query. Mirrors `refreshShellPanels`: drop stale keys for gone cards, then snapshot each
    /// visible card's current owner. After this, the live `agentTerminalOwner` stream keeps it current.
    private func refreshAgentOwners(for cards: [Task]) async {
        let activeIds = Set(cards.map(\.id))
        // Snapshot the keys before mutating — iterating the live `.keys` view while assigning would be a
        // simultaneous-access violation.
        for id in Array(agentOwners.keys) where !activeIds.contains(id) { agentOwners[id] = nil }
        for card in cards {
            if let state = try? await client.agentTerminalOwner(card.id.uuidString) {
                agentOwners[card.id] = state
            }
        }
    }

    /// Apply one live event to the board. Internal (not private) so the dedup/reconcile branches can be
    /// unit-tested without a live daemon — same rationale as `ingestShellsChanged`.
    func apply(_ event: Event) {
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
                // Host-only: the macOS notifier surfaces these as system banners; iOS notifications are N1.
                #if os(macOS)
                if let prev {
                    if prev != .waiting, t.status == .waiting {
                        notifier.notify(t.waitReason == .permission ? .permission : .needsYou, task: t)
                    }
                    if prev != .dead, t.status == .dead {
                        notifier.notify(.died, task: t)
                    }
                }
                #endif
            }
        case .taskRemoved(let id):
            tasks.removeAll { $0.id == id }
            archived.removeAll { $0.id == id }
            if selectedId == id { selectedId = nil }
            if archiveConfirm == id { archiveConfirm = nil }
            // Reap per-card shell state so it doesn't accumulate for the process's lifetime.
            shellOpen.remove(id); shellWindows[id] = nil; selectedShell[id] = nil
        case .activity(let item):
            // Dedup by id (#3): the daemon replays its whole activity ring to EVERY `subscribe`, so each
            // reconnect (which re-subscribes) would otherwise re-insert up to 200 items the board already
            // has — duplicate `Identifiable` ids crash/scramble `ForEach`. Cheap: the feed is capped at 200.
            guard !activity.contains(where: { $0.id == item.id }) else { break }
            activity.insert(item, at: 0)
            if activity.count > 200 { activity.removeLast(activity.count - 200) }
        case .agentTerminalOwner(let state):
            // Live owner flip from the daemon. Store the whole snapshot (it carries `owner` + `stale`);
            // the render/acquire decisions read the owner kind out of it. Events are LIVE-ONLY (not ring-
            // replayed), so `refreshAgentOwners` reconciles current ownership on every (re)connect.
            agentOwners[state.cardId] = state
        case .shellsChanged(let s):
            // Live shell open/close from ANY surface (this client, another desktop, or the phone).
            ingestShellsChanged(s)
        }
    }

    // MARK: actions

    /// Refresh the Spawn sheet's daemon-backed repo/dir candidates. The daemon enumerates its own disk
    /// (the phone can't). Best-effort: on failure the sheet still has its card-derived suggestions.
    public func refreshSpawnTargets() async {
        guard let t = try? await client.spawnRepos() else { return }
        spawnRepoCandidates = t.repos
        spawnDirCandidates = t.dirs
    }

    /// Local git branches for a repo, most-recent first (lazy, on repo selection). Empty on failure so
    /// the branch picker degrades to card-derived suggestions + free-text branch creation.
    public func spawnBranches(forRepo repo: String) async -> [String] {
        (try? await client.spawnBranches(repo: repo)) ?? []
    }

    /// List a directory's children for the Spawn sheet's remote directory browser. `path` nil/empty →
    /// the root listing (browse roots). Returns `nil` on failure (e.g. an escaping path) so the browser
    /// can surface an error / stay put rather than crash.
    public func listDir(path: String?) async -> DirListing? {
        try? await client.listDir(path: path)
    }

    /// Spawn a card. Returns the created `Task` on success (so a caller — e.g. the phone's spawn sheet —
    /// can act on the new card id, such as auto-owning its terminal), or `nil` on failure. Callers that
    /// don't need it can ignore the result.
    @discardableResult
    public func spawn(prompt: String, repo: String, branch: String, model: String?, startIn: StartIn,
               agent: String? = nil,
               cwd: String? = nil, access: CardAccess = .readWrite, scratch: Bool = false) async -> Task? {
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
            return t
        } catch { toast("Spawn failed", sub: "\(error)", color: .red); return nil }
    }

    public func move(_ id: UUID, to col: Column) async {
        guard tasks.first(where: { $0.id == id })?.origin == .worktree else {
            return
        }
        _ = try? await client.call("move", .object(["ref": .string(id.uuidString), "col": .string(col.rawValue)]))
    }
    public func archive(_ id: UUID) async {
        _ = try? await client.call("archive", .object(["ref": .string(id.uuidString)]))
        if selectedId == id { selectedId = nil }
        toast("Archived", sub: nil)
    }
    /// Reopen a Done card: the daemon recreates its worktree + resumes the agent; we bring the card back
    /// onto the board, select it (so the live inspector opens), and close the Done popover.
    public func reopen(_ id: UUID) async {
        do {
            let t = try await client.call("reopen", .object(["ref": .string(id.uuidString)])).decode(Task.self)
            apply(.taskUpserted(t))   // off the Done list onto the board immediately; the stream is idempotent
            selectedId = t.id
            showDone = false
            toast("Reopened “\(t.title)”", sub: nil)
        } catch { toast("Reopen failed", sub: "\(error)", color: .red) }
    }
    public func send(_ id: UUID, _ message: String) async {
        _ = try? await client.call("send", .object(["ref": .string(id.uuidString), "message": .string(message)]))
    }

    /// Register this device for push (N1): hand the APNs device token + the current notification-pref
    /// snapshot to the daemon over the shared `client`, so it can push attention alerts while the phone is
    /// backgrounded. Call after `registerForRemoteNotifications` yields a token, and again whenever a
    /// notification pref changes (a re-register replaces the prior entry). Best-effort — a failed
    /// registration just means no push until the next attempt; the in-app Needs You queue still works.
    public func registerForPush(token: String) async {
        // Retain the token FIRST — before the best-effort RPC — so a registration that fails because the
        // link is still connecting (or dropped) is re-attempted on the next `connectionState → .live` edge
        // rather than lost for the whole session (#7).
        pushToken = token
        _ = try? await client.registerDevice(token: token, prefs: NotificationPrefs().snapshot())
    }

    /// Re-assert push registration on the (re)connected link, if we hold a device token (#7). Called on
    /// the `connectionState → .live` edge from `wireState`. Guarded to a no-op when no token is present
    /// (macOS, or before the phone registers). Idempotent with the token-arrival path: the daemon keys
    /// device registrations by `clientId` and REPLACES the prior entry (`DeviceTokenStore.register`), so
    /// the two paths firing close together can't double-register harmfully — the store holds one entry.
    func reregisterPushOnConnect() {
        guard let token = pushToken else { return }
        _Concurrency.Task { await self.registerForPush(token: token) }
    }

    /// Non-attaching read of a card's agent pane (the phone Agent tab's v1 render source, D1). Just a
    /// size-capped `capture-pane` snapshot — no attach, no resize pressure. `nil` on RPC failure so the
    /// caller can keep showing the last good frame. `clientId` stays private to the shared model.
    public func captureAgentPane(_ id: UUID, window: String = "agent") async -> CaptureResult? {
        try? await client.capture(id.uuidString, window: window)
    }

    /// Send a constrained key chord to a card's agent window (the Agent tab's steer-bar key affordances,
    /// D2). Live keystrokes with no implicit Enter — distinct from `send`, which *queues* a message to the
    /// inbox drained at turn-end. Best-effort (swallows RPC errors): a dropped keystroke on a flaky link
    /// is recoverable by tapping again, and the steer bar shouldn't error-toast on every miss.
    public func sendKeysToAgent(_ id: UUID, _ chord: [KeyToken], window: String = "agent") async {
        try? await client.sendKeys(ref: id.uuidString, chord, window: window)
    }

    /// Inbox editor: list a card's pending messages (empty on any error).
    public func inboxPeek(_ id: UUID) async -> [InboxMessage] {
        (try? await client.call("inbox", .object(["ref": .string(id.uuidString)]))
            .decode([InboxMessage].self)) ?? []
    }
    /// Inbox editor: edit one queued message's text.
    public func inboxEdit(_ id: UUID, messageId: UUID, text: String) async {
        _ = try? await client.call("inbox-edit", .object(["ref": .string(id.uuidString),
            "id": .string(messageId.uuidString), "text": .string(text)]))
    }
    /// Inbox editor: remove one queued message.
    public func inboxRemove(_ id: UUID, messageId: UUID) async {
        _ = try? await client.call("inbox-remove", .object(["ref": .string(id.uuidString),
            "id": .string(messageId.uuidString)]))
    }
    /// Inbox editor: reorder a card's queued messages (full new order).
    public func inboxReorder(_ id: UUID, orderedIds: [UUID]) async {
        _ = try? await client.call("inbox-reorder", .object(["ref": .string(id.uuidString),
            "ids": .array(orderedIds.map { .string($0.uuidString) })]))
    }

    /// Read-only trust check for the spawn sheet's freeform trust indicator (T1's ledger via the daemon).
    public func trustState(path: String) async -> Bool {
        guard let r = try? await client.call("trustState", .object(["path": .string(path)])) else { return false }
        return r["trusted"]?.boolValue ?? false
    }

    /// Grant a human's trust for a borrowed directory (the T2 grant), so the freeform card can run
    /// read-write. The app is a human surface — the user clicking "Trust this directory" in the spawn
    /// sheet *is* the human gate the daemon's `SurfaceGrantResolver` requires for an `.app` source, so
    /// this succeeds without any further prompt. Returns whether the directory is now trusted; toasts on
    /// failure (a denial can only happen if the resolver policy changes under us).
    public func trust(path: String) async -> Bool {
        do {
            let r = try await client.call("trust", .object(["path": .string(path)]))
            return r["granted"]?.boolValue ?? false
        } catch {
            toast("Couldn't trust directory", sub: "\(error)", color: .red)
            return false
        }
    }
    public func restart(_ id: UUID) async {
        do {
            _ = try await client.call("restart", .object(["ref": .string(id.uuidString)]))
            toast("Started a new session", sub: nil)
        } catch { toast("Couldn't start session", sub: "\(error)", color: .red) }
    }
    public func resume(_ id: UUID) async {
        do { _ = try await client.call("resume", .object(["ref": .string(id.uuidString)])) }
        catch { toast("Resume failed", sub: "\(error)", color: .red) }
    }
    public func openShell(_ id: UUID) async -> String? {
        guard let r = try? await client.call("shell", .object(["ref": .string(id.uuidString)])) else { return nil }
        return r["window"]?.stringValue
    }

    /// Open a new shell window for a card and track it (the one place that mutates shell state).
    public func newShell(_ id: UUID) async {
        if let w = await openShell(id) {
            shellWindows[id, default: []].append(w)
            selectedShell[id] = w
            shellOpen.insert(id)
        }
    }

    /// Open a read-only inspect shell for a card (read-only claude in its worktree) and track its
    /// window like a normal shell tab.
    public func inspect(_ id: UUID) async {
        guard let r = try? await client.call("inspect", .object(["ref": .string(id.uuidString)])),
              let w = r["window"]?.stringValue else { return }
        shellWindows[id, default: []].append(w)
        selectedShell[id] = w
        shellOpen.insert(id)
    }

    /// Close one shell window, dropping it from the daemon and the per-card state. Selects a
    /// neighbouring tab if the closed one was active; hides the strip once the last shell is gone.
    public func closeShell(_ id: UUID, _ window: String) async {
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
    public func sessions(_ id: UUID) async -> CardSessions? {
        try? await client.call("sessions", .object(["ref": .string(id.uuidString)])).decode(CardSessions.self)
    }

    // MARK: - Terminal tab (T2): one-shot exec + phone-owned live shell

    /// Run a one-shot command in the card's worktree (the phone Terminal tab's block-REPL default).
    /// Returns `nil` on transport failure; a non-zero `exitCode` is still a *result*, not a failure.
    public func exec(_ id: UUID, _ cmd: String) async -> ExecResult? {
        try? await client.call("exec", .object(["ref": .string(id.uuidString), "cmd": .string(cmd)]))
            .decode(ExecResult.self)
    }

    /// This install's deterministic phone-owned shell window name. Deterministic (derived from the
    /// persistent client id) so a reconnect — even after an app relaunch — reuses the *same* window
    /// rather than leaking a fresh one (design §"Reconnect churn"). `phone-`-prefixed so it is visibly
    /// distinct from the desktop's `shell-N` windows and never collides with them.
    public var phoneShellWindow: String { "phone-" + clientId.prefix(8) }

    /// Open (idempotently) this card's phone-owned live shell window and return its full tmux target.
    /// Reuses the window on every call, so re-attaching does not spawn a second window. `nil` on failure.
    public func openPhoneShell(_ id: UUID) async -> TmuxTarget? {
        let win = phoneShellWindow
        guard let r = try? await client.call("shell", .object(["ref": .string(id.uuidString),
                                                               "window": .string(win)])),
              let session = r["session"]?.stringValue,
              let window = r["window"]?.stringValue else { return nil }
        let socket = r["socket"]?.stringValue ?? Config.tmuxSocket
        return TmuxTarget(socket: socket, session: session, window: window, kind: .shell,
                          target: "\(session):\(window)",
                          attach: "tmux -L \(socket) attach -t \(session):\(window)")
    }

    /// Reap this card's phone-owned shell window (leave/detach). Leak-safe: kills the window and its
    /// grouped view session on the daemon.
    public func closePhoneShell(_ id: UUID) async {
        _ = try? await client.call("closeShell", .object(["ref": .string(id.uuidString),
                                                          "window": .string(phoneShellWindow)]))
    }
    /// Rendered git patch for the inspector Diff view (axis 7). App-only internal endpoint — agents
    /// read a diff by running `git diff` in the card's cwd. `""` for non-git cards.
    public func diffText(_ id: UUID, base: String) async -> String {
        (try? await client.call("diffText",
            .object(["ref": .string(id.uuidString), "base": .string(base)])).decode(String.self)) ?? ""
    }
    /// The changed/new markdown notes on a card's branch, each with its current content — the phone's
    /// Notes page (M6) renders these in-app (it has no Obsidian). Read-only; `[]` for non-worktree cards
    /// or on any error. Delegates to M6a's typed `changedNotes` client method (`changedNotes` RPC).
    public func changedNotes(_ id: UUID) async -> [NoteFile] {
        (try? await client.changedNotes(id.uuidString)) ?? []
    }
    public func openInZed(_ id: UUID) async {
        let t = (tasks + archived).first { $0.id == id }
        do {
            _ = try await client.call("openInZed", .object(["ref": .string(id.uuidString)]))
            if let t { toast("Opening changes in Zed…", sub: "\((t.repo as NSString).lastPathComponent) · \(t.branch)") }
        } catch {
            toast("Couldn't open in Zed", sub: "\(error)", color: .red)
        }
    }
    public func openNotes(_ id: UUID) async {
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
    public func saveConfig(_ cfg: Config) async {
        if let saved = try? await client.call("setConfig", JSONValue(encodable: cfg)).decode(Config.self) { config = saved }
    }

    /// Focus a card from an `orchestra://task/<shortId>-<slug>` URL (the registered URL scheme).
    public func select(ref: String) {
        let all = tasks + archived
        if let t = try? resolve(TaskRef(parsing: ref), in: all) { selectedId = t.id }
    }

    // MARK: agent-terminal ownership (PR D5) — desktop consumer of D4's lease

    /// The current owner of a card's agent terminal, or nil when available.
    public func agentOwner(for cardId: UUID) -> AgentTerminalOwner? { agentOwners[cardId]?.owner }

    /// Whether the card's phone owner has gone stale — derived locally (`updatedAt + timeout`) OR taken
    /// from the daemon's own `stale` flag. Drives the placeholder's Force-Retake copy; never affects
    /// mount-vs-placeholder (a stale phone owner is still the placeholder — see the policy).
    public func agentOwnerStale(for cardId: UUID) -> Bool {
        guard let s = agentOwners[cardId], let owner = s.owner else { return false }
        return isAgentTerminalStale(updatedAt: owner.updatedAt, serverStale: s.stale, now: Date())
    }

    /// Whether the inspector should mount the live terminal or the "Taken over by phone" placeholder.
    #if os(macOS)
    public func desktopTerminalDecision(for cardId: UUID) -> DesktopTerminalDecision {
        let owner = agentOwners[cardId]?.owner
        return OrchestraUI.desktopTerminalDecision(ownerKind: owner?.ownerKind,
                                                   isStale: agentOwnerStale(for: cardId))
    }
    #endif

    /// Called when the desktop selects/mounts a card's terminal: claim `desktopOwned` unless the phone
    /// owns it or we already own it (the policy short-circuits both). Fire-and-forget; the authoritative
    /// state comes back as an `agentTerminalOwner` event that re-drives the decision.
    public func acquireDesktopTerminal(_ cardId: UUID) {
        let owner = agentOwners[cardId]?.owner
        guard shouldAcquireDesktopOwnership(ownerKind: owner?.ownerKind, ownerClientId: owner?.clientId,
                                            desktopClientId: clientId) else { return }
        takeOverAgentTerminal(cardId)
    }

    /// Explicit **Retake Terminal** from the placeholder: CAS the lease to this desktop even though the
    /// phone currently owns it. The resulting owner event flips `desktopTerminalDecision` back to `.mount`
    /// and the inspector remounts `AgentTerminalView` automatically. Works for a fresh OR stale phone
    /// owner — `takeOverAgentTerminal` always wins (epoch++), so no guard here.
    public func retakeAgentTerminal(_ cardId: UUID) { takeOverAgentTerminal(cardId) }

    /// Shared CAS: take this card's `agent` lease as *this desktop*. `acquire` gates this behind the
    /// policy (silent, on select); `retake` calls it unconditionally (explicit, from the button).
    private func takeOverAgentTerminal(_ cardId: UUID) {
        let ref = cardId.uuidString
        let me = clientId
        _Concurrency.Task { [weak self] in
            _ = try? await self?.client.takeOverAgentTerminal(ref, clientId: me, kind: .desktop)
        }
    }

    // MARK: agent-terminal ownership (PR T4) — phone consumer of D4's lease

    /// **Take Over Agent Terminal** from the phone: CAS this card's `agent` lease to `.phone` (epoch++),
    /// which the daemon broadcasts so the desktop tears down its `AgentTerminalView` and shows the
    /// placeholder. Returns the `TakeOverResult` — the new state's `epoch` (the phone heartbeats/releases
    /// at it) and the `agent` `TmuxTarget` the takeover surface attaches to via `TmuxAttach(takeover:)`.
    /// `nil` on RPC failure so the caller can surface an error instead of attaching to nothing.
    ///
    /// Mirrors the desktop's private `takeOverAgentTerminal`, but async/returning because the phone needs
    /// the attach target and epoch back; `clientId` stays private to the shared model (never leaked to the
    /// App layer). Optimistically mirrors the returned state into `agentOwners` so `phoneStillHolds…`
    /// reads it immediately, before the live event echoes back.
    public func takeOverAgentTerminalAsPhone(_ cardId: UUID) async -> TakeOverResult? {
        guard let result = try? await client.takeOverAgentTerminal(
            cardId.uuidString, clientId: clientId, kind: .phone) else { return nil }
        agentOwners[cardId] = result.state
        return result
    }

    /// Refresh a phone-held lease (~every 10s while the takeover surface is up). Epoch-guarded on the
    /// daemon: a heartbeat at a stale epoch (a desktop retook, bumping the epoch) is rejected and the
    /// reply reflects the *current* owner — which `phoneStillHolds…` then reads as lost. `nil` on RPC
    /// failure (a transient mobile drop); the surface tolerates a missed beat within the 30s stale window.
    @discardableResult
    public func heartbeatAgentTerminalAsPhone(_ cardId: UUID, epoch: Int) async -> AgentTerminalOwnerState? {
        guard let state = try? await client.heartbeatAgentTerminal(
            cardId.uuidString, clientId: clientId, epoch: epoch) else { return nil }
        agentOwners[cardId] = state
        return state
    }

    /// **Return to Desktop**: release a phone-held lease so the desktop reattaches. Epoch-guarded — a
    /// stale release (after a desktop already retook) is a daemon no-op, so this can't clear a newer owner.
    public func releaseAgentTerminalAsPhone(_ cardId: UUID, epoch: Int) async {
        if let state = try? await client.releaseAgentTerminal(
            cardId.uuidString, clientId: clientId, epoch: epoch) {
            agentOwners[cardId] = state
        }
    }

    /// Whether THIS phone still holds `cardId`'s lease at ≥ `epoch`. Reads the mirrored owner snapshot so
    /// live owner events, heartbeat replies, and reconnect reconcile all feed one decision (via the pure
    /// `phoneTakeoverStatus`). The takeover surface polls this to drop its attach on a desktop retake.
    /// `clientId` stays private — the App layer never needs it, only this yes/no.
    public func phoneStillHoldsAgentTerminal(_ cardId: UUID, epoch: Int) -> Bool {
        phoneTakeoverStatus(myClientId: clientId, myEpoch: epoch,
                            owner: agentOwners[cardId]?.owner) == .holding
    }

    // MARK: keyboard-navigation intents
    // Thin executors the KeyboardController calls; selection movement delegates to the pure
    // BoardNavigator, everything else reuses the existing daemon-backed actions above.

    public func selectMove(_ dir: Direction) {
        selectedId = BoardNavigator.move(tasks, selected: selectedId, dir)
    }
    public func selectEnd(first: Bool) {
        selectedId = BoardNavigator.end(tasks, selected: selectedId, first: first)
    }

    /// Carry the selected card one column left/right (Plan↔Impl↔Review).
    public func carrySelected(_ dir: Direction) {
        guard let id = selectedId, let col = BoardNavigator.columnOf(tasks, id) else { return }
        let order: [Column] = [.plan, .impl, .review]
        guard let ci = order.firstIndex(of: col) else { return }
        let ti = dir == .left ? ci - 1 : ci + 1
        guard ti >= 0, ti < order.count else { return }
        _Concurrency.Task { await move(id, to: order[ti]) }
    }

    /// Descend the keyboard into the selected card's agent terminal (Enter / i). No-op with no
    /// selection so the focus ring never lights on an empty inspector.
    public func enterTerminalZone() {
        guard selectedId != nil else { return }
        focusZone = .terminal
        _ = platform.window.enterTerminalFocus()
    }

    /// A mouse click on a card selects it AND descends into its agent terminal (matching Enter / i),
    /// so the card glow, the inspector ring, and the real first responder all agree after the click.
    /// Falls back to the board zone when the card has no mounted terminal (e.g. a dead agent showing
    /// RecoveryView), so `focusZone` never claims a terminal that isn't there.
    public func selectAndEnterTerminal(_ id: UUID) {
        let sameCard = selectedId == id
        selectedId = id
        focusZone = .terminal
        if sameCard {
            if !platform.window.enterTerminalFocus() { focusZone = .board }   // already mounted → claim now
        } else {
            // Selecting a different card remounts the inspector; its autofocus (focusZone == .terminal)
            // claims focus on mount. Re-assert once that terminal view exists, as a fallback.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self else { return }
                if !self.platform.window.enterTerminalFocus() { self.focusZone = .board }
            }
        }
    }

    public func archiveSelected() { if let id = selectedId { _Concurrency.Task { await archive(id) } } }

    /// The keyboard `a` path: don't archive immediately — raise the confirm dialog. Archive is
    /// effectively permanent, and a bare `a` is too easy to fire when focus isn't where you think.
    public func requestArchiveSelected() { if let id = selectedId { archiveConfirm = id } }
    /// ⏎ in the confirm dialog: perform the archive we were holding.
    public func confirmArchive() { if let id = archiveConfirm { archiveConfirm = nil; _Concurrency.Task { await archive(id) } } }
    /// esc / ⌘W in the confirm dialog: back out, archive nothing.
    public func cancelArchive() { archiveConfirm = nil }
    /// A card's title by id (searches board + archived), for confirm-dialog copy. "" if unknown.
    public func cardTitle(_ id: UUID) -> String { (tasks + archived).first { $0.id == id }?.title ?? "" }
    public func openZedSelected() { if let id = selectedId { _Concurrency.Task { await openInZed(id) } } }
    public func openNotesSelected() { if let id = selectedId { _Concurrency.Task { await openNotes(id) } } }

    /// Yank a reference to the selected card to the pasteboard (chat link / tmux target / path).
    public func copySelected(_ target: CopyTarget) {
        guard let t = selected else { return }
        let s: String
        switch target {
        case .chatLink: s = t.ref()
        case .tmux:     s = "\(t.tmuxSession):agent"
        case .path:     s = t.cwd
        }
        platform.clipboard.copy(s)
        toast("Copied", sub: s)
    }

    /// Jump to a region: select the first card of a column / freeform, or open a popover / settings.
    public func goTo(_ target: GoTarget) {
        switch target {
        case .plan:     selectedId = BoardNavigator.columnCards(tasks, .plan).first?.id
        case .impl:     selectedId = BoardNavigator.columnCards(tasks, .impl).first?.id
        case .review:   selectedId = BoardNavigator.columnCards(tasks, .review).first?.id
        case .freeform: selectedId = freeformTasks.first?.id; focusZone = .board
        case .activity: showActivity = true
        case .done:     showDone = true
        case .settings: platform.opener.openSettings()
        }
    }

    /// Cmd-W / Esc "close the frontmost thing," peeling most-transient-first.
    public func closeFrontmost() {
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
            platform.window.resignInputFocus()
            return
        }
        // On the board with a card open → close the inspector. Archiving is the `a` verb only, never
        // Esc — now that "board + selection" is the resting state, Esc-to-archive would be a footgun.
        if selectedId != nil { selectedId = nil }
    }

    // MARK: search / hints / resize / collapse

    /// Every visible card in navigation order: Plan → Impl → Review columns, then the freeform dock.
    public var orderedVisibleCards: [Task] {
        BoardNavigator.columnCards(tasks, .plan)
            + BoardNavigator.columnCards(tasks, .impl)
            + BoardNavigator.columnCards(tasks, .review)
            + freeformTasks
    }

    /// Ids of cards matching the active `/` query (title / branch / repo substring, case-insensitive).
    public var searchMatchIds: [UUID] {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespaces).lowercased(), !q.isEmpty else { return [] }
        return orderedVisibleCards.filter {
            $0.title.lowercased().contains(q) || $0.branch.lowercased().contains(q)
                || (($0.repo as NSString).lastPathComponent).lowercased().contains(q)
        }.map(\.id)
    }
    /// True when a search is active and this card matches (drives the dim of non-matches).
    public func isSearchMatch(_ t: Task) -> Bool {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return true }
        return searchMatchIds.contains(t.id)
    }
    /// A search filter is active (a non-empty committed query).
    public var searchActive: Bool {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespaces) else { return false }
        return !q.isEmpty
    }
    public func searchNext() { cycleMatch(+1) }
    public func searchPrev() { cycleMatch(-1) }
    private func cycleMatch(_ step: Int) {
        let ids = searchMatchIds
        guard !ids.isEmpty else { return }
        let cur = selectedId.flatMap { ids.firstIndex(of: $0) }
        let next = cur.map { ($0 + step + ids.count) % ids.count } ?? 0
        selectedId = ids[next]
    }

    // f link-hints: assign a short label to every visible card; the controller matches typed keys.
    private static let hintAlphabet = Array("asdfghjklqwertyuiopzxcvbnm")
    public func beginHint() {
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
    public func endHint() { hintActive = false; hintLabels = [:] }
    /// The card whose hint label exactly equals `typed`, if any.
    public func hintTarget(_ typed: String) -> UUID? { hintLabels.first { $0.value == typed }?.key }

    /// Grow/shrink the focused pane's movable edge (Ctrl-Shift-hjkl), writing the same @AppStorage the
    /// drag handles use so the views update live.
    public func resizeFocusedPane(_ dir: Direction) {
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
    public func toggleCollapseFocused() {
        let key = (focusZone == .shell || focusZone == .terminal) ? "shellMinimized" : "freeformCollapsed"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    // MARK: command palette (:)

    @Published public var paletteQuery = ""
    @Published public var paletteIndex = 0

    public struct PaletteCommand: Identifiable {
        public let id = UUID(); public let title: String; public let keys: String; public let run: () -> Void
    }

    public func openPalette() { paletteQuery = ""; paletteIndex = 0; showPalette = true }

    /// The full command catalogue (label · shortcut · action). Rebuilt each access; closures capture
    /// `self` weakly-enough (transient values) to avoid a retained cycle.
    public func paletteCommands() -> [PaletteCommand] {
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
    public var filteredPaletteCommands: [PaletteCommand] {
        let q = paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return paletteCommands() }
        return paletteCommands().filter { fuzzySubsequence(q, $0.title.lowercased()) }
    }

    public func paletteMove(_ delta: Int) {
        let n = filteredPaletteCommands.count
        guard n > 0 else { paletteIndex = 0; return }
        paletteIndex = (paletteIndex + delta + n) % n
    }
    public func runPaletteSelection() {
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

    public func toast(_ title: String, sub: String?, color: Toast.ToastColor = .green) {
        let t = Toast(title: title, sub: sub, color: color)
        toasts.append(t)
        _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .milliseconds(4200))
            self?.toasts.removeAll { $0.id == t.id }
        }
    }
}
