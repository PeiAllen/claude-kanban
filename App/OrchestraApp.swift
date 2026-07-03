import SwiftUI
import AppKit
import OrchestraCore

@main
struct OrchestraApp: App {
    @StateObject private var model = BoardModel()
    /// The app-wide keyboard router — installed once when the window appears.
    @State private var keyboard: KeyboardController? = nil

    var body: some Scene {
        Window("Orchestra · Personal", id: "board") {
            ContentView()
                .environmentObject(model)
                .environment(\.theme, Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent))
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            theme.winBg.ignoresSafeArea()
            WindowConfigurator(model: model)

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

            // First-run welcome / daemon install — covers the whole window.
            if model.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.showOnboarding)
        .animation(.easeOut(duration: 0.18), value: model.showSpawn)
        .animation(.easeOut(duration: 0.15), value: model.showHelp)
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
                 status: .done, initialPrompt: title, archived: true,
                 updatedAt: Date(timeIntervalSinceNow: -ago))
        }
        return [
            mk("Fix passthrough statusLine timeout", repo: "/Users/allen/code/orchestra",
               branch: "fix/statusline-timeout", agent: "claude-code", model: "claude-opus-4-8", ago: 1800),
            mk("Add done-popover session info", repo: "/Users/allen/code/orchestra",
               branch: "feat/done-information", agent: "claude-code", model: "claude-sonnet-4-6", ago: 7200),
        ]
    }
    /// The agent catalog for the headless Spawn-sheet screenshot (`ORCH_SHOW=spawn`) — the built-in
    /// adapters mapped to `AgentInfo`, same shape the live `agents` RPC returns. Explicitly typed as
    /// `[any Adapter]` so the heterogeneous literal doesn't stall type inference.
    static var mockAgents: [AgentInfo] {
        let adapters: [any Adapter] = [ClaudeCodeAdapter(), CodexAdapter()]
        return adapters.map { AgentInfo(id: $0.id, name: $0.name, icon: $0.icon, models: $0.models()) }
    }

    /// Visual-check harness for the inspector's shell strip (scripts/orch-ui-shot.sh). Injects one
    /// mock *running* card (so AgentChrome renders, not Recovery) and selects it — no daemon needed,
    /// so it never touches the live app/daemon. `ORCH_SHELLS_N` (default 2) sets how many shell tabs
    /// to open: 0 leaves the "New terminal" button showing, ≥1 swaps in the tab ribbon. The agent /
    /// shell terminals render empty (no tmux behind a mock card) — only the chrome is under test.
    /// `ORCH_SHELL_HEIGHT` overrides the persisted shell-panel height so resize wiring is screenshot-
    /// able at different sizes.
    static func showShells(model: BoardModel) {
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["ORCH_SHELLS_N"] ?? "") ?? 2
        if let h = env["ORCH_SHELL_HEIGHT"], let hv = Double(h) {
            UserDefaults.standard.set(hv, forKey: "shellPanelHeight")
        }
        let mock = Task(title: "Wire shell-panel resize + strip swap",
                        repo: "/Users/allen/code/orchestra", branch: "fix/shells",
                        cwd: "/Users/allen/code/orchestra/.worktrees/fix-shells",
                        model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                        order: 0, status: .running, initialPrompt: "demo")
        model.tasks = [mock]
        model.selectedId = mock.id
        if n > 0 {
            model.shellWindows[mock.id] = (1...n).map { "shell-\($0)" }
            model.selectedShell[mock.id] = "shell-1"
            model.shellOpen.insert(mock.id)
        }
    }

    /// A multi-card mock board (no daemon) that STAYS RUNNING, for driving keyboard-navigation tests:
    /// `ORCH_SHOW=demo`. Cards span all three columns plus a freeform card, so hjkl / g-go-to / hints
    /// have something to move through. The terminals render empty (no tmux behind a mock card).
    static func showDemo(model: BoardModel) {
        func mk(_ title: String, _ branch: String, _ col: Column, _ status: AgentStatus, _ order: Int,
                origin: CardOrigin = .worktree) -> Task {
            Task(title: title, repo: "/Users/allen/code/orchestra", branch: branch,
                 cwd: origin == .worktree ? "/Users/allen/code/orchestra/.worktrees/\(branch)" : "/Users/allen/notes/\(branch)",
                 origin: origin, model: AgentModel(id: "claude-opus-4-8"),
                 startIn: col == .plan ? .plan : .impl, column: col, order: order,
                 status: status, initialPrompt: title)
        }
        model.tasks = [
            mk("Design the keyboard scheme", "feat/keys-design", .plan, .waiting, 0),
            mk("Draft the spec document", "feat/spec", .plan, .running, 1),
            mk("Wire the KeyboardController", "feat/controller", .impl, .running, 0),
            mk("Add the command palette", "feat/palette", .impl, .running, 1),
            mk("Pure BoardNavigator + tests", "feat/navigator", .impl, .waiting, 2),
            mk("Review the focus model", "feat/review", .review, .running, 0),
            mk("Ship the context chip", "feat/chip", .review, .done, 1),
            mk("Scratch: perf notes", "perf-notes", .plan, .running, 0, origin: .borrowed),
        ]
        model.selectedId = model.tasks.first?.id
        // No daemon in this hook → suppress the first-run onboarding cover so the board is visible.
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
        let card = Task(title: "Inbox demo", repo: "/Users/allen/code/orchestra", branch: "demo",
                        cwd: "/Users/allen/code/orchestra/.worktrees/demo",
                        model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                        order: 0, status: .running, initialPrompt: "demo")
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
        var card = Task(title: "Wire the KeyboardController", repo: "/Users/allen/code/orchestra",
                        branch: "feat/controller",
                        cwd: "/Users/allen/code/orchestra/.worktrees/feat/controller",
                        model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                        order: 0, status: .dead,
                        initialPrompt: "Wire the KeyboardController to the command palette and add hjkl navigation across columns.")
        card.deadReason = .sessionVanished
        card.agentSessionId = "mock-session"   // surfaces the "Try resume" button too
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
                        repo: "/Users/allen/code/orchestra", branch: "feat/code-review-on-board",
                        cwd: "/Users/allen/code/orchestra/.worktrees/code-review-on-board",
                        model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                        order: 0, status: .running, initialPrompt: "demo")
        card.diffStat = DiffStat(filesChanged: 6, insertions: 214, deletions: 37)
        let view = DiffInspectorView(task: card, preview: mockDiffANSI)
            .environmentObject(model)
            .environment(\.theme, theme)
            .frame(width: 384, height: 470)
            .background(theme.inspector)
            .preferredColorScheme(model.darkMode ? .dark : .light)
        renderPNG(view, to: path)
    }

    /// Render a few board cards carrying `diffStat`s (and one without → model-name fallback) so the
    /// footer diffstat (`Nf +I −D`, axis 7) is visible. `ORCH_SNAPSHOT_CARDS=/path.png`.
    static func snapshotCards(to path: String, model: BoardModel) {
        if let d = ProcessInfo.processInfo.environment["ORCH_SNAP_DARK"] { model.darkMode = d == "1" }
        let theme = Theme(scheme: model.darkMode ? .dark : .light, accent: model.accent)
        func mk(_ title: String, branch: String, status: AgentStatus, stat: DiffStat?) -> Task {
            var t = Task(title: title, repo: "/Users/allen/code/orchestra", branch: branch,
                         cwd: "/Users/allen/code/orchestra/.worktrees/\(branch)",
                         model: AgentModel(id: "claude-opus-4-8"), startIn: .impl, column: .impl,
                         order: 0, status: status, initialPrompt: title)
            t.diffStat = stat
            return t
        }
        let cards = [
            mk("Wire the footer diffstat into CardView.meta", branch: "feat/footer-stat",
               status: .running, stat: DiffStat(filesChanged: 6, insertions: 214, deletions: 37)),
            mk("Small tweak to the baseline toggle", branch: "fix/baseline",
               status: .waiting, stat: DiffStat(filesChanged: 1, insertions: 3, deletions: 1)),
            mk("Freeform notes card (no git diff)", branch: "scratch",
               status: .running, stat: nil),
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
            if let path = ProcessInfo.processInfo.environment["ORCH_SNAPSHOT_CARDS"] {
                DebugLaunchHook.snapshotCards(to: path, model: model)
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
            case "demo": DebugLaunchHook.showDemo(model: model)
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

/// Static, one-time window setup: pull the SwiftUI content under a transparent full-size titlebar so
/// our toolbar occupies the same band as the traffic lights (the toolbar then lays itself out to line
/// up — no runtime querying or moving of the OS buttons). Also disables move-by-background so the
/// inspector resize handle works. Done from `viewDidMoveToWindow`, where the window already exists.
struct WindowConfigurator: NSViewRepresentable {
    let model: BoardModel
    func makeNSView(context: Context) -> NSView { ConfiguratorView(model: model) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguratorView: NSView {
        let model: BoardModel
        private var installedAccessory = false

        init(model: BoardModel) {
            self.model = model
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

            // Host the interactive controls in a real title-bar accessory. Controls placed in the
            // SwiftUI content can't be clicked in this band: the bar shares the OS title-bar region,
            // whose container view sits ABOVE the content and swallows the mouse-down. A title-bar
            // accessory lives *inside* that container, so its controls receive clicks while the empty
            // middle of the title bar still drags the window.
            if !installedAccessory {
                installedAccessory = true
                let acc = NSTitlebarAccessoryViewController()
                acc.layoutAttribute = .right
                let host = NSHostingView(rootView: ToolbarControls().environmentObject(model))
                let fit = host.fittingSize
                host.frame = NSRect(x: 0, y: 0,
                                    width: max(fit.width, 1),
                                    height: max(fit.height, ToolbarView.height))
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
