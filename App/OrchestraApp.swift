import SwiftUI
import OrchestraUI
import AppKit
import OrchestraCore

@main
struct OrchestraApp: App {
    @StateObject private var model = BoardModel(platform: MacPlatform.ui)
    /// The app-wide keyboard router — installed once when the window appears.
    @State private var keyboard: KeyboardController? = nil
    /// Foreground-reconcile safety net: live board updates are push-only, so a missed event would strand
    /// the board until a restart. `onChange` never fires for the initial `.active` (so no launch
    /// double-refresh with `bootstrap`), only on a genuine background→foreground return.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The "Vim keyboard" setting defaults to on; register it so the plain-object
        // KeyboardController reads `true` before the user ever visits Settings.
        UserDefaults.standard.register(defaults: ["orch_vim_keys": true])
        // Staged previews outlive their panel so `Open with` can hand the file to another app — but they
        // never outlive the app session that made them. Wipe the spool once at launch, before any terminal
        // can resolve a reference.
        TranscriptImagePreviewSpool.wipeAtLaunch()
    }

    var body: some Scene {
        Window("Orchestra · Personal", id: "board") {
            ContentView()
                .environmentObject(model)
                .environment(\.theme, Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent))
                .platformUI()
                .preferredColorScheme(model.darkMode ? .dark : .light)
                .frame(minWidth: 940, minHeight: 580)
                .task { await model.bootstrap() }
                .onAppear {
                    if keyboard == nil {
                        let k = KeyboardController(model: model)
                        k.install()
                        keyboard = k
                    }
                }
                .onOpenURL { url in model.select(ref: url.absoluteString) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { _Concurrency.Task { await model.reconcileIfConnected() } }
                }
                // A card's staged images die with the card, mirroring the daemon dropping its own copy on
                // an archive intent. Keyed on ids rather than the array so a diffstat/telemetry churn on an
                // archived card doesn't re-fire. Sweeping EVERY archived card (not just newly-arrived ones)
                // is deliberate: it is idempotent, costs a no-op removeItem, and self-heals a wipe missed
                // while the app was closed.
                .onChange(of: model.archived.map(\.id)) { _, ids in
                    for id in ids { TranscriptImagePreviewSpool.removeExports(cardId: id) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Standard macOS accelerators (Layer 8) — also surfaced in the menu bar for discoverability.
            // The KeyboardController additionally handles these while a terminal is focused.
            CommandGroup(replacing: .newItem) {
                Button("New Card") { model.spawnDefaultColumn = .plan; model.showSpawn = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Shell") {
                    if let id = model.selectedId { _Concurrency.Task { await model.newShell(id) } }
                }
                .keyboardShortcut("t", modifiers: .command)
                Button("Close") { model.closeFrontmost() }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }

        Settings {
            TabView {
                SettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                ConnectionsSettingsView()
                    .tabItem { Label("Connections", systemImage: "network") }
            }
            .environmentObject(model)
            .environment(\.theme, Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent))
            .platformUI()
        }
    }
}

/// Top-level composition: toolbar over a board + optional inspector, with sheet/popover/toast overlays.
struct ContentView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme

    /// Inspector width, persisted across launches. During a live drag we don't touch this (a
    /// per-frame UserDefaults write + KVO fan-out makes the drag stutter); `dragWidth` holds the
    /// in-flight value and we commit it back here only when the drag ends.
    @AppStorage("inspectorWidth") private var savedInspectorWidth: Double = 392
    /// Non-nil only while the divider is being dragged — the live width that drives layout.
    @State private var dragWidth: Double? = nil

    /// Drives the idle-CPU gate: false while the window is occluded/miniaturized or the app is
    /// backgrounded, which parks every perpetual animation + live clock in the board.
    @StateObject private var activity = WindowActivityMonitor()

    var body: some View {
        ZStack(alignment: .topLeading) {
            theme.winBg.ignoresSafeArea()
            WindowConfigurator(model: model, monitor: activity)

            VStack(spacing: 0) {
                ToolbarView()
                Divider().overlay(theme.hair)
                if !model.connected {
                    OfflineBanner()
                    Divider().overlay(theme.hair)
                }
                GeometryReader { geo in
                    // The board fills the area to the left of the inspector. While the split can
                    // give up room the board just shrinks. Once the inspector is dragged wider than
                    // that — the board has hit its ~690pt minimum (3 columns) — the board stops
                    // shrinking and the inspector slides *over* it instead of shoving the whole row
                    // off-screen.
                    let w = Double(geo.size.width)
                    let h = Double(geo.size.height)
                    let boardMin = 690.0
                    let hasInspector = model.selected != nil
                    let inspectorWidth = dragWidth ?? savedInspectorWidth
                    let split = w - inspectorWidth
                    let boardW = hasInspector ? max(boardMin, split) : w
                    ZStack(alignment: .topLeading) {
                        BoardView()
                            .frame(width: boardW, height: h)
                        if hasInspector {
                            HStack(spacing: 0) {
                                // Allow dragging the inspector out nearly all the way — leave only a
                                // thin board sliver so the divider stays grabbable to pull it back.
                                InspectorResizer(width: inspectorWidth,
                                                 maxWidth: max(360, geo.size.width - 56),
                                                 onChange: { dragWidth = $0 },
                                                 onEnd: { savedInspectorWidth = $0; dragWidth = nil })
                                InspectorView()
                                    .frame(width: inspectorWidth)
                            }
                            .frame(width: w, height: h, alignment: .trailing)
                        }
                    }
                    .frame(width: w, height: h, alignment: .topLeading)
                    .clipped()
                }
                .frame(maxHeight: .infinity)
            }
            // Pull the toolbar up under the (hidden) titlebar so it shares the band with the traffic
            // lights. Without this, the title-bar safe-area inset pushes the toolbar down, leaving an
            // empty strip above it that looks like the old native bar.
            .ignoresSafeArea(.container, edges: .top)

            // Spawn sheet overlay
            if model.showSpawn {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { model.showSpawn = false }
                SpawnSheet()
                    .frame(width: 470)
                    .padding(.top, 62)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // The Done / Activity popovers are anchored to their toolbar buttons via SwiftUI's
            // `.popover` (see ControlsRow) — they're no longer free-floating overlays here.

            // Toasts (bottom-right)
            VStack(alignment: .trailing, spacing: 9) {
                ForEach(model.toasts) { ToastView(toast: $0) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            // `/` card search bar — floats near the top of the board.
            if model.searchQuery != nil {
                SearchBar()
                    .padding(.top, 54)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // `:` command palette.
            if model.showPalette {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { model.showPalette = false }
                CommandPalette()
                    .padding(.top, 96)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }

            // Keyboard-shortcuts reference (?) — overlay like the spawn sheet.
            if model.showHelp {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { model.showHelp = false }
                KeyboardHelpView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
            }

            // Archive confirmation — the keyboard `a` path routes here so an accidental keystroke
            // can't permanently archive a card. ⏎ confirms, esc / ⌘W / click-away cancels.
            if let id = model.archiveConfirm {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { model.cancelArchive() }
                ArchiveConfirmView(cardTitle: model.cardTitle(id))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
            }

            // First-run welcome / daemon install — covers the whole window.
            if model.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.showOnboarding)
        .animation(.easeOut(duration: 0.18), value: model.showSpawn)
        .animation(.easeOut(duration: 0.15), value: model.showHelp)
        .animation(.easeOut(duration: 0.15), value: model.archiveConfirm)
        // The idle-CPU gate for the whole board subtree — parks perpetual animations + live clocks when
        // the window isn't being looked at (see WindowActivityMonitor).
        .environment(\.animationsActive, activity.active)
        .modifier(DebugLaunchHook())
    }
}

/// DEBUG-only automation hook for headless screenshotting: set `ORCH_SHOW=spawn|settings` on launch
/// to auto-open that surface. Compiled out of Release builds entirely.
private struct DebugLaunchHook: ViewModifier {
    #if DEBUG
    @EnvironmentObject var model: BoardModel
    @Environment(\.openSettings) private var openSettings
    #endif

    #if DEBUG
    /// Two fake archived cards so `ORCH_SHOW=done` can screenshot the Done popover headlessly.
    static var mockArchived: [Task] {
        func mk(_ title: String, repo: String, branch: String, agent: String, model: String, ago: TimeInterval) -> Task {
            Task(title: title, repo: repo, branch: branch,
                 cwd: "~/worktrees/\((repo as NSString).lastPathComponent)/\(branch.replacingOccurrences(of: "/", with: "-"))",
                 agentId: agent, model: AgentModel(id: model), startIn: .impl, column: .review, order: 0,
                 phase: .archived(teardownComplete: true), initialPrompt: title, archived: true,
                 updatedAt: Date(timeIntervalSinceNow: -ago))
        }
        return [
            mk("Fix passthrough statusLine timeout", repo: DemoConfig.repoRoot,
               branch: "fix/statusline-timeout", agent: "claude-code", model: "claude-opus-4-8", ago: 1800),
            mk("Add done-popover session info", repo: DemoConfig.repoRoot,
               branch: "feat/done-information", agent: "claude-code", model: "claude-sonnet-5", ago: 7200),
        ]
    }
    /// The agent catalog for the headless Spawn-sheet screenshot (`ORCH_SHOW=spawn`) — the built-in
    /// adapters mapped to `AgentInfo`, same shape the live `agents` RPC returns. Explicitly typed as
    /// `[any Adapter]` so the heterogeneous literal doesn't stall type inference.
    static var mockAgents: [AgentInfo] {
        let adapters: [any Adapter] = [ClaudeCodeAdapter(), CodexAdapter()]
        return adapters.map {
            AgentInfo(id: $0.id, name: $0.name, icon: $0.icon,
                      models: $0.models(), capabilities: $0.capabilities)
        }
    }

    /// Visual-check harness for the inspector's shell strip (scripts/orch-ui-shot.sh). Injects one
    /// mock *running* card (so AgentChrome renders, not Recovery) and selects it — no daemon needed,
    /// so it never touches the live app/daemon. `ORCH_SHELLS_N` (default 2) sets how many shell tabs
    /// to open: 0 leaves the "New terminal" button showing, ≥1 swaps in the tab ribbon. The agent /
    /// shell terminals render empty (no tmux behind a mock card) — only the chrome is under test.
    /// `ORCH_TREE` (stale | restack | merge-requested | stalled | in-sync) gives the mock a lineage
    /// state so the `TreeBadge` on the card's L1 quiet cluster and beside the branch in the terminal
    /// header renders;
    /// `ORCH_BEHIND` sets the `↓N` count. Sizes that live in preferences — the shell-panel height, the
    /// inspector width — are NOT set here: the harness passes them as `-shellPanelHeight`/
    /// `-inspectorWidth` launch arguments, because a `UserDefaults` write from this hook persists into
    /// the human's live app domain (the isolated $HOME does not cover preferences).
    /// `ORCH_SHOW=image`: pop the transcript image preview over a mock card's inspector with a synthetic
    /// payload, so the popover's chrome can be screenshotted headlessly (no daemon, no published image).
    /// The loader is the only fake — the popover, its theming, and its zoom are the real ones.
    @MainActor
    static func showTranscriptImage(model: BoardModel) {
        showShells(model: model)
        let referenceID = UUID()
        let cardId = model.tasks.first?.id ?? UUID()
        let payload = TranscriptImagePayload(
            reference: TranscriptImageReference(
                id: referenceID, cardId: cardId, sessionEpoch: 1,
                caption: ProcessInfo.processInfo.environment["ORCH_IMAGE_CAPTION"]
                    ?? "throughput-after-the-cache-fix",
                mimeType: "image/png",
                filename: "\(referenceID.uuidString.lowercased()).png"),
            dataBase64: sampleImagePNG().base64EncodedString())
        // Let the board render first so the preview opens over a real app, as it would in use.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            imagePresenter.show(referenceID: referenceID) { _ in payload }
        }
    }

    private static let imagePresenter = TranscriptImagePreviewPresenter()

    /// Colour bands + a label: enough structure to show fit-scale and the image surface's chrome.
    private static func sampleImagePNG() -> Data {
        let size = NSSize(width: 1400, height: 900)
        let image = NSImage(size: size)
        image.lockFocus()
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemGreen, .systemBlue, .systemPurple]
        for (i, color) in colors.enumerated() {
            color.setFill()
            NSRect(x: CGFloat(i) * size.width / 5, y: 0, width: size.width / 5, height: size.height).fill()
        }
        let style = NSMutableParagraphStyle(); style.alignment = .center
        "ORCHESTRA".draw(in: NSRect(x: 0, y: 390, width: size.width, height: 130), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 96), .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }

    static func showShells(model: BoardModel) {
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["ORCH_SHELLS_N"] ?? "") ?? 2
        // The shell-panel height used to be set here with `UserDefaults.standard.set`, which PERSISTED
        // it into the human's live `com.orchestra.app` domain — the isolated $HOME the harness launches
        // under does not isolate preferences (cfprefsd keys them per-UID). The harness now passes
        // `-shellPanelHeight <pt>` on the command line instead: the NSUserDefaults argument domain
        // outranks the persistent one for this process and is never written to disk.
        var mock = Task(title: "Wire shell-panel resize + strip swap",
                        repo: DemoConfig.repoRoot, branch: "fix/shells",
                        cwd: "\(DemoConfig.repoRoot)/.worktrees/fix-shells",
                        model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                        order: 0, phase: .live(.running), ctxPct: 62, initialPrompt: "demo")
        // A branch diffstat the daemon would have computed, so the card's L1 quiet cluster and the shared
        // Agent|Diff header both have something to render (they share the `k files · +N −M` formatting).
        mock.diffStat = DiffStat(filesChanged: 7, insertions: 214, deletions: 38)
        // A lineage state so `TreeBadge` has something to render. `stalled` deliberately keeps a live
        // `stale` underneath, since the flag is supposed to outrank the state. Unknown values abort
        // rather than defaulting: this hook exists to show WHICH glyph renders.
        if let want = env["ORCH_TREE"] {
            mock.parentBranch = "feat/branch-tree"
            switch want {
            case "stale":           mock.treeStat = TreeStat(state: .stale,
                                                             behind: Int(env["ORCH_BEHIND"] ?? "") ?? 3)
            case "restack":         mock.treeStat = TreeStat(state: .restackNeeded)
            case "merge-requested": mock.treeStat = TreeStat(state: .mergeRequested)
            case "stalled":         mock.treeStat = TreeStat(state: .stale, behind: 2, nudges: 3,
                                                             mergeStalled: true)
            case "in-sync":         mock.treeStat = TreeStat(state: .inSync)
            default: fatalError("ORCH_TREE=\(want) is not a tree state — use "
                                + "stale | restack | merge-requested | stalled | in-sync")
            }
        }
        model.tasks = [mock]
        model.selectedId = mock.id
        // ORCH_INSPECTOR=diff opens the Diff pane instead of the agent terminal — the shared header
        // keeps the diffstat visible there, while the tree badge stays with the Agent tab's branch.
        if env["ORCH_INSPECTOR"] == "diff" { model.inspectorMode = .diff }
        // No daemon in this hook → suppress the first-run onboarding cover so the inspector is visible.
        model.onboarded = true
        model.showOnboarding = false
        if n > 0 {
            model.shellWindows[mock.id] = (1...n).map { "shell-\($0)" }
            model.selectedShell[mock.id] = "shell-1"
            // `shellOpen` is derived from `shellWindows` — setting the windows above is sufficient.
        }
        // ORCH_FOCUS=terminal|shell descends the keyboard into the terminal box so its accent focus
        // ring can be screenshotted (board zone = no ring; terminal/shell zone = ring).
        if let f = env["ORCH_FOCUS"] {
            model.focusZone = (f == "shell") ? .shell : .terminal
        }
    }

    /// `ORCH_SHOW=takeover`: a mock running card whose agent terminal is owned by a phone, so the
    /// inspector renders the "Taken over by phone" placeholder headlessly (no daemon). `ORCH_STALE=1`
    /// seeds a STALE phone owner to screenshot the Force Retake variant.
    static func showTakeover(model: BoardModel) {
        let mock = Task(title: "Wire desktop unmount + phone-takeover placeholder",
                        repo: "/Users/allen/code/orchestra", branch: "mobile/d5-desktop-unmount",
                        cwd: "/Users/allen/code/orchestra/.worktrees/d5",
                        model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                        order: 0, phase: .live(.running), ctxPct: 40, initialPrompt: "demo")
        model.tasks = [mock]
        model.selectedId = mock.id
        // No daemon in this hook → suppress the first-run onboarding cover so the inspector is visible.
        model.onboarded = true
        model.showOnboarding = false
        let stale = ProcessInfo.processInfo.environment["ORCH_STALE"] == "1"
        // A stale owner also gets an old `updatedAt` so the desktop's local staleness derivation agrees
        // with the server flag (both paths converge on Force Retake).
        let updatedAt = stale ? Date(timeIntervalSinceNow: -120) : Date()
        let owner = AgentTerminalOwner(ownerKind: .phone, clientId: "phone-demo", epoch: 1,
                                       cardId: mock.id, window: "agent", updatedAt: updatedAt)
        model.agentOwners[mock.id] = AgentTerminalOwnerState(
            ref: mock.id.uuidString, cardId: mock.id, window: "agent",
            owner: owner, epoch: 1, stale: stale)
    }

    /// A multi-card mock board (no daemon) that STAYS RUNNING, for driving keyboard-navigation tests:
    /// `ORCH_SHOW=demo`. Cards span all three columns plus a freeform card, so hjkl / g-go-to / hints
    /// have something to move through. The terminals render empty (no tmux behind a mock card).
    static func showDemo(model: BoardModel) {
        func mk(_ title: String, _ branch: String, _ col: Column, _ phase: Phase, _ order: Int,
                origin: CardOrigin = .worktree) -> Task {
            Task(title: title, repo: DemoConfig.repoRoot, branch: branch,
                 cwd: origin == .worktree ? "\(DemoConfig.repoRoot)/.worktrees/\(branch)" : "\(DemoConfig.notesRoot)/\(branch)",
                 origin: origin, model: AgentModel(id: "claude-opus-4-8"),
                 startIn: col == .plan ? .plan : .impl, column: col, order: order,
                 phase: phase, initialPrompt: title)
        }
        model.tasks = [
            mk("Design the keyboard scheme", "feat/keys-design", .plan, .live(.waiting(.humanTurn)), 0),
            mk("Draft the spec document", "feat/spec", .plan, .live(.running), 1),
            mk("Wire the KeyboardController", "feat/controller", .impl, .live(.running), 0),
            mk("Add the command palette", "feat/palette", .impl, .live(.running), 1),
            mk("Pure BoardNavigator + tests", "feat/navigator", .impl, .live(.waiting(.humanTurn)), 2),
            mk("Review the focus model", "feat/review", .review, .live(.running), 0),
            mk("Ship the context chip", "feat/chip", .review, .live(.waiting(.humanTurn)), 1),
            mk("Scratch: perf notes", "perf-notes", .plan, .live(.running), 0, origin: .borrowed),
        ]
        model.selectedId = model.tasks.first?.id
        // No daemon in this hook → suppress the first-run onboarding cover so the board is visible.
        model.onboarded = true
        model.showOnboarding = false
    }

    /// `ORCH_SHOW=attached`: a target worktree card with two attached read-only reviewers (one running,
    /// one waiting → the badge reads amber `👁 2`). The reviewers are embedded, so the board shows only
    /// the target carrying the attached-agents badge — the feature at a glance.
    static func showAttached(model: BoardModel) {
        let repo = DemoConfig.repoRoot
        let targetBranch = "feat/attached-agents"
        func mk(_ title: String, _ branch: String, _ phase: Phase, _ order: Int,
                access: CardAccess = .readWrite, parentBranch: String? = nil) -> Task {
            Task(title: title, repo: repo, branch: branch,
                 cwd: "\(repo)/.worktrees/\(branch)", origin: .worktree, access: access,
                 model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                 order: order, phase: phase, initialPrompt: title, parentBranch: parentBranch)
        }
        model.tasks = [
            mk("Attached agents PR", targetBranch, .live(.running), 0),
            mk("Claude review", "review/attached-claude", .live(.running), 1,
               access: .readOnly, parentBranch: targetBranch),
            mk("Codex review", "review/attached-codex", .live(.waiting(.humanTurn)), 2,
               access: .readOnly, parentBranch: targetBranch),
        ]
        model.selectedId = model.tasks.first?.id
        model.onboarded = true
        model.showOnboarding = false
    }

    /// `ORCH_SHOW=subtree`: an orchestrator ROOT with three live lineage children (one per column) plus
    /// merged/planned progress counters, so the board shows the root carrying its L4 subtree line — the
    /// stage-coloured segment bar AND the hover-revealed `drill ›` chip at its trailing edge. The
    /// children embed under the root (non-root descendants), so only the root is a column card.
    static func showSubtree(model: BoardModel) {
        let repo = DemoConfig.repoRoot
        let rootBranch = "feat/board-hierarchy"
        func mk(_ title: String, _ branch: String, _ col: Column, _ phase: Phase, _ order: Int,
                parentBranch: String? = nil, treeStat: TreeStat? = nil) -> Task {
            Task(title: title, repo: repo, branch: branch, cwd: "\(repo)/.worktrees/\(branch)",
                 origin: .worktree, model: AgentModel(id: "claude-opus-4-8"),
                 startIn: col == .plan ? .plan : .impl, column: col, order: order,
                 phase: phase, initialPrompt: title, parentBranch: parentBranch, treeStat: treeStat)
        }
        model.tasks = [
            mk("Board hierarchy: roots, peek & drill", rootBranch, .impl, .live(.running), 0,
               treeStat: TreeStat(state: .inSync, behind: 0, mergedChildren: 2, plannedChildren: 5)),
            mk("Peek rows layout", "feat/peek-row-layout", .impl, .live(.running), 1, parentBranch: rootBranch),
            mk("Drill breadcrumb & banner", "feat/drill-banner", .plan, .live(.waiting(.humanTurn)), 2, parentBranch: rootBranch),
            mk("Scope re-resolution", "feat/scope-resolve", .review, .live(.running), 3, parentBranch: rootBranch),
        ]
        model.selectedId = nil   // leave the root UNSELECTED so its L4 summary (not peek rows) shows
        model.onboarded = true
        model.showOnboarding = false
    }

    /// Render the Done popover (with mock rows) straight to a PNG via `ImageRenderer` — headless,
    /// needs no Screen-Recording permission. Used by `ORCH_SNAPSHOT_DONE=/path.png` for UI review.
    static func snapshotDone(to path: String, model: BoardModel) {
        model.archived = mockArchived
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        // ImageRenderer can't lay out a ScrollView's children, so render the same rows in a plain
        // VStack at the popover's real width — faithful to what DonePopover shows, minus the scroll.
        let rows = VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("DONE").font(F.ui(11, .semibold)).tracking(0.8).foregroundColor(theme.text2)
                Spacer(minLength: 0)
                Text("\(model.archived.count) tasks").font(F.ui(11)).foregroundColor(theme.text2)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            VStack(spacing: 0) {
                ForEach(Array(model.archived.enumerated()), id: \.element.id) { idx, t in
                    ArchiveRow(task: t)
                    if idx < model.archived.count - 1 {
                        Rectangle().fill(theme.hair).frame(height: 0.5)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 10)
        }
        .frame(width: 460)
        .background(theme.panelOpaque)
        let view = rows
            .environmentObject(model)
            .environment(\.theme, theme)
            .preferredColorScheme(model.darkMode ? .dark : .light)
        renderPNG(view, to: path)
    }

    /// Render the populated Inbox editor popover straight to a PNG via `ImageRenderer` — headless,
    /// needs no Screen-Recording permission. Used by `ORCH_SNAPSHOT_INBOX=/path.png` for UI review.
    /// Renders the REAL `InboxEditorView` (via its `preview:` seed), so the screenshot can't drift
    /// from the shipping row layout.
    static func snapshotInbox(to path: String, model: BoardModel) {
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        let card = Task(title: "Inbox demo", repo: DemoConfig.repoRoot, branch: "demo",
                        cwd: "\(DemoConfig.repoRoot)/.worktrees/demo",
                        model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                        order: 0, phase: .live(.running), initialPrompt: "demo")
        let seed = ["charlie", "BRAVO (edited)", "review the auth refactor before merging"]
            .map { InboxMessage(cardId: card.id, text: $0) }
        let view = InboxEditorView(task: card, preview: seed)
            .environmentObject(model)
            .environment(\.theme, theme)
            .background(theme.panelOpaque)
            .preferredColorScheme(model.darkMode ? .dark : .light)
        renderPNG(view, to: path)
    }

    /// Render the dead-card recovery panel straight to a PNG via `ImageRenderer` — headless, needs no
    /// Screen-Recording permission. Used by `ORCH_SNAPSHOT_RECOVERY=/path.png` for UI review. Renders the
    /// REAL `RecoveryView` for a `.dead` task, so the screenshot can't drift from the shipping panel
    /// (including the "Copy prompt" affordance on the "Originally asked:" block).
    static func snapshotRecovery(to path: String, model: BoardModel) {
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        var card = Task(title: "Wire the KeyboardController", repo: DemoConfig.repoRoot,
                        branch: "feat/controller",
                        cwd: "\(DemoConfig.repoRoot)/.worktrees/feat/controller",
                        model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                        order: 0, phase: .dead(.sessionVanished),
                        initialPrompt: "Wire the KeyboardController to the command palette and add hjkl navigation across columns.")
        card.deadReason = .sessionVanished
        card.agentSessionId = "mock-session"   // surfaces the "Try resume" button too
        // The panel's whole claim is "your work is preserved" — give it work to have preserved, so
        // the snapshot covers the diffstat line under the worktree path.
        card.diffStat = DiffStat(filesChanged: 12, insertions: 486, deletions: 91)
        let view = RecoveryView(task: card)
            .environmentObject(model)
            .environment(\.theme, theme)
            .frame(width: 460, height: 560)
            .background(theme.inspector)
            .preferredColorScheme(model.darkMode ? .dark : .light)
        renderPNG(view, to: path)
    }

    /// A representative git-colored (ANSI/SGR) diff for the headless Diff-view snapshot — bold file
    /// headers, a cyan hunk header, red removals + green additions — so `ANSIText`'s parser + the
    /// DiffInspectorView chrome are visible without a daemon.
    static var mockDiffANSI: String {
        let E = "\u{1B}"
        return [
            "\(E)[1mdiff --git a/Sources/OrchestraCore/Diff/GitDiffProvider.swift b/Sources/OrchestraCore/Diff/GitDiffProvider.swift\(E)[m",
            "\(E)[1m--- a/Sources/OrchestraCore/Diff/GitDiffProvider.swift\(E)[m",
            "\(E)[1m+++ b/Sources/OrchestraCore/Diff/GitDiffProvider.swift\(E)[m",
            "\(E)[36m@@ -14,9 +14,11 @@ public struct GitDiffProvider: DiffProvider {\(E)[m",
            "         var files = 0, insertions = 0, deletions = 0",
            "         for line in r.stdout.split(separator: \"\\n\") {",
            "\(E)[31m-            let cols = line.split(separator: \"\\t\")\(E)[m",
            "\(E)[31m-            files += 1\(E)[m",
            "\(E)[32m+            let cols = line.split(separator: \"\\t\", maxSplits: 2, omittingEmptySubsequences: false)\(E)[m",
            "\(E)[32m+            guard cols.count == 3 else { continue }\(E)[m",
            "\(E)[32m+            files += 1   // binary rows count as a changed file, 0/0 lines\(E)[m",
            "             insertions += Int(cols[0]) ?? 0",
            "             deletions += Int(cols[1]) ?? 0",
            "         }",
            "\(E)[36m@@ -30,6 +32,7 @@\(E)[m",
            "         if Proc.toolExists(\"difft\") {",
            "\(E)[32m+            let env = [\"GIT_EXTERNAL_DIFF\": \"difft\", \"DFT_DISPLAY\": \"inline\"]\(E)[m",
            "             return r.stdout",
            "         }",
            "",
            "\(E)[1mdiff --git a/App/Views/DiffInspectorView.swift b/App/Views/DiffInspectorView.swift\(E)[m",
            "\(E)[1m--- a/App/Views/DiffInspectorView.swift\(E)[m",
            "\(E)[1m+++ b/App/Views/DiffInspectorView.swift\(E)[m",
            "\(E)[36m@@ -46,6 +46,11 @@ struct DiffInspectorView: View {\(E)[m",
            "                 .pickerStyle(.segmented)",
            "                 .labelsHidden()",
            "                 .fixedSize()",
            "\(E)[32m+                Picker(\"\", selection: $layout) {\(E)[m",
            "\(E)[32m+                    Text(\"Unified\").tag(DiffLayout.unified)\(E)[m",
            "\(E)[32m+                    Text(\"Split\").tag(DiffLayout.split)\(E)[m",
            "\(E)[32m+                }\(E)[m",
            "\(E)[32m+                .pickerStyle(.segmented)\(E)[m",
            "",
        ].joined(separator: "\n")
    }

    /// Render the real `DiffInspectorView` (with a canned ANSI diff seed) to a PNG — headless, no
    /// daemon, no Screen-Recording permission. `ORCH_SNAPSHOT_DIFF=/path.png`.
    static func snapshotDiff(to path: String, model: BoardModel) {
        if let d = ProcessInfo.processInfo.environment["ORCH_SNAP_DARK"] { model.darkMode = d == "1" }
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        var card = Task(title: "Promote the Zed diff engine into DiffProvider",
                        repo: DemoConfig.repoRoot, branch: "feat/code-review-on-board",
                        cwd: "\(DemoConfig.repoRoot)/.worktrees/code-review-on-board",
                        model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                        order: 0, phase: .live(.running), initialPrompt: "demo")
        card.diffStat = DiffStat(filesChanged: 6, insertions: 214, deletions: 37)
        let split = ProcessInfo.processInfo.environment["ORCH_SNAP_SPLIT"] == "1"
        let view = DiffInspectorView(task: card, preview: mockDiffANSI, split: split)
            .environmentObject(model)
            .environment(\.theme, theme)
            .frame(width: 384, height: 470)
            .background(theme.inspector)
            .preferredColorScheme(model.darkMode ? .dark : .light)
        renderPNG(view, to: path)
    }

    /// Render a few board cards carrying `diffStat`s (and one without) so the quiet-cluster diffstat
    /// (`Nf +I −D`, axis 7) is visible on the L1 strip. `ORCH_SNAPSHOT_CARDS=/path.png`.
    static func snapshotCards(to path: String, model: BoardModel) {
        if let d = ProcessInfo.processInfo.environment["ORCH_SNAP_DARK"] { model.darkMode = d == "1" }
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        func mk(_ title: String, branch: String, phase: Phase, stat: DiffStat?) -> Task {
            var t = Task(title: title, repo: DemoConfig.repoRoot, branch: branch,
                         cwd: "\(DemoConfig.repoRoot)/.worktrees/\(branch)",
                         model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                         order: 0, phase: phase, initialPrompt: title)
            t.diffStat = stat
            return t
        }
        let cards = [
            mk("Wire the branch diffstat into the L1 quiet cluster", branch: "feat/quiet-stat",
               phase: .live(.running), stat: DiffStat(filesChanged: 6, insertions: 214, deletions: 37)),
            mk("Small tweak to the baseline toggle", branch: "fix/baseline",
               phase: .live(.waiting(.humanTurn)), stat: DiffStat(filesChanged: 1, insertions: 3, deletions: 1)),
            mk("Freeform notes card (no git diff)", branch: "scratch",
               phase: .live(.running), stat: nil),
        ]
        let list = VStack(spacing: 10) {
            ForEach(cards, id: \.id) { CardView(task: $0) }
        }
        .padding(14)
        .frame(width: 320)
        .background(theme.colBg)
        let view = list
            .environmentObject(model)
            .environment(\.theme, theme)
            .preferredColorScheme(model.darkMode ? .dark : .light)
        renderPNG(view, to: path)
    }

    /// Render the attached-agents surface headlessly (no daemon, no Screen-Recording): the target card
    /// (selected, so it renders EXPANDED) carrying the amber `👁 2` glance badge, with its two attached
    /// read-only reviewers listed as inline rows (one running + one waiting). `ORCH_SNAPSHOT_ATTACHED`.
    static func snapshotAttached(to path: String, model: BoardModel) {
        if let d = ProcessInfo.processInfo.environment["ORCH_SNAP_DARK"] { model.darkMode = d == "1" }
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        showAttached(model: model)                       // seeds target (selected) + 2 embedded reviewers
        let target = model.tasks[0]
        let view = CardView(task: target)
            .padding(14)
            .frame(width: 320)
            .background(theme.colBg)
            .environmentObject(model)
            .environment(\.theme, theme)
            .preferredColorScheme(model.darkMode ? .dark : .light)
        renderPNG(view, to: path)
    }

    /// Render the slice-2b hierarchy surfaces headlessly (no daemon, no window, no Screen-Recording) —
    /// the board's ScrollView columns can't be laid out by `ImageRenderer`, but the individual card /
    /// banner components can, so this writes three PNGs into `dir` from the REAL `CardView` /
    /// `SubtreeSegments` / `PeekRow` / `DrillHeader`: `23-hier-toplevel` (a root card collapsed → L4
    /// stage segments + eye), `24-hier-peek` (the same root selected → five-zone peek rows replacing L4),
    /// `25-hier-drill` (the drill breadcrumb + banner above the root's direct children). `ORCH_SNAPSHOT_HIER=<dir>`.
    static func snapshotHierarchy(toDir dir: String, model: BoardModel) {
        if let d = ProcessInfo.processInfo.environment["ORCH_SNAP_DARK"] { model.darkMode = d == "1" }
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        showAnatomy(model: model)                       // seeds the fixture incl. live-wake's subtree
        guard let root = model.tasks.first(where: { $0.branch == "feat/live-wake" }) else { return }
        func framed(_ v: some View, width: CGFloat = 440) -> some View {
            v.padding(16).frame(width: width).background(theme.colBg)
                .environmentObject(model).environment(\.theme, theme)
                .preferredColorScheme(model.darkMode ? .dark : .light)
        }
        // 23 — top level: the root card collapsed shows its stage-segment bar + eye.
        model.selectedId = nil
        renderPNG(framed(CardView(task: root)), to: "\(dir)/23-hier-toplevel.png")
        // 24 — peek: selecting the root reveals its subordinates as five-zone rows in place of L4.
        model.selectedId = root.id
        renderPNG(framed(CardView(task: root)), to: "\(dir)/24-hier-peek.png")
        // 24b/24c/24d — the same peek rows squeezed into NARROW cards, exercising every rung of the
        // width-driven squish ladder: the long prompt-titles truncate to one line (never wrap into a tall
        // pill — the bug), and as the row narrows the desc drops, the stage chip collapses word→letter, the
        // diffstat sheds its file count then drops, while the title keeps its first words. 24b is a mid
        // width (word chip + `+I −M` diff); 24d is the TIGHTEST rung that still shows the diff (letter chip
        // + diff coexisting — the pinch where a collision would hide); 24c is the real board floor (letter
        // chip, diff/desc gone, title still readable).
        renderPNG(framed(CardView(task: root), width: 300), to: "\(dir)/24b-hier-peek-narrow.png")
        renderPNG(framed(CardView(task: root), width: 255), to: "\(dir)/24d-hier-peek-pinch.png")
        renderPNG(framed(CardView(task: root), width: 222), to: "\(dir)/24c-hier-peek-floor.png")
        // 25 — drill: the breadcrumb + banner over the root's direct children (the scoped board).
        model.selectedId = nil
        model.drillInto(root.id)
        let kids = model.visibleTasks
        renderPNG(framed(VStack(alignment: .leading, spacing: 10) {
            DrillHeader()
            ForEach(kids) { CardView(task: $0) }
        }, width: 820), to: "\(dir)/25-hier-drill.png")
    }

    // MARK: - Attention (slice 3b) fixtures

    /// Every attention surface on one board (`ORCH_SHOW=attention`), arranged so the SCAN RULE is the
    /// thing you check: solid amber appears only where a human is actually needed, and nowhere else.
    ///
    /// Covers the four states the slice ships — an OWN chip (permission), a stall (time-derived), a
    /// declared question, and a SUBTREE rollup on an ancestor whose child is the one that stopped —
    /// plus two controls that must stay quiet: a healthy running card, and a merge-request into an
    /// OWNED parent, which wears a grey ⏱ and must never amber.
    static func showAttention(model: BoardModel) {
        let repo = DemoConfig.repoRoot

        func mk(_ title: String, _ branch: String, _ col: Column, _ phase: Phase, _ order: Int,
                desc: String = "", diff: DiffStat? = nil, tree: TreeStat? = nil,
                ageMinutes: Double = 4, ctxPct: Double = 0, question: String? = nil,
                access: CardAccess = .readWrite, parentBranch: String? = nil) -> Task {
            var t = Task(title: title, repo: repo, branch: branch,
                         cwd: "\(repo)/.worktrees/\(branch)", access: access,
                         model: AgentModel(id: "claude-opus-4-8"),
                         startIn: col == .plan ? .plan : .impl, column: col, order: order,
                         phase: phase, initialPrompt: title, parentBranch: parentBranch)
            t.desc = desc
            t.diffStat = diff
            t.treeStat = tree
            t.ctxPct = ctxPct
            if let q = question {
                t.pendingQuestion = PendingQuestion(text: q, declaredAt: Date(timeIntervalSinceNow: -600))
            }
            // The stall row is TIME-derived, so the fixture has to age its cards past the threshold for
            // the amber to exist at all.
            t.phaseChangedAt = Date(timeIntervalSinceNow: -ageMinutes * 60)
            t.updatedAt = t.phaseChangedAt
            return t
        }

        // The control: healthy, working, quiet cluster intact — no amber anywhere on it.
        let running = mk("live-wake-delivery", "feat/live-wake", .impl, .live(.running), 0,
                         desc: "Wave 2/4 — lease/claim delivery",
                         diff: DiffStat(filesChanged: 4, insertions: 38, deletions: 9))
        // OWN chip: blocked mid-turn on a tool approval — the hardest block short of death.
        let blocked = mk("pr/wake-endpoint", "pr/wake-endpoint", .impl,
                         .live(.waiting(.permission)), 1, desc: "Wake endpoint + route ladder",
                         diff: DiffStat(filesChanged: 6, insertions: 134, deletions: 28))
        // OWN chip + overflow: a declared question on a card that is also nearly out of context.
        let asking = mk("plan/codex-restart", "plan/codex-restart", .plan,
                        .live(.waiting(.humanTurn)), 0, ageMinutes: 30, ctxPct: 91,
                        question: "squash or rebase the wave?")
        // The quiet control that must NOT amber: merge-requested into a parent a live card owns.
        let owned = mk("pr/child-of-root", "pr/child", .review, .live(.waiting(.humanTurn)), 0,
                       diff: DiffStat(filesChanged: 2, insertions: 21, deletions: 4),
                       tree: TreeStat(state: .mergeRequested), ageMinutes: 90,
                       parentBranch: "feat/orchestrator")
        // The rollup pair: an idle ORCHESTRATOR whose stopped child owns the stall. Leaf attachment
        // means the amber sits on the child and the parent shows "1 needs you" on L4 — one fact, one
        // amber, aggregated once.
        let orchestrator = mk("feat/orchestrator", "feat/orchestrator", .impl,
                              .live(.waiting(.humanTurn)), 2, desc: "Wave C — attention system",
                              tree: TreeStat(state: .inSync, mergedChildren: 2, plannedChildren: 4),
                              ageMinutes: 40)
        let stoppedChild = mk("pr/stopped-child", "pr/stopped", .impl, .live(.waiting(.humanTurn)), 3,
                              diff: DiffStat(filesChanged: 9, insertions: 412, deletions: 96),
                              ageMinutes: 40, parentBranch: "feat/orchestrator")

        // The LONGEST label the chip can carry. It exists in the fixture specifically so the narrow
        // shot proves "never truncates" against the worst case rather than against "permission".
        let drained = mk("feat/wave-b", "feat/wave-b", .impl, .live(.waiting(.humanTurn)), 4,
                         desc: "Wave B — all children merged",
                         tree: TreeStat(state: .inSync, mergedChildren: 4, plannedChildren: 4,
                                        drained: true),
                         ageMinutes: 55)

        model.tasks = [running, blocked, asking, owned, orchestrator, stoppedChild, drained]

        // `ORCH_ATTENTION=peek` selects the orchestrator, which does two things at once: it reveals its
        // subordinates as PEEK ROWS (the only way to see the row action slot — the stopped child's stall
        // label beside the quiet owned-parent child) and it opens the inspector, which squeezes the
        // columns. That squeeze is the real narrow test: `-inspectorWidth` alone changes nothing on a
        // board with no inspector open, so a "narrow" shot without a selection is a no-op.
        if ProcessInfo.processInfo.environment["ORCH_ATTENTION"] == "peek" {
            model.selectedId = orchestrator.id
        }
    }

    // MARK: - Card anatomy (slice 2a) fixtures

    /// Every card state the four-line anatomy has to survive, as one board. Used windowed
    /// (`ORCH_SHOW=anatomy`, to see the ladder bite at real column widths) and headless
    /// (`ORCH_SNAPSHOT_ANATOMY`, for a deterministic gallery). `ORCH_ANATOMY=single-repo` re-homes
    /// every card into one repo, which shuts the source-prefix gate.
    static func showAnatomy(model: BoardModel) {
        let single = ProcessInfo.processInfo.environment["ORCH_ANATOMY"] == "single-repo"
        let repo = DemoConfig.repoRoot
        let other = single ? repo : "\(DemoConfig.repoRoot)-site"

        func mk(_ title: String, _ branch: String, _ col: Column, _ phase: Phase, _ order: Int,
                repo: String = repo, note: String? = nil, desc: String = "",
                diff: DiffStat? = nil, tree: TreeStat? = nil, ageMinutes: Double = 12,
                access: CardAccess = .readWrite, parentBranch: String? = nil,
                origin: CardOrigin = .worktree, cwd: String? = nil) -> Task {
            var t = Task(title: title, repo: origin == .worktree ? repo : "",
                         branch: origin == .worktree ? branch : "",
                         cwd: cwd ?? "\(repo)/.worktrees/\(branch)", origin: origin, access: access,
                         model: AgentModel(id: "claude-opus-4-8"),
                         startIn: col == .plan ? .plan : .impl, column: col, order: order,
                         phase: phase, initialPrompt: title, parentBranch: parentBranch)
            t.note = note
            t.desc = desc
            t.diffStat = diff
            t.treeStat = tree
            // Time-in-state is what the pill renders, so the fixture has to set it explicitly —
            // otherwise every mock card reads "· 0s" and the age half of the pill goes untested.
            t.phaseChangedAt = Date(timeIntervalSinceNow: -ageMinutes * 60)
            return t
        }

        model.tasks = [
            // The full quiet cluster: diffstat + ↓N + model, with a note.
            mk("live-wake-delivery", "feat/live-wake", .impl, .live(.running), 0,
               note: "Wave 2/4 — lease/claim delivery",
               diff: DiffStat(filesChanged: 4, insertions: 38, deletions: 9),
               tree: TreeStat(state: .stale, behind: 3, mergedChildren: 4, plannedChildren: 10),
               ageMinutes: 12),
            // Desc only (the volatile blurb), no note — and a long title that has to wrap.
            mk("fix/the-startup-abort-misclassification-that-marks-cards-dead", "fix/startup-abort",
               .impl, .live(.running), 1, desc: "Reproducing the <1s exit path under a fake clock",
               diff: DiffStat(filesChanged: 12, insertions: 412, deletions: 96), ageMinutes: 47),
            // Neither note nor desc: the ref falls back to the identity line.
            mk("docs-refresh", "chore/docs", .impl, .live(.waiting(.humanTurn)), 2, ageMinutes: 125),
            // Waiting + merge-requested (grey clock, NOT amber).
            mk("plan/spawn-hang", "plan/spawn-hang", .review, .live(.waiting(.humanTurn)), 0,
               note: "Startup-abort misclassification fix",
               diff: DiffStat(filesChanged: 6, insertions: 134, deletions: 28),
               tree: TreeStat(state: .mergeRequested), ageMinutes: 120),
            // Merge-stalled keeps its warning look; restack rides the same one glyph slot.
            mk("pr/wake-endpoint", "pr/wake-endpoint", .review, .live(.waiting(.humanTurn)), 1,
               desc: "Wake endpoint + route ladder",
               tree: TreeStat(state: .stale, behind: 2, nudges: 3, mergeStalled: true), ageMinutes: 21),
            mk("pr/codex-clean-restart", "pr/codex-restart", .plan, .live(.running), 0,
               desc: "Codex clean-restart launch path",
               tree: TreeStat(state: .restackNeeded), ageMinutes: 3),
            // A second repo opens the source-prefix gate (unless ORCH_ANATOMY=single-repo).
            mk("fix/rss-dates", "fix/rss-dates", .plan, .live(.waiting(.humanTurn)), 1, repo: other,
               desc: "Feed dates render a day early in Safari",
               diff: DiffStat(filesChanged: 1, insertions: 22, deletions: 6), ageMinutes: 38),
            // A target with two attached reviewers → the labelled eye on L4.
            mk("feat/attached-agents", "feat/attached", .impl, .live(.running), 3,
               note: "Attached-agents seam", ageMinutes: 8),
            mk("Claude review", "review/attached-claude", .impl, .live(.running), 4,
               access: .readOnly, parentBranch: "feat/attached"),
            mk("Codex review", "review/attached-codex", .impl, .live(.waiting(.humanTurn)), 5,
               access: .readOnly, parentBranch: "feat/attached"),
            // A freeform card: no repo, so it is never repo-prefixed on the board (its dir is inspector-only).
            mk("board-redesign research", "", .plan, .live(.running), 6,
               desc: "Surveying agent-tree UIs", ageMinutes: 4,
               origin: .borrowed, cwd: DemoConfig.notesRoot),
            // live-wake-delivery's SUBTREE (slice 2b hierarchy): four PR children across the macro-phases
            // + two attached wave reviewers, all on feat/live-wake. At the top level they embed (roots
            // only) and the root shows a stage-segment bar + eye; selecting the root reveals them as peek
            // rows; drilling the root scopes the board to just these. (ORCH_ANATOMY=peek/drill below.)
            // Real children carry PROMPT-DERIVED titles — long, wrapping-prone, markdown asterisks and
            // all (the board shows the raw first line of the seed). This is what stresses the peek-row
            // geometry: a long title must truncate to ONE line and leave the fixed-size stage chip its
            // horizontal footprint, never starve it into a vertical pill.
            mk("You are the **D (Codex clean-restart) card** — implement the clean-restart launch path",
               "pr/codex-restart", .plan, .live(.running), 7,
               desc: "Codex clean-restart launch path", ageMinutes: 3, parentBranch: "feat/live-wake"),
            mk("You are a PLANNING card. Produce a **layered** lease/claim delivery core plan for wave 2",
               "pr/lease-claim", .impl, .live(.running), 8,
               desc: "Lease/claim delivery core",
               diff: DiffStat(filesChanged: 8, insertions: 188, deletions: 40), ageMinutes: 47,
               parentBranch: "feat/live-wake"),
            mk("You are the **D (Claude channels) card** — wire MCP channel push into the delivery arm",
               "pr/claude-channels", .impl, .live(.waiting(.permission)), 9,
               desc: "MCP channel push wiring", ageMinutes: 9, parentBranch: "feat/live-wake"),
            mk("You are the **wake-endpoint + route-ladder** PR card for the live-wake-delivery redesign",
               "pr/wake-route", .review, .live(.waiting(.humanTurn)), 10,
               desc: "Wake endpoint + route ladder",
               diff: DiffStat(filesChanged: 6, insertions: 134, deletions: 28), ageMinutes: 21,
               parentBranch: "feat/live-wake"),
            mk("You are the **FINAL PRE-MAIN REVIEW (Opus 4.8)** — review the accumulated wave-2 diff",
               "review/wave2-claude", .impl, .live(.running), 11,
               ageMinutes: 6, access: .readOnly, parentBranch: "feat/live-wake"),
            mk("You are the **FINAL PRE-MAIN REVIEW (Codex Sol)** — review the accumulated wave-2 diff",
               "review/wave2-codex", .impl, .live(.running), 12,
               ageMinutes: 6, access: .readOnly, parentBranch: "feat/live-wake"),
        ]
        model.onboarded = true
        model.showOnboarding = false
        // These hooks run with no daemon, and a running card whose connection is down renders STALE
        // (dimmed to 72%) — correct behaviour, but it would misreport every colour in a fixture whose
        // whole job is to show what the anatomy looks like on a live board.
        model.connectionState = .live
        let liveWake = model.tasks.first { $0.branch == "feat/live-wake" }?.id
        switch ProcessInfo.processInfo.environment["ORCH_ANATOMY"] {
        case "expanded": model.selectedId = model.tasks.first { $0.branch == "feat/attached" }?.id
        case "peek":     model.selectedId = liveWake                       // reveal the root's peek rows
        case "drill":    if let id = liveWake { model.drillInto(id) }      // scope the board to its subtree
        case "drill-selected":                                            // drilled AND the banner is the open card
            if let id = liveWake { model.drillInto(id); model.selectedId = id }
        default:         break
        }
    }

    /// The anatomy gallery, headless: every seeded state as a column of cards at one width.
    /// `ORCH_SNAPSHOT_ANATOMY=/path.png`.
    static func snapshotAnatomy(to path: String, model: BoardModel) {
        if let d = ProcessInfo.processInfo.environment["ORCH_SNAP_DARK"] { model.darkMode = d == "1" }
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        showAnatomy(model: model)
        let cards = model.visibleTasks
        let view = VStack(alignment: .leading, spacing: 8) {
            ForEach(cards, id: \.id) { CardView(task: $0) }
        }
        .frame(width: 320)
        .padding(14)
        .background(theme.colBg)
        .environmentObject(model)
        .environment(\.theme, theme)
        .preferredColorScheme(model.darkMode ? .dark : .light)
        renderPNG(view, to: path)
    }

    /// The squish ladder, headless and deterministic: ONE card rendered at a sweep of widths, each
    /// row labelled, so every rung the ladder actually reaches is visible in a single image.
    /// A fixed handful of widths can silently skip a rung (the treeStat glyph is ~14 pt wide, so
    /// rung 2's window is narrow), which is exactly what a squish test must not do.
    /// `ORCH_SNAPSHOT_LADDER=/path.png`.
    static func snapshotLadder(to path: String, model: BoardModel) {
        if let d = ProcessInfo.processInfo.environment["ORCH_SNAP_DARK"] { model.darkMode = d == "1" }
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        showAnatomy(model: model)
        guard let card = model.tasks.first else { return }
        let widths: [CGFloat] = stride(from: 380, through: 120, by: -20).map { CGFloat($0) }
        let view = VStack(alignment: .leading, spacing: 6) {
            ForEach(widths, id: \.self) { w in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(Int(w))")
                        .font(F.mono(9, .medium)).foregroundStyle(theme.text3)
                        .frame(width: 26, alignment: .trailing)
                    CardView(task: card).frame(width: w)
                }
            }
        }
        .padding(14)
        .background(theme.colBg)
        .environmentObject(model)
        .environment(\.theme, theme)
        .preferredColorScheme(model.darkMode ? .dark : .light)
        renderPNG(view, to: path)
    }

    /// Render the `?` keyboard-help overlay to a PNG via `ImageRenderer` — headless, no daemon, no
    /// Screen-Recording permission. Used by `ORCH_SNAPSHOT_HELP=/path.png` for UI review.
    static func snapshotHelp(to path: String, model: BoardModel) {
        if let d = ProcessInfo.processInfo.environment["ORCH_SNAP_DARK"] { model.darkMode = d == "1" }
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        let view = KeyboardHelpView()
            .environmentObject(model)
            .environment(\.theme, theme)
            .padding(40)
            .background(theme.winBg)
            .preferredColorScheme(model.darkMode ? .dark : .light)
        renderPNG(view, to: path)
    }

    /// Render the `:` command palette to a PNG via `ImageRenderer` — headless. `ORCH_SNAPSHOT_PALETTE`.
    static func snapshotPalette(to path: String, model: BoardModel) {
        if let d = ProcessInfo.processInfo.environment["ORCH_SNAP_DARK"] { model.darkMode = d == "1" }
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        let view = CommandPalette()
            .environmentObject(model)
            .environment(\.theme, theme)
            .padding(40)
            .background(theme.winBg)
            .preferredColorScheme(model.darkMode ? .dark : .light)
        renderPNG(view, to: path)
    }

    /// Render the archive-confirm dialog to a PNG via `ImageRenderer` — headless. Renders the REAL
    /// `ArchiveConfirmView` so the screenshot can't drift from the shipping dialog. `ORCH_SNAPSHOT_ARCHIVE`.
    static func snapshotArchive(to path: String, model: BoardModel) {
        if let d = ProcessInfo.processInfo.environment["ORCH_SNAP_DARK"] { model.darkMode = d == "1" }
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        let view = ArchiveConfirmView(cardTitle: "Wire the KeyboardController to the command palette")
            .environmentObject(model)
            .environment(\.theme, theme)
            .padding(40)
            .background(theme.winBg)
            .preferredColorScheme(model.darkMode ? .dark : .light)
        renderPNG(view, to: path)
    }

    /// Render the REAL `AgentTerminalPlaceholder` ("Taken over by phone") straight to a PNG via
    /// `ImageRenderer` — headless, no daemon, no Screen-Recording permission (works even with the screen
    /// locked, unlike `screencapture`). `ORCH_SNAPSHOT_TAKEOVER=/path.png`; `ORCH_STALE=1` renders the
    /// Force-Retake variant. Reuses `showTakeover` to seed the mock card + phone owner so the snapshot
    /// can't drift from the shipping view.
    static func snapshotTakeover(to path: String, model: BoardModel) {
        if let d = ProcessInfo.processInfo.environment["ORCH_SNAP_DARK"] { model.darkMode = d == "1" }
        showTakeover(model: model)
        guard let task = model.tasks.first else { return }
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        let view = AgentTerminalPlaceholder(task: task)
            .environmentObject(model)
            .environment(\.theme, theme)
            .frame(width: 520, height: 300)
            .background(theme.termBg)
            .preferredColorScheme(model.darkMode ? .dark : .light)
        renderPNG(view, to: path)
    }

    /// Shared ImageRenderer → PNG writer for the snapshot hooks.
    static func renderPNG(_ view: some View, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        content.task {
            if let path = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_TAKEOVER"] {
                DebugLaunchHook.snapshotTakeover(to: path, model: model)
                exit(0)
            }
            if let path = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_DONE"] {
                DebugLaunchHook.snapshotDone(to: path, model: model)
                exit(0)
            }
            if let path = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_INBOX"] {
                DebugLaunchHook.snapshotInbox(to: path, model: model)
                exit(0)
            }
            if let path = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_RECOVERY"] {
                DebugLaunchHook.snapshotRecovery(to: path, model: model)
                exit(0)
            }
            if let path = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_DIFF"] {
                DebugLaunchHook.snapshotDiff(to: path, model: model)
                exit(0)
            }
            if let path = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_HELP"] {
                DebugLaunchHook.snapshotHelp(to: path, model: model)
                exit(0)
            }
            if let path = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_PALETTE"] {
                DebugLaunchHook.snapshotPalette(to: path, model: model)
                exit(0)
            }
            if let path = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_ARCHIVE"] {
                DebugLaunchHook.snapshotArchive(to: path, model: model)
                exit(0)
            }
            if let path = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_CARDS"] {
                DebugLaunchHook.snapshotCards(to: path, model: model)
                exit(0)
            }
            if let path = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_ATTACHED"] {
                DebugLaunchHook.snapshotAttached(to: path, model: model)
                exit(0)
            }
            if let path = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_ANATOMY"] {
                DebugLaunchHook.snapshotAnatomy(to: path, model: model)
                exit(0)
            }
            if let path = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_LADDER"] {
                DebugLaunchHook.snapshotLadder(to: path, model: model)
                exit(0)
            }
            if let dir = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_HIER"] {
                DebugLaunchHook.snapshotHierarchy(toDir: dir, model: model)
                exit(0)
            }
            switch ProcessInfo.processInfo.environment["ORCH_SHOW"] {
            case "spawn":
                // Seed the agent catalog (no daemon in this hook) so the Spawn sheet's agent picker
                // renders — mirrors what the `agents` RPC would return from the live registry.
                model.agents = DebugLaunchHook.mockAgents
                // ORCH_SPAWN_AGENT preselects an agent (screenshots the per-agent model list).
                if let a = ProcessInfo.processInfo.environment["ORCH_SPAWN_AGENT"] {
                    model.config.defaultAgentId = a
                }
                model.showSpawn = true
            case "settings": openSettings()
            case "done":
                model.archived = DebugLaunchHook.mockArchived
                model.showDone = true
            case "shells": DebugLaunchHook.showShells(model: model)
            case "image": DebugLaunchHook.showTranscriptImage(model: model)
            case "takeover": DebugLaunchHook.showTakeover(model: model)
            case "demo": DebugLaunchHook.showDemo(model: model)
            case "attached": DebugLaunchHook.showAttached(model: model)
            case "subtree": DebugLaunchHook.showSubtree(model: model)
            case "anatomy": DebugLaunchHook.showAnatomy(model: model)
            case "attention": DebugLaunchHook.showAttention(model: model)
            default: break
            }
        }
        #else
        content
        #endif
    }
}

/// Shown below the toolbar whenever the control daemon isn't connected, with a one-click start.
struct OfflineBanner: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.connecting ? "arrow.triangle.2.circlepath" : "bolt.slash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.amber.text)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.connecting ? "Starting the Orchestra daemon…" : "Daemon offline")
                    .font(F.ui(12.5, .semibold)).foregroundStyle(theme.text)
                Text("Agents run in a background service. Starting it installs a login-time LaunchAgent so your agents keep running when the app is closed.")
                    .font(F.ui(11)).foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                _Concurrency.Task { await model.ensureDaemonAndStart() }
            } label: {
                Text(model.connecting ? "Starting…" : "Start daemon")
                    .font(F.ui(12, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 13).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(model.connecting)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(theme.amber.tint)
    }
}

/// Draggable divider between the board and the inspector — grab anywhere in the 8px hit strip and
/// drag to resize the inspector (clamped). Persisted width lives on ContentView. The strip is backed
/// by a non-window-draggable AppKit view so the drag resizes instead of moving the whole window.
struct InspectorResizer: View {
    /// Current (live) inspector width — read-only; changes are reported via the closures below.
    var width: Double
    /// Upper bound for the drag — supplied by the parent from the live window width so the inspector
    /// can be pulled out nearly the whole way.
    var maxWidth: Double = 760
    /// Called every drag frame with the new width (parent keeps this in cheap @State).
    var onChange: (Double) -> Void
    /// Called once when the drag ends with the final width (parent persists it).
    var onEnd: (Double) -> Void
    @Environment(\.theme) var theme
    @State private var startWidth: Double?

    private func resolve(_ translation: CGFloat, base: Double) -> Double {
        // Dragging left (negative translation) widens the inspector.
        min(maxWidth, max(320, base - Double(translation)))
    }

    var body: some View {
        theme.hair.frame(width: 0.5)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(NonWindowDraggable())
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(
                // Measure in GLOBAL space: the handle re-lays-out to a new x on every width change,
                // so a .local translation would be measured against a moving origin and jitter.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if startWidth == nil { startWidth = width }
                        onChange(resolve(v.translation.width, base: startWidth ?? width))
                    }
                    .onEnded { v in
                        let base = startWidth ?? width
                        startWidth = nil
                        onEnd(resolve(v.translation.width, base: base))
                    }
            )
    }
}

/// An AppKit view whose region never initiates a window drag, so a SwiftUI gesture on top of it
/// (the resize handle) works even under a full-size-content / movable window.
struct NonWindowDraggable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NoDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class NoDragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

/// An `NSHostingView` for a title-bar accessory whose width tracks its SwiftUI content. The titlebar
/// sizes a `.right` accessory from its view's *frame* (not its intrinsic size) and only re-lays-out
/// on window resize — so a plain hosting view freezes at its install-time width, and when the content
/// later grows (ContextChip BOARD→INSPECTOR/TERMINAL/SHELL, MCP offline→"connected · N agents") the
/// right-aligned row overflows the stale frame and clips on the left. Here we resize our own frame to
/// the content's fitting width whenever the content re-lays-out, then poke the titlebar container to
/// reposition us so the right edge stays pinned to the window edge.
final class AutoWidthHostingView<Content: View>: NSHostingView<Content> {
    override func layout() {
        super.layout()
        let w = fittingSize.width
        guard w > 0, abs(frame.width - w) > 0.5 else { return }
        setFrameSize(NSSize(width: w, height: max(fittingSize.height, ToolbarView.height)))
        // The accessory's superview is the titlebar container; make it re-run its accessory layout so
        // it picks up our new width and re-pins our right edge to the window's trailing edge.
        superview?.needsLayout = true
        superview?.layoutSubtreeIfNeeded()
    }
}

/// Static, one-time window setup: pull the SwiftUI content under a transparent full-size titlebar so
/// our toolbar occupies the same band as the traffic lights (the toolbar then lays itself out to line
/// up — no runtime querying or moving of the OS buttons). Also disables move-by-background so the
/// inspector resize handle works. Done from `viewDidMoveToWindow`, where the window already exists.
/// Tracks whether the board window is actually being looked at, so the idle-CPU gate
/// (`\.animationsActive`) can park the board's perpetual animations + live clocks when it isn't.
///
/// "Being looked at" = the window is on-screen and unobscured (`occlusionState` covers occluded,
/// fully-covered, AND miniaturized) AND the app is the active app. Either failing drops `active` to
/// false, which stops every breathing dot / shimmer / age-clock in the content and the toolbar. Bound to
/// the one board window by `WindowConfigurator` once the window exists.
@MainActor
final class WindowActivityMonitor: ObservableObject {
    @Published private(set) var active = true

    // Mutated only on the main actor (in `bind`); read once in the nonisolated `deinit` after the last
    // reference is gone, so there is no concurrent access — `nonisolated(unsafe)` lets deinit unregister.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private weak var window: NSWindow?

    func bind(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        let nc = NotificationCenter.default
        // Window-scoped: occlusion covers "another window fully covers us" and miniaturize, but the
        // miniaturize/deminiaturize pair is observed too so a restore recomputes even on the rare AppKit
        // build where occlusion doesn't re-fire for it.
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recompute() }
            })
        }
        // App-scoped: backgrounding the app pauses too, even if our window stays fully visible behind
        // another app's — the point is to stop burning CPU while the user is elsewhere.
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recompute() }
            })
        }
        recompute()
    }

    private func recompute() {
        let visible = window?.occlusionState.contains(.visible) ?? true
        active = visible && NSApplication.shared.isActive
    }

    deinit {
        let nc = NotificationCenter.default
        observers.forEach(nc.removeObserver)
    }
}

struct WindowConfigurator: NSViewRepresentable {
    let model: BoardModel
    let monitor: WindowActivityMonitor
    func makeNSView(context: Context) -> NSView { ConfiguratorView(model: model, monitor: monitor) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguratorView: NSView {
        let model: BoardModel
        let monitor: WindowActivityMonitor
        private var installedAccessory = false

        init(model: BoardModel, monitor: WindowActivityMonitor) {
            self.model = model
            self.monitor = monitor
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false

            // Start driving the idle-CPU gate off this window's occlusion/active state.
            monitor.bind(to: window)

            // Host the interactive controls in a real title-bar accessory. Controls placed in the
            // SwiftUI content can't be clicked in this band: the bar shares the OS title-bar region,
            // whose container view sits ABOVE the content and swallows the mouse-down. A title-bar
            // accessory lives *inside* that container, so its controls receive clicks while the empty
            // middle of the title bar still drags the window.
            if !installedAccessory {
                installedAccessory = true
                let acc = NSTitlebarAccessoryViewController()
                acc.layoutAttribute = .right
                // The accessory is a SEPARATE hosting view outside ContentView's environment, so it gets
                // the monitor as its own environmentObject — `ToolbarControls` re-publishes it as
                // `\.animationsActive` so the MCP status dot parks with the rest when occluded.
                let host = AutoWidthHostingView(
                    rootView: ToolbarControls().environmentObject(model).environmentObject(monitor))
                acc.view = host
                window.addTitlebarAccessoryViewController(acc)
            }
        }
    }
}

struct ToastView: View {
    let toast: Toast
    @Environment(\.theme) var theme
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(F.ui(12.5, .semibold)).foregroundStyle(theme.text)
                if let sub = toast.sub { Text(sub).font(F.mono(11)).foregroundStyle(theme.text2) }
            }
        }
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
        .frame(minWidth: 236, maxWidth: 320, alignment: .leading)
        .surface(theme.panelOpaque, corner: 11, hair: theme.hair)
        .shadow(color: Color(r: 20, g: 18, b: 40, a: 0.26), radius: 20, y: 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    var dotColor: Color {
        switch toast.color { case .green: return theme.green.dot; case .blue: return theme.blue.dot; case .red: return theme.red.dot }
    }
}
