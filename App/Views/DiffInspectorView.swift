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
    private var baselines: [DiffBase] {
        task.parentBranch != nil ? [.working, .branch, .parent] : [.working, .branch]
    }
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
                        .font(F.ui(9, .semibold))
                        .foregroundStyle(theme.text3)
                        .frame(width: 10)
                    filePath(file.title)
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
        let body = VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { unifiedRow($0, numW: numW) }
        }
        .fixedSize(horizontal: true, vertical: false)   // width = widest line; guards the horizontal scroll
        return scrollableBody(body)
    }

    @ViewBuilder private func unifiedRow(_ row: DiffRow, numW: CGFloat) -> some View {
        if row.kind == .hunk {
            hunkDivider(row.text)
        } else {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    lineNumber(row.oldNum, width: numW)
                    lineNumber(row.newNum, width: numW)
                }
                .background(theme.dark ? Color.white.opacity(0.03) : Color.black.opacity(0.025))
                HStack(spacing: 0) {
                    Text(marker(row.kind))
                        .font(codeFont(.medium))
                        .foregroundStyle(markerColor(row.kind))
                        .frame(width: 16)
                    codeText(row.text)
                        .padding(.trailing, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(rowTint(row.kind))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Split layout

    private func splitDiff(_ file: DiffFileSection) -> some View {
        let rows = DiffSplitRows.make(file.lines)
        let numW = numberWidth(digits: maxDigits(rows.flatMap { [$0.oldNum ?? 0, $0.newNum ?? 0] }))
        let body = VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { splitRow($0, numW: numW) }
        }
        // The two columns each fill half the pane and clip long lines to their own side (see `splitCell`),
        // so a line can never overflow across the divider into the other column. Unlike the unified layout
        // there is no horizontal scroll — "Open in Zed" / the unified view cover reading full long lines.
        // The headless snapshot proposes an unbounded width, so pin the body to the snapshot frame.
        return Group {
            if preview == nil { body }
            else { body.frame(width: 364, alignment: .leading).clipped() }
        }
    }

    /// Long lines scroll horizontally in the live view. The headless snapshot renderer (`ImageRenderer`)
    /// can't lay out a `ScrollView` and proposes an unbounded width, so it instead clips the body to a
    /// fixed width, left-aligned — matching the scroll's resting position. The width tracks the 384pt
    /// snapshot frame in `snapshotDiff` minus the file-card insets.
    @ViewBuilder private func scrollableBody(_ body: some View) -> some View {
        if preview == nil {
            ScrollView(.horizontal, showsIndicators: false) { body }
        } else {
            body.frame(width: 364, alignment: .leading).clipped()
        }
    }

    @ViewBuilder private func splitRow(_ row: DiffSplitRow, numW: CGFloat) -> some View {
        if row.kind == .hunk {
            hunkDivider(row.heading)
        } else {
            HStack(spacing: 0) {
                splitCell(num: row.oldNum, text: row.oldText, side: .remove, changed: row.kind == .change, numW: numW)
                Rectangle().fill(theme.hair).frame(width: splitDividerWidth)
                splitCell(num: row.newNum, text: row.newText, side: .add, changed: row.kind == .change, numW: numW)
            }
        }
    }

    /// One side of a split row. `text == nil` renders an empty (no-counterpart) cell.
    private func splitCell(num: Int?, text: String?, side: DiffRow.Kind, changed: Bool, numW: CGFloat) -> some View {
        let kind: DiffRow.Kind = (changed && text != nil) ? side : .context
        return HStack(spacing: 0) {
            lineNumber(num, width: numW)
                .background(theme.dark ? Color.white.opacity(0.03) : Color.black.opacity(0.025))
            HStack(spacing: 0) {
                if changed {
                    Text(text == nil ? " " : marker(side))
                        .font(codeFont(.medium)).foregroundStyle(markerColor(side)).frame(width: 14)
                }
                codeText(text ?? " ").padding(.trailing, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(text == nil ? theme.termPrompt : rowTint(kind))
        }
        // Each side takes half the row and clips its own overflow, so a long line stays on its side of
        // the divider instead of bleeding into the opposite column.
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    // MARK: - Shared row pieces

    private func lineNumber(_ n: Int?, width: CGFloat) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .foregroundStyle(theme.text3)
            .padding(.trailing, 8)
            .frame(width: width, alignment: .trailing)
            .padding(.vertical, 1.5)
    }

    private func codeText(_ s: String) -> some View {
        Text(s.isEmpty ? " " : s)
            .font(codeFont(.regular))
            .foregroundStyle(theme.term)
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
            .padding(.vertical, 1.5)
    }

    /// A soft band marking a jump in the file, labelled with git's section heading (the enclosing
    /// function) when present. Replaces the raw `@@ -14,9 +14,11 @@` line.
    private func hunkDivider(_ heading: String) -> some View {
        Text(heading)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(theme.text3)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(theme.accent.opacity(theme.dark ? 0.10 : 0.06))
            .overlay(Rectangle().fill(theme.hair).frame(height: 0.5), alignment: .top)
            .overlay(Rectangle().fill(theme.hair).frame(height: 0.5), alignment: .bottom)
    }

    private func codeFont(_ weight: Font.Weight) -> Font { .system(size: 11.5, weight: weight, design: .monospaced) }
    private func marker(_ kind: DiffRow.Kind) -> String { kind == .add ? "+" : kind == .remove ? "−" : " " }
    private func markerColor(_ kind: DiffRow.Kind) -> Color {
        kind == .add ? theme.green.text : kind == .remove ? theme.red.text : .clear
    }
    private func rowTint(_ kind: DiffRow.Kind) -> Color {
        kind == .add ? theme.green.tint : kind == .remove ? theme.red.tint : .clear
    }
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

    /// Path styled as a dimmed directory + bold filename, e.g. `App/Views/` + **DiffInspectorView.swift**.
    private func filePath(_ path: String) -> Text {
        guard let slash = path.lastIndex(of: "/") else {
            return Text(path).font(F.ui(12, .semibold)).foregroundColor(theme.text)
        }
        let dir = String(path[...slash])
        let name = String(path[path.index(after: slash)...])
        return Text(dir).font(F.ui(12)).foregroundColor(theme.text3)
             + Text(name).font(F.ui(12, .semibold)).foregroundColor(theme.text)
    }

    private func label(_ b: DiffBase) -> String {
        switch b {
        case .working: return "Working"
        case .branch:  return "Branch"
        // S3-3: name the parent branch — the parent-relative diffstat measures against it, and two
        // adjacent cards' `+N −M` can baseline against different parents with no other indicator.
        case .parent:  return task.parentBranch.map { "Parent (\($0))" } ?? "Parent"
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
