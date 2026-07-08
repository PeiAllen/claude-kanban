import SwiftUI
import UIKit
import OrchestraKit
import OrchestraUI

/// The **Terminal** tab (design §3, phone-agent-terminal UX §"The Terminal tab — a block REPL, with an
/// opt-in live mode"). Two independent surfaces, toggled by `TerminalSession.mode`:
///
///  - **Block REPL (default).** A "Run a command…" field runs a one-shot command in the worktree via the
///    `exec` RPC and appends a **copyable output block** — a notebook of blocks. No PTY, no tmux, no
///    sizing fight with the desktop. Each command is an *independent* one-shot: no persistent shell, so
///    `cd`/env don't carry between blocks. Covers `git status` / `npm test` / `ls` / `rg` / one-shot `tail`.
///  - **Attach live shell (opt-in).** A live SwiftTerm PTY (T1's `IOSTerminalView`, via the injected
///    `TerminalHost`) attached to a **phone-owned** `shell` window — a deterministic `phone-<client>`
///    identity that reconnects idempotently (never spawns a fresh window) and is reaped only on Detach.
///    This is the only place the phone runs a real, stateful terminal; per-window tmux sizes are
///    independent, so the desktop's windows are untouched.
///
/// **Persistence.** The tab's state — which mode you're in, the notebook history + running one-shots, and
/// the live-shell attach — lives in a per-card `TerminalSession` held by the app-level `TerminalSessionStore`,
/// NOT in this view's `@State`. So switching tabs (Agent/Diff/…) or leaving and returning to the card no
/// longer resets anything: you land back on the surface you left, the notebook is intact, and the live
/// shell is still attached on the daemon. **Detach** kills the live shell; **Clear** empties the notebook.
struct TerminalTab: View {
    let task: Task
    @EnvironmentObject private var sessions: TerminalSessionStore

    var body: some View {
        // Resolve (lazily creating) this card's persistent session from the app-level store, then hand it to
        // the content view. Because the session lives in the store — not in `@State` here — it survives this
        // view being torn down on a tab switch or on leaving/returning to the card.
        TerminalTabContent(task: task, session: sessions.session(for: task.id))
    }
}

private struct TerminalTabContent: View {
    let task: Task
    @ObservedObject var session: TerminalSession
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        Group {
            switch session.mode {
            case .blocks: BlockREPLView(task: task, session: session)
            case .live:   LiveShellView(task: task, session: session)
            }
        }
        .background(theme.termBg)
    }
}

// MARK: - Persisted per-card session + store

/// Which surface the Terminal tab is showing for a card. Part of the persisted session, so returning to the
/// tab lands you on the surface you left.
enum TerminalMode { case blocks, live }

/// One card's Terminal-tab state, held above the navigation stack so it outlives the views that render it.
/// Holds BOTH surfaces at once — the block-REPL notebook AND the live-shell attach — because they persist
/// in different senses: the notebook is a history of completed one-shots (no live process), while the live
/// shell is a real tmux window that stays alive on the daemon until Detach. Both survive here regardless of
/// which one `mode` is currently displaying.
@MainActor
final class TerminalSession: ObservableObject {
    @Published var mode: TerminalMode

    // Block REPL (one-shot notebook).
    @Published var blocks: [ExecBlock] = []
    @Published var commandDraft = ""
    @Published var running = false

    // Live shell.
    @Published var liveTarget: TmuxTarget?    // this phone's OWN shell attach target (nil ⇒ detached)
    @Published var selectMode = false         // Select toggle (native text selection vs TUI mouse)
    @Published var selectedRibbon: String?    // which ribbon tab is showing (phone vs a desktop shell)

    init(mode: TerminalMode) { self.mode = mode }

    /// Headless-screenshot hook (mirrors `ORCH_DEV_*`): `ORCH_DEV_TERMINAL_MODE=live` starts a fresh session
    /// in live-shell mode so a gate can capture it deterministically. Defaults to the block REPL.
    static var initialMode: TerminalMode {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ORCH_DEV_TERMINAL_MODE"] == "live" { return .live }
        #endif
        return .blocks
    }

    /// Run `commandDraft` as a one-shot `exec` and land its output block. The work runs on a detached task
    /// that captures only the session + model — not the view — so it completes and records its result even
    /// if the Terminal tab is torn down (you switched tabs / cards) while the command is in flight. That's
    /// what makes an in-flight one-shot persist alongside the notebook history.
    func run(via model: BoardModel, taskId: UUID) {
        let cmd = commandDraft.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, !running else { return }
        commandDraft = ""
        let block = ExecBlock(command: cmd)
        blocks.append(block)
        let id = block.id
        running = true
        _Concurrency.Task { [weak self] in
            let res = await model.exec(taskId, cmd)
            guard let self else { return }
            defer { self.running = false }
            guard let idx = self.blocks.firstIndex(where: { $0.id == id }) else { return }
            if let res {
                self.blocks[idx].stdout = res.stdout
                self.blocks[idx].stderr = res.stderr
                self.blocks[idx].exitCode = res.exitCode
            } else {
                self.blocks[idx].stderr = "Couldn’t run the command (no response from the daemon)."
                self.blocks[idx].exitCode = -1
            }
        }
    }

    /// Wipe the one-shot notebook (the **Clear** button). Does not touch the live shell.
    func clearNotebook() { blocks.removeAll() }
}

/// App-level owner of per-card `TerminalSession`s, injected at the root (next to `BoardModel`) so sessions
/// outlive card navigation. `sessions` is deliberately NOT `@Published`: each view observes its own
/// `TerminalSession`, so publishing here would needlessly re-render every observer whenever any card's
/// session is first created.
@MainActor
final class TerminalSessionStore: ObservableObject {
    private var sessions: [UUID: TerminalSession] = [:]

    func session(for id: UUID) -> TerminalSession {
        if let s = sessions[id] { return s }
        let s = TerminalSession(mode: TerminalSession.initialMode)
        sessions[id] = s
        return s
    }
}

// MARK: - Block REPL (default)

/// One executed command + its captured output — the copyable unit of the notebook. `exitCode == nil`
/// while the command is still running.
struct ExecBlock: Identifiable {
    let id = UUID()
    let command: String
    var stdout: String = ""
    var stderr: String = ""
    var exitCode: Int32?
    var isRunning: Bool { exitCode == nil }

    /// The whole block as plain text — what the copy button puts on the clipboard.
    var copyText: String {
        var s = "$ \(command)\n"
        if !stdout.isEmpty { s += stdout.hasSuffix("\n") ? stdout : stdout + "\n" }
        if !stderr.isEmpty { s += stderr.hasSuffix("\n") ? stderr : stderr + "\n" }
        return s
    }
}

private struct BlockREPLView: View {
    let task: Task
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    @State private var copiedId: UUID?
    @FocusState private var inputFocused: Bool

    private static let examples = ["git status", "ls -la", "git log --oneline -10"]

    var body: some View {
        VStack(spacing: 0) {
            contextBar
            Divider().overlay(theme.hair)
            notebook
            Divider().overlay(theme.hair)
            inputBar
        }
        .task { await runDemoIfRequested() }
    }

    /// Headless-screenshot hook: `ORCH_DEV_TERMINAL_DEMO=<cmd>` (or `1` ⇒ `git status`) auto-runs one
    /// real command on appear so a gate captures a populated notebook against the isolated daemon.
    private func runDemoIfRequested() async {
        #if DEBUG
        guard session.blocks.isEmpty,
              let demo = ProcessInfo.processInfo.environment["ORCH_DEV_TERMINAL_DEMO"], !demo.isEmpty
        else { return }
        session.commandDraft = demo == "1" ? "git status" : demo
        session.run(via: model, taskId: task.id)
        #endif
    }

    // A slim strip: where commands run + Clear (once the notebook has content) + the opt-in into the live
    // shell (which reads "● Live shell" once a shell is attached in the background).
    private var contextBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.caption2).foregroundStyle(theme.text3)
            Text((task.cwd as NSString).lastPathComponent)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(theme.text2)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            if !session.blocks.isEmpty {
                Button { session.clearNotebook() } label: {
                    Label("Clear", systemImage: "trash").font(.caption.weight(.medium))
                        .foregroundStyle(theme.text2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear notebook")
            }
            attachButton
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    // Enters the live-shell surface. When a shell is already attached in the background (`liveTarget != nil`)
    // this reads as "● Live shell" — you're *resuming* a running shell, not starting one; the shell was never
    // detached, so tapping just switches which surface is visible (no re-attach).
    @ViewBuilder private var attachButton: some View {
        Button { session.mode = .live } label: {
            if session.liveTarget != nil {
                HStack(spacing: 5) {
                    Circle().fill(theme.green.dot).frame(width: 7, height: 7)
                    Text("Live shell").font(.caption.weight(.medium))
                }
                .foregroundStyle(theme.text)
            } else {
                Label("Attach live shell", systemImage: "bolt.horizontal")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.accent)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var notebook: some View {
        if session.blocks.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 10) {
                        ForEach(session.blocks) { blockView($0) }
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(12)
                }
                .onChange(of: session.blocks.count) { _, _ in
                    withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                }
            }
        }
    }
    private let bottomAnchor = "repl-bottom"

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "terminal").font(.system(size: 38)).foregroundStyle(theme.text3)
            Text("Run a command in the worktree").font(.callout).foregroundStyle(theme.text2)
            Text("Each command runs one-shot and its output lands in a copyable block. No live terminal — tap **Attach live shell** for that.")
                .font(.footnote).foregroundStyle(theme.text3)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            HStack(spacing: 8) {
                ForEach(Self.examples, id: \.self) { ex in
                    Button { session.commandDraft = ex; sendCommand() } label: {
                        Text(ex).font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(theme.chip))
                            .foregroundStyle(theme.text2)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func blockView(_ block: ExecBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("$").font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .foregroundStyle(theme.accent)
                Text(block.command).font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(theme.term).textSelection(.enabled)
                Spacer(minLength: 8)
                statusView(block)
            }
            let output = combinedOutput(block)
            if !output.isEmpty {
                Text(output).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(block.stderr.isEmpty ? theme.text2 : theme.term)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.hair, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    @ViewBuilder private func statusView(_ block: ExecBlock) -> some View {
        HStack(spacing: 8) {
            if block.isRunning {
                ProgressView().controlSize(.mini)
            } else if let code = block.exitCode, code != 0 {
                Text("exit \(code)").font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.red.text)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(theme.red.tint))
            }
            if !block.isRunning {
                Button { copy(block) } label: {
                    Image(systemName: copiedId == block.id ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copiedId == block.id ? theme.green.text : theme.text3)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func combinedOutput(_ block: ExecBlock) -> String {
        let out = block.stdout.trimmingCharacters(in: .newlines)
        let err = block.stderr.trimmingCharacters(in: .newlines)
        return [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text("$").font(.system(.body, design: .monospaced)).foregroundStyle(theme.text3)
            TextField("Run a command…", text: $session.commandDraft)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .submitLabel(.send).focused($inputFocused)
                .onSubmit(sendCommand)
            Button(action: sendCommand) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
                    .foregroundStyle(canRun ? theme.accent : theme.text3)
            }
            .buttonStyle(.plain).disabled(!canRun)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(theme.termPrompt)
    }

    private var canRun: Bool {
        !session.commandDraft.trimmingCharacters(in: .whitespaces).isEmpty && !session.running
    }

    private func sendCommand() {
        session.run(via: model, taskId: task.id)
        inputFocused = true
    }

    private func copy(_ block: ExecBlock) {
        UIPasteboard.general.string = block.copyText
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        copiedId = block.id
        _Concurrency.Task {
            try? await _Concurrency.Task.sleep(for: .seconds(1.2))
            if copiedId == block.id { copiedId = nil }
        }
    }
}

// MARK: - Live shell (opt-in)

private struct LiveShellView: View {
    let task: Task
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    @Environment(\.terminalHost) private var terminalHost

    // View-local, recreated on each mount:
    //  - `attaching` gates the "Attaching…" state, only on a FRESH open (no persisted target).
    //  - `sawMyWindow` is the reconcile latch below; it deliberately re-arms per mount so returning to the
    //    tab can't misfire on a broadcast that hasn't re-synced yet (the attach is re-affirmed on appear).
    @State private var attaching = true
    @State private var sawMyWindow = false

    // Imperative handle over the mounted live terminal — reused from the takeover. The live shell has no
    // arming chrome (tapping the terminal raises the keyboard directly), but `control` gives us two things:
    // `armed` tracks whether the keyboard is up (tap-to-arm via `onUserArmed`), and `dismissKeyboard()`
    // resigns first responder so the **Hide keyboard** button can drop the keyboard while the terminal stays
    // visible and swipe-scrollable. Scroll/Select/Detach are untouched — mouse reporting stays off here.
    @StateObject private var control = TerminalControl()

    // The card's full shell set (broadcast from the daemon → shared BoardModel). Both surfaces render
    // the same list; a phone live-attaches only its own `phone-<client>` window (attaching a desktop
    // `shell-N` would resize-fight it — the grouped view session is keyed by window, not client).
    private var windows: [String] { model.shellWindows[task.id] ?? [] }
    private var myWindow: String { model.phoneShellWindow }
    private var selectedWindow: String { session.selectedRibbon ?? myWindow }
    private var isMine: Bool { selectedWindow == myWindow }

    /// The ribbon list — the broadcast set, plus this phone's own window optimistically while its open
    /// RPC is still in flight (so the tab shows immediately instead of flashing in on the echo).
    private var ribbonWindows: [String] {
        var ws = windows
        if (session.liveTarget != nil || attaching), !ws.contains(myWindow) { ws.insert(myWindow, at: 0) }
        return ws
    }

    var body: some View {
        VStack(spacing: 0) {
            ribbon
            Divider().overlay(theme.hair)
            controlBar
            Divider().overlay(theme.hair)
            terminalBody
        }
        .task { await attachIfNeeded() }
        // Reconcile the live attach against the broadcast shell set (TerminalTab #407): once our window has
        // appeared in the shared list, its later DISAPPEARANCE means another surface (the desktop) closed
        // it — so drop the now-dead attach instead of freezing on a terminal whose tmux window is gone. The
        // `sawMyWindow` gate avoids clearing during the optimistic-open window before the first echo lands.
        .onChange(of: windows) { _, ws in
            if ws.contains(myWindow) {
                sawMyWindow = true
            } else if sawMyWindow, session.liveTarget != nil, !attaching {
                session.liveTarget = nil
                sawMyWindow = false
            }
        }
    }

    private var ribbon: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ribbonWindows, id: \.self) { w in
                    let active = w == selectedWindow
                    let mine = w == myWindow
                    Button { session.selectedRibbon = w } label: {
                        HStack(spacing: 4) {
                            Image(systemName: mine ? "iphone" : "desktopcomputer").font(.system(size: 9))
                            Text(w).font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundStyle(active ? theme.text : theme.text2)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(active ? theme.card : theme.chip))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    // Contextual controls: Hide-keyboard (while typing) / Select / Detach for the phone's own live shell; a
    // "runs on desktop" note + Close for a desktop shell (closing from the phone is a legitimate reconcile —
    // it broadcasts back).
    private var controlBar: some View {
        HStack(spacing: 10) {
            if isMine {
                // Leave the live view WITHOUT killing the shell — returns to the notebook while the phone
                // shell stays attached on the daemon (Detach, on the right, is the explicit kill). Since the
                // session persists, the notebook's entry button keeps reading "● Live shell".
                Button { session.mode = .blocks } label: {
                    Label("Notebook", systemImage: "chevron.left").font(.caption.weight(.medium))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                Circle().fill(theme.green.dot).frame(width: 7, height: 7)
                Text("Phone-owned shell").font(.caption.weight(.semibold)).foregroundStyle(theme.text)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                Spacer(minLength: 8)
                // Only while the keyboard is up: drop it (resign first responder) so you can just look at /
                // swipe-scroll the terminal. `control.armed` tracks the soft keyboard via tap-to-arm.
                if control.armed {
                    Button { control.dismissKeyboard() } label: {
                        Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                            .font(.caption.weight(.medium))
                            .labelStyle(.iconOnly)
                            .foregroundStyle(theme.text2)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(theme.chip))
                    .accessibilityLabel("Hide keyboard")
                }
                Button { session.selectMode.toggle() } label: {
                    Label("Select", systemImage: "selection.pin.in.out")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(session.selectMode ? theme.accent : theme.text2)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(session.selectMode ? theme.accent.opacity(0.14) : theme.chip))
                Button(action: detach) {
                    Label("Detach", systemImage: "xmark").font(.caption.weight(.medium))
                        .foregroundStyle(theme.text2)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(theme.chip))
            } else {
                Image(systemName: "desktopcomputer").font(.caption2).foregroundStyle(theme.text3)
                Text("Desktop shell").font(.caption.weight(.semibold)).foregroundStyle(theme.text2)
                Spacer(minLength: 8)
                Button { closeWindow(selectedWindow) } label: {
                    Label("Close", systemImage: "xmark").font(.caption.weight(.medium))
                        .foregroundStyle(theme.text2)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(theme.chip))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder private var terminalBody: some View {
        if !isMine {
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").font(.title).foregroundStyle(theme.text3)
                    Text("Runs on the desktop").font(.callout).foregroundStyle(theme.text2)
                    Text("This shell is owned by the desktop. It’s listed here so both surfaces stay in sync — tap your phone shell to type.")
                        .font(.footnote).foregroundStyle(theme.text3)
                        .multilineTextAlignment(.center).padding(.horizontal, 28)
                }
            }
        } else if let target = session.liveTarget {
            liveTerminal(target: target)
                .background(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if attaching {
            centered { ProgressView("Attaching phone-owned shell…").font(.footnote) }
        } else {
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal.circle").font(.title).foregroundStyle(theme.text3)
                    Text("Couldn’t open the shell").font(.callout).foregroundStyle(theme.text2)
                    Button("Retry") { _Concurrency.Task { await attachIfNeeded() } }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    /// Mount the live terminal, threading `control` when the injected host is the real `IOSTerminalHost` so
    /// the Hide-keyboard button can drop the keyboard. The Noop/preview host has no such overload, so those
    /// paths fall back to the plain control-less attach (they never mount a real terminal anyway).
    @ViewBuilder private func liveTerminal(target: TmuxTarget) -> some View {
        if let iosHost = terminalHost as? IOSTerminalHost {
            iosHost.attach(target: target, selectMode: session.selectMode, control: control)
        } else {
            terminalHost.attach(target: target, selectMode: session.selectMode)
        }
    }

    /// Open (or re-affirm) this card's phone-owned shell. On a FRESH entry (no persisted target) show the
    /// "Attaching…" state while the open RPC runs. On RETURN (target already persisted from a prior visit)
    /// mount the terminal immediately and just re-affirm the window idempotently in the background — the
    /// shell was never detached, so there's no spinner, only the terminal's own inline reconnect.
    private func attachIfNeeded() async {
        if session.liveTarget == nil {
            attaching = true
            session.liveTarget = await model.openPhoneShell(task.id)
            attaching = false
            if session.liveTarget != nil { session.selectedRibbon = myWindow }
        } else {
            attaching = false
            if let refreshed = await model.openPhoneShell(task.id) { session.liveTarget = refreshed }
        }
    }

    /// Explicit kill: reap the phone-owned shell on the daemon, drop the attach, and return to the notebook.
    /// This — not a tab/card switch — is the only thing that ends the live shell.
    private func detach() {
        let id = task.id
        _Concurrency.Task { await model.closePhoneShell(id) }
        session.liveTarget = nil
        session.mode = .blocks
    }

    /// Close another surface's shell from the phone (a valid reconcile). Reselect the phone's own shell.
    private func closeWindow(_ window: String) {
        let id = task.id
        session.selectedRibbon = myWindow
        _Concurrency.Task { await model.closeShell(id, window) }
    }
}
