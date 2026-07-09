import SwiftUI
import OrchestraKit
import OrchestraUI

/// The **Diff** tab (design §3): read-only three-way baseline **Working · Branch · Parent** (Parent only
/// for a stacked card with a `parentBranch`), a file list, and per-file unified diff. Reuses the shared
/// `DiffFileParser` / `DiffRows` (moved to OrchestraKit so both desktop + phone parse one way) over the
/// shipped `diffText` RPC. Phone-native reinterpretation of the desktop `DiffInspectorView` — unified only
/// (split is a desktop nicety; a phone's width favours one column + horizontal scroll for long lines).
struct DiffTab: View {
    let task: Task
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme

    @State private var base: DiffBase
    @State private var files: [DiffFileSection] = []
    @State private var loading = true
    @State private var collapsed: Set<String> = []

    init(task: Task) {
        self.task = task
        // BT3: a stacked card opens on Parent (its own work vs its parent), else Branch — same default
        // the desktop inspector uses.
        _base = State(initialValue: diffDefaultBaseline(parentBranch: task.parentBranch))
    }

    private var baselines: [DiffBase] { diffBaselines(parentBranch: task.parentBranch) }
    private var reloadKey: String { "\(task.id.uuidString)-\(base.rawValue)" }

    var body: some View {
        VStack(spacing: 0) {
            baselineBar
            Divider().overlay(theme.hair)
            content
        }
        .background(theme.termBg)
        .task(id: reloadKey) { await load() }
    }

    private var baselineBar: some View {
        HStack(spacing: 10) {
            Picker("Baseline", selection: $base) {
                ForEach(baselines, id: \.self) { Text(diffBaselineLabel($0, parentBranch: task.parentBranch)).tag($0) }
            }
            .pickerStyle(.segmented)
            Spacer(minLength: 6)
            if files.count > 1 {
                Button {
                    let allCollapsed = files.allSatisfy { collapsed.contains($0.id) }
                    collapsed = allCollapsed ? [] : Set(files.map(\.id))
                } label: {
                    Image(systemName: files.allSatisfy { collapsed.contains($0.id) }
                          ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        .foregroundStyle(theme.text2)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if loading {
            centered { ProgressView() }
        } else if files.isEmpty {
            centered {
                VStack(spacing: 8) {
                    Image(systemName: task.origin == .worktree ? "checkmark.circle" : "minus.circle")
                        .font(.title2).foregroundStyle(theme.text3)
                    Text(task.origin == .worktree ? "No changes on this baseline" : "No diff for this card")
                        .font(.footnote).foregroundStyle(theme.text3)
                }
            }
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 12) {
                    ForEach(files) { fileSection($0) }
                }
                .padding(12)
            }
        }
    }

    private func fileSection(_ file: DiffFileSection) -> some View {
        let isCollapsed = collapsed.contains(file.id)
        return VStack(spacing: 0) {
            Button {
                if isCollapsed { collapsed.remove(file.id) } else { collapsed.insert(file.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold)).foregroundStyle(theme.text3).frame(width: 10)
                    filePath(file.title, dir: .footnote, name: .footnote.weight(.semibold), theme: theme)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if file.additions > 0 { statPill("+\(file.additions)", theme.green) }
                    if file.deletions > 0 { statPill("−\(file.deletions)", theme.red) }
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(theme.termPrompt)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !isCollapsed {
                Divider().overlay(theme.hair)
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(DiffRows.make(file.lines)) { unifiedRow($0) }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.vertical, 2)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.hair, lineWidth: 0.5))
    }

    @ViewBuilder private func unifiedRow(_ row: DiffRow) -> some View {
        if row.kind == .hunk {
            Text(row.text.isEmpty ? " " : row.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.text3)
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.accent.opacity(theme.dark ? 0.10 : 0.06))
        } else {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    lineNo(row.oldNum)
                    lineNo(row.newNum)
                }
                .background(theme.dark ? Color.white.opacity(0.03) : Color.black.opacity(0.025))
                Text(marker(row.kind))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(markerColor(row.kind))
                    .frame(width: 16)
                Text(row.text.isEmpty ? " " : row.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.term)
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
                    .padding(.trailing, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowTint(row.kind))
        }
    }

    private func lineNo(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(theme.text3)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 6).padding(.vertical, 1.5)
    }

    private func marker(_ k: DiffRow.Kind) -> String { k == .add ? "+" : k == .remove ? "−" : " " }
    private func markerColor(_ k: DiffRow.Kind) -> Color {
        k == .add ? theme.green.text : k == .remove ? theme.red.text : .clear
    }
    private func rowTint(_ k: DiffRow.Kind) -> Color {
        k == .add ? theme.green.tint : k == .remove ? theme.red.tint : .clear
    }

    private func statPill(_ s: String, _ c: SemColor) -> some View {
        Text(s).font(.caption2.weight(.semibold)).foregroundStyle(c.text)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(c.tint))
    }

    /// Path styled as a dimmed directory + bold filename.
    private func load() async {
        loading = true
        let text = await model.diffText(task.id, base: base.rawValue)
        files = DiffFileParser.parse(text)
        loading = false
    }

}
