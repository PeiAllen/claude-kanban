import SwiftUI
import OrchestraUI
import OrchestraCore

/// Read-only in-app diff for a card (axis 7 — code review on the board). Parses the daemon's git
/// patch output into a structured line model (`DiffRows`) and renders it as a real diff — old/new
/// line-number gutters, a `+`/`−` marker column, full-row add/remove tinting, and section-heading
/// hunk dividers — with working/branch(/parent) baseline and unified/split layout toggles. Refreshes
/// on card selection + mode change; "Open in Zed" for the full changes. Editing stays Zed's job.
struct DiffInspectorView: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme
    let task: Task
    /// Headless-snapshot seed (ORCH_SNAPSHOT_DIFF): canned ANSI shown verbatim instead of calling the
    /// daemon, so the shipping view renders faithfully with no control socket. nil in production.
    var preview: String? = nil

    @State private var base: DiffBase
    @State private var layout: DiffLayout = .unified
    @State private var text = ""
    @State private var files: [DiffFileSection] = []
    @State private var loading = true
    @State private var collapsedFiles: Set<String> = []

    init(task: Task, preview: String? = nil, split: Bool = false) {
        self.task = task
        self.preview = preview
        // Seed synchronously so a headless ImageRenderer snapshot (which never runs `.task`) still
        // shows the diff; production leaves preview nil and loads via the daemon in `.task`.
        _text = State(initialValue: preview ?? "")
        _files = State(initialValue: preview.map(DiffFileParser.parse) ?? [])
        _loading = State(initialValue: preview == nil)
        _layout = State(initialValue: split ? .split : .unified)
        // BT3: a stacked card opens on Parent (its own work vs its parent), else Branch.
        _base = State(initialValue: task.parentBranch != nil ? .parent : .branch)
    }

    /// `.parent` is only offered once the card carries a parent branch (stacked-branches sets it).
    /// Shared with the phone Diff tab — see OrchestraKit `diffBaselines`.
    private var baselines: [DiffBase] { diffBaselines(parentBranch: task.parentBranch) }
    private var reloadKey: String { "\(task.id.uuidString)-\(base.rawValue)" }
    private var allCollapsed: Bool { !files.isEmpty && files.allSatisfy { collapsedFiles.contains($0.id) } }
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
                    ForEach(baselines, id: \.self) { Text(diffBaselineLabel($0, parentBranch: task.parentBranch)).tag($0) }
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
                fauxSegments(items: baselines.map { (diffBaselineLabel($0, parentBranch: task.parentBranch), $0 == base) })
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
                        .font(F.ui(9, .semibold))
                        .foregroundStyle(theme.text3)
                        .frame(width: 10)
                    filePath(file.title, dir: F.ui(12), name: F.ui(12, .semibold), theme: theme)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if file.hunks > 0 {
                        Text("\(file.hunks) \(file.hunks == 1 ? "hunk" : "hunks")")
                            .font(F.ui(10, .medium))
                            .foregroundStyle(theme.text3)
                    }
                    if file.additions > 0 { statPill("+\(file.additions)", theme.green) }
                    if file.deletions > 0 { statPill("−\(file.deletions)", theme.red) }
                }
                .padding(.horizontal, 12)
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

    // MARK: - Unified layout

    private func unifiedDiff(_ file: DiffFileSection) -> some View {
        let rows = DiffRows.make(file.lines)
        let numW = numberWidth(digits: maxDigits(rows.map { max($0.oldNum ?? 0, $0.newNum ?? 0) }))
        return rendered(DiffTextRenderer(rows: rows.map(DiffTextRow.init),
                                         palette: DiffTextPalette(theme: theme),
                                         gutterWidth: numW * 2,
                                         showsBothNumbers: true,
                                         scrollsHorizontally: preview == nil),
                        snapshotWidth: 364)
    }

    /// Live, the renderer is hosted as an AppKit view. The headless snapshot renderer can't lay one
    /// out, so it gets a bitmap of the same text view — see `snapshotImage(width:)`. The width tracks
    /// the 384pt snapshot frame in `snapshotDiff` minus the file-card insets.
    @ViewBuilder
    private func rendered(_ renderer: DiffTextRenderer, snapshotWidth: CGFloat) -> some View {
        if preview == nil {
            renderer
        } else {
            Image(nsImage: renderer.snapshotImage(width: snapshotWidth))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Split layout

    /// Two text views sharing one divider. Each side clips long lines to its own column, so a line can
    /// never bleed across the divider — unlike unified there is no horizontal scroll here, and "Open in
    /// Zed" / the unified view cover reading full long lines.
    private func splitDiff(_ file: DiffFileSection) -> some View {
        let rows = DiffSplitRows.make(file.lines)
        let numW = numberWidth(digits: maxDigits(rows.flatMap { [$0.oldNum ?? 0, $0.newNum ?? 0] }))
        let palette = DiffTextPalette(theme: theme)
        return HStack(spacing: 0) {
            splitSide(rows, numW: numW, palette: palette, side: .remove)
            Rectangle().fill(theme.hair).frame(width: splitDividerWidth)
            splitSide(rows, numW: numW, palette: palette, side: .add)
        }
    }

    /// One column of the split layout. A `nil` cell on a `change` row means that side has no
    /// counterpart (a pure add or pure remove), and renders as a blank context line.
    private func splitSide(_ rows: [DiffSplitRow], numW: CGFloat,
                           palette: DiffTextPalette, side: DiffRow.Kind) -> some View {
        let cells = rows.map { row -> DiffTextRow in
            if row.kind == .hunk { return DiffTextRow(kind: .hunk, oldNum: nil, newNum: nil, text: row.heading) }
            let text = side == .remove ? row.oldText : row.newText
            let num = side == .remove ? row.oldNum : row.newNum
            let kind: DiffRow.Kind = (row.kind == .change && text != nil) ? side : .context
            return DiffTextRow(kind: kind, oldNum: num, newNum: nil, text: text ?? "",
                               filler: row.kind == .change && text == nil)
        }
        return rendered(DiffTextRenderer(rows: cells, palette: palette, gutterWidth: numW,
                                         showsBothNumbers: false, scrollsHorizontally: false),
                        snapshotWidth: 182)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
    }

    /// Long lines scroll horizontally in the live view. The headless snapshot renderer (`ImageRenderer`)
    /// can't lay out a `ScrollView` and proposes an unbounded width, so it instead clips the body to a
    /// fixed width, left-aligned — matching the scroll's resting position. The width tracks the 384pt
    /// snapshot frame in `snapshotDiff` minus the file-card insets.
    private func maxDigits(_ nums: [Int]) -> Int { max(2, String(nums.max() ?? 0).count) }
    private func numberWidth(digits: Int) -> CGFloat { CGFloat(digits) * 7 + 12 }

    private func statPill(_ s: String, _ c: SemColor) -> some View {
        Text(s)
            .font(F.ui(10, .semibold))
            .foregroundStyle(c.text)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(c.tint)
            .clipShape(Capsule())
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
