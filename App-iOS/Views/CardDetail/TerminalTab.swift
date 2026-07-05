import SwiftUI
import UIKit
import OrchestraKit
import OrchestraUI

/// The **Terminal** tab (design §3, phone-agent-terminal UX §"The Terminal tab — a block REPL, with an
/// opt-in live mode"). Two modes:
///
///  - **Block REPL (default).** A "Run a command…" field runs a one-shot command in the worktree via the
///    `exec` RPC and appends a **copyable output block** — a notebook of blocks. No PTY, no tmux, no
///    sizing fight with the desktop. Covers `git status` / `npm test` / `ls` / `rg` / one-shot `tail`.
///  - **Attach live shell (opt-in).** A live SwiftTerm PTY (T1's `IOSTerminalView`, via the injected
///    `TerminalHost`) attached to a **phone-owned** `shell` window — a deterministic `phone-<client>`
///    identity that reconnects idempotently (never spawns a fresh window) and is reaped on Detach. This
///    is the only place the phone runs a real terminal; per-window tmux sizes are independent, so the
///    desktop's windows are untouched.
struct TerminalTab: View {
    let task: Task
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    private enum Mode { case blocks, live }
    @State private var mode: Mode = TerminalTab.initialMode

    /// Headless-screenshot hook (mirrors `ORCH_DEV_*`): `ORCH_DEV_TERMINAL_MODE=live` lands the tab in
    /// live-shell mode so a gate can capture it deterministically. Defaults to the block REPL.
    private static var initialMode: Mode {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ORCH_DEV_TERMINAL_MODE"] == "live" { return .live }
        #endif
        return .blocks
    }

    var body: some View {
        Group {
            switch mode {
            case .blocks: BlockREPLView(task: task, onAttach: { mode = .live })
            case .live:   LiveShellView(task: task, onDetach: { mode = .blocks })
            }
        }
        .background(theme.termBg)
    }
}

// MARK: - Block REPL (default)

/// One executed command + its captured output — the copyable unit of the notebook. `exitCode == nil`
/// while the command is still running.
private struct ExecBlock: Identifiable {
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
    let onAttach: () -> Void
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    @State private var command = ""
    @State private var blocks: [ExecBlock] = []
    @State private var running = false
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
        guard blocks.isEmpty,
              let demo = ProcessInfo.processInfo.environment["ORCH_DEV_TERMINAL_DEMO"], !demo.isEmpty
        else { return }
        command = demo == "1" ? "git status" : demo
        run()
        #endif
    }

    // A slim strip: where commands run + the opt-in into the live shell.
    private var contextBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.caption2).foregroundStyle(theme.text3)
            Text((task.cwd as NSString).lastPathComponent)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(theme.text2)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            Button(action: onAttach) {
                Label("Attach live shell", systemImage: "bolt.horizontal")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain).foregroundStyle(theme.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    @ViewBuilder private var notebook: some View {
        if blocks.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 10) {
                        ForEach(blocks) { blockView($0) }
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(12)
                }
                .onChange(of: blocks.count) { _, _ in
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
                    Button { command = ex; run() } label: {
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
            TextField("Run a command…", text: $command)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .submitLabel(.send).focused($inputFocused)
                .onSubmit(run)
            Button(action: run) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
                    .foregroundStyle(canRun ? theme.accent : theme.text3)
            }
            .buttonStyle(.plain).disabled(!canRun)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(theme.termPrompt)
    }

    private var canRun: Bool {
        !command.trimmingCharacters(in: .whitespaces).isEmpty && !running
    }

    private func run() {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, !running else { return }
        command = ""
        let block = ExecBlock(command: cmd)
        blocks.append(block)
        let id = block.id
        running = true
        inputFocused = true
        _Concurrency.Task {
            let res = await model.exec(task.id, cmd)
            guard let idx = blocks.firstIndex(where: { $0.id == id }) else { running = false; return }
            if let res {
                blocks[idx].stdout = res.stdout
                blocks[idx].stderr = res.stderr
                blocks[idx].exitCode = res.exitCode
            } else {
                blocks[idx].stderr = "Couldn’t run the command (no response from the daemon)."
                blocks[idx].exitCode = -1
            }
            running = false
        }
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
    let onDetach: () -> Void
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    @Environment(\.terminalHost) private var terminalHost

    @State private var target: TmuxTarget?
    @State private var attaching = true
    @State private var selectMode = false

    var body: some View {
        VStack(spacing: 0) {
            ownerBar
            Divider().overlay(theme.hair)
            terminalBody
        }
        .task { await attach() }
    }

    private var ownerBar: some View {
        HStack(spacing: 10) {
            Circle().fill(theme.green.dot).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text("Phone-owned shell").font(.caption.weight(.semibold)).foregroundStyle(theme.text)
                Text(target?.window ?? model.phoneShellWindow)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.text3)
            }
            Spacer(minLength: 8)
            Button {
                selectMode.toggle()
            } label: {
                Label("Select", systemImage: "selection.pin.in.out")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(selectMode ? theme.accent : theme.text2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(selectMode ? theme.accent.opacity(0.14) : theme.chip))
            Button(action: detach) {
                Label("Detach", systemImage: "xmark").font(.caption.weight(.medium))
                    .foregroundStyle(theme.text2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(theme.chip))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder private var terminalBody: some View {
        if let target {
            terminalHost.attach(target: target, selectMode: selectMode)
                .background(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if attaching {
            centered { ProgressView("Attaching phone-owned shell…").font(.footnote) }
        } else {
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal.circle").font(.title).foregroundStyle(theme.text3)
                    Text("Couldn’t open the shell").font(.callout).foregroundStyle(theme.text2)
                    Button("Retry") { _Concurrency.Task { await attach() } }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func attach() async {
        attaching = true
        target = await model.openPhoneShell(task.id)
        attaching = false
    }

    private func detach() {
        let id = task.id
        _Concurrency.Task { await model.closePhoneShell(id) }
        onDetach()
    }

    @ViewBuilder private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
