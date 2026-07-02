import SwiftUI
import OrchestraCore

/// Read-only in-app diff for a card (axis 7 — code review on the board). Renders the daemon's
/// difftastic/git ANSI output as colored monospaced text, with a working/branch(/parent) baseline
/// toggle. Refreshes on card selection + baseline change; "Open in Zed" for the full changes. Editing
/// stays Zed's job.
struct DiffInspectorView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task
    /// Headless-snapshot seed (ORCH_SNAPSHOT_DIFF): canned ANSI shown verbatim instead of calling the
    /// daemon, so the shipping view renders faithfully with no control socket. nil in production.
    var preview: String? = nil

    @State private var base: DiffBase = .branch
    @State private var text = ""
    @State private var loading = true

    init(task: Task, preview: String? = nil) {
        self.task = task
        self.preview = preview
        // Seed synchronously so a headless ImageRenderer snapshot (which never runs `.task`) still
        // shows the diff; production leaves preview nil and loads via the daemon in `.task`.
        _text = State(initialValue: preview ?? "")
        _loading = State(initialValue: preview == nil)
    }

    /// `.parent` is only offered once the card carries a parent branch (stacked-branches sets it).
    private var baselines: [DiffBase] {
        task.parentBranch != nil ? [.working, .branch, .parent] : [.working, .branch]
    }
    private var reloadKey: String { "\(task.id.uuidString)-\(base.rawValue)" }

    var body: some View {
        VStack(spacing: 0) {
            baselineBar
            Rectangle().fill(theme.hair).frame(height: 0.5)
            content
        }
        .background(theme.termBg)
        .task(id: reloadKey) { await load() }
    }

    private var baselineBar: some View {
        HStack(spacing: 8) {
            if preview == nil {
                Picker("", selection: $base) {
                    ForEach(baselines, id: \.self) { Text(label($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                // Snapshot-only: a native segmented Picker won't render in ImageRenderer, so draw a
                // faithful faux-segmented control for the headless screenshot.
                HStack(spacing: 0) {
                    ForEach(baselines, id: \.self) { b in
                        Text(label(b))
                            .font(F.ui(11, .medium))
                            .foregroundColor(b == base ? theme.text : theme.text2)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(b == base ? theme.card : Color.clear)
                    }
                }
                .background(theme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Spacer(minLength: 6)
            if !text.isEmpty {
                Button { _Concurrency.Task { await model.openInZed(task.id) } } label: {
                    Text("Open in Zed").font(F.ui(11, .medium)).foregroundColor(theme.text2)
                }
                .buttonStyle(.plain)
                .help("Open the full changes in Zed")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if loading {
            centered { ProgressView().controlSize(.small) }
        } else if text.isEmpty {
            centered {
                VStack(spacing: 6) {
                    Image(systemName: task.origin == .worktree ? "checkmark.circle" : "minus.circle")
                        .font(F.ui(20)).foregroundStyle(theme.text3)
                    Text(task.origin == .worktree ? "No changes on this baseline" : "No diff for this card")
                        .font(F.ui(12)).foregroundStyle(theme.text3)
                }
            }
        } else if preview != nil {
            // Snapshot-only: ImageRenderer can't lay out a ScrollView's children, so render the diff
            // text in a plain container at the top.
            diffText.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView([.vertical, .horizontal]) { diffText }
        }
    }

    private var diffText: some View {
        Text(ANSIText.attributed(text, base: theme.term, size: 11.5))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }

    private func label(_ b: DiffBase) -> String {
        switch b {
        case .working: return "Working"
        case .branch:  return "Branch"
        case .parent:  return "Parent"
        }
    }

    private func load() async {
        if let preview { text = preview; loading = false; return }
        loading = true
        text = await model.diffText(task.id, base: base.rawValue)
        loading = false
    }

    @ViewBuilder private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
