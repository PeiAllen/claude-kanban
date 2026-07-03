import SwiftUI
import OrchestraCore

/// Read-only in-app diff for a card (axis 7 — code review on the board). Renders the daemon's
/// git ANSI patch output as colored monospaced text, with working/branch(/parent) baseline and
/// unified/split layout toggles. Refreshes on card selection + mode change; "Open in Zed" for the full
/// changes. Editing stays Zed's job.
struct DiffInspectorView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task
    /// Headless-snapshot seed (ORCH_SNAPSHOT_DIFF): canned ANSI shown verbatim instead of calling the
    /// daemon, so the shipping view renders faithfully with no control socket. nil in production.
    var preview: String? = nil

    @State private var base: DiffBase = .branch
    @State private var layout: DiffLayout = .unified
    @State private var text = ""
    @State private var files: [DiffFileSection] = []
    @State private var loading = true
    @State private var collapsedFiles: Set<String> = []

    init(task: Task, preview: String? = nil) {
        self.task = task
        self.preview = preview
        // Seed synchronously so a headless ImageRenderer snapshot (which never runs `.task`) still
        // shows the diff; production leaves preview nil and loads via the daemon in `.task`.
        _text = State(initialValue: preview ?? "")
        _files = State(initialValue: preview.map(DiffFileParser.parse) ?? [])
        _loading = State(initialValue: preview == nil)
    }

    /// `.parent` is only offered once the card carries a parent branch (stacked-branches sets it).
    private var baselines: [DiffBase] {
        task.parentBranch != nil ? [.working, .branch, .parent] : [.working, .branch]
    }
    private var reloadKey: String { "\(task.id.uuidString)-\(base.rawValue)" }
    private var allCollapsed: Bool { !files.isEmpty && files.allSatisfy { collapsedFiles.contains($0.id) } }
    private let splitCellWidth: CGFloat = 360
    private let splitDividerWidth: CGFloat = 0.5

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

                Picker("", selection: $layout) {
                    Text("Unified").tag(DiffLayout.unified)
                    Text("Split").tag(DiffLayout.split)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                // Snapshot-only: a native segmented Picker won't render in ImageRenderer, so draw a
                // faithful faux-segmented control for the headless screenshot.
                fauxSegments(items: baselines.map { (label($0), $0 == base) })
                fauxSegments(items: [(layoutLabel(.unified), layout == .unified),
                                     (layoutLabel(.split), layout == .split)])
            }
            Spacer(minLength: 6)
            if files.count > 1 {
                Button {
                    collapsedFiles = allCollapsed ? [] : Set(files.map(\.id))
                } label: {
                    Image(systemName: allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        .font(F.ui(12, .semibold))
                        .foregroundColor(theme.text2)
                        .frame(width: 24, height: 24)
                        .background(theme.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(allCollapsed ? "Expand all files" : "Collapse all files")
            }
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
            fileStack.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView(.vertical) { fileStack }
        }
    }

    private var fileStack: some View {
        LazyVStack(spacing: 10) {
            ForEach(files) { fileSection($0) }
        }
        .padding(10)
    }

    private func fileSection(_ file: DiffFileSection) -> some View {
        let collapsed = collapsedFiles.contains(file.id)
        return VStack(spacing: 0) {
            Button {
                if collapsed { collapsedFiles.remove(file.id) } else { collapsedFiles.insert(file.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(F.ui(10, .semibold))
                        .frame(width: 12)
                    Image(systemName: "doc.text").font(F.ui(12))
                    Text(file.title)
                        .font(F.ui(12, .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if file.hunks > 0 {
                        Text("\(file.hunks) \(file.hunks == 1 ? "hunk" : "hunks")")
                            .font(F.ui(10, .medium))
                            .foregroundStyle(theme.text3)
                    }
                    if file.additions > 0 {
                        Text("+\(file.additions)").font(F.ui(10, .semibold)).foregroundStyle(theme.green.text)
                    }
                    if file.deletions > 0 {
                        Text("-\(file.deletions)").font(F.ui(10, .semibold)).foregroundStyle(theme.red.text)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(theme.termPrompt)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed {
                Rectangle().fill(theme.hair).frame(height: 0.5)
                if layout == .split {
                    splitDiff(file)
                } else {
                    unifiedDiff(file)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
    }

    private func unifiedDiff(_ file: DiffFileSection) -> some View {
        ScrollView(.horizontal) {
            Text(ANSIText.attributed(file.text, base: theme.term, size: 11.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    private func splitDiff(_ file: DiffFileSection) -> some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(DiffSplitRows.make(file.lines)) { row in
                    if let full = row.full {
                        splitFullRow(full, tone: row.tone)
                    } else {
                        HStack(spacing: 0) {
                            splitCell(row.old, tone: row.old == nil ? .blank : row.tone)
                            Rectangle().fill(theme.hair).frame(width: 0.5)
                            splitCell(row.new, tone: row.new == nil ? .blank : row.tone)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func splitFullRow(_ text: String, tone: DiffTone) -> some View {
        Text(ANSIText.attributed(text, base: theme.term, size: 11))
            .textSelection(.enabled)
            .frame(width: splitCellWidth * 2 + splitDividerWidth, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(tone.color(theme))
    }

    private func splitCell(_ text: String?, tone: DiffTone) -> some View {
        Text(ANSIText.attributed(text ?? " ", base: text == nil ? theme.text3 : theme.term, size: 11))
            .textSelection(.enabled)
            .frame(width: splitCellWidth, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 1.5)
            .background(tone.color(theme))
    }

    private func label(_ b: DiffBase) -> String {
        switch b {
        case .working: return "Working"
        case .branch:  return "Branch"
        case .parent:  return "Parent"
        }
    }

    private func layoutLabel(_ l: DiffLayout) -> String {
        switch l {
        case .unified: return "Unified"
        case .split:   return "Split"
        }
    }

    private func load() async {
        if let preview {
            text = preview
            files = DiffFileParser.parse(preview)
            loading = false
            return
        }
        loading = true
        text = await model.diffText(task.id, base: base.rawValue)
        files = DiffFileParser.parse(text)
        loading = false
    }

    @ViewBuilder private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fauxSegments(items: [(String, Bool)]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item.0)
                    .font(F.ui(11, .medium))
                    .foregroundColor(item.1 ? theme.text : theme.text2)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(item.1 ? theme.card : Color.clear)
            }
        }
        .background(theme.chip)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private enum DiffLayout: String {
    case unified, split
}

private extension DiffTone {
    func color(_ theme: Theme) -> Color {
        switch self {
        case .blank:   return theme.termBg
        case .context: return Color.clear
        case .header:  return theme.chip
        case .hunk:    return theme.accent.opacity(theme.dark ? 0.16 : 0.10)
        case .change:  return theme.termPrompt
        }
    }
}
