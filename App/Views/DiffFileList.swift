import AppKit
import OrchestraCore
import OrchestraUI
import SwiftUI

/// The live diff's vertical owner. SwiftUI owns this view's frame, while AppKit owns all file-row
/// realization and sizing below it so a native scroller never asks a lazy SwiftUI stack to revise its
/// document estimate while tracking a knob.
struct DiffFileList: NSViewRepresentable {
    let files: [DiffPreparedFile]
    @Binding var collapsedFiles: Set<String>
    let theme: Theme

    func makeNSView(context: Context) -> DiffFileListView {
        let view = DiffFileListView()
        configure(view)
        return view
    }

    func updateNSView(_ view: DiffFileListView, context: Context) {
        configure(view)
    }

    private func configure(_ view: DiffFileListView) {
        let binding = $collapsedFiles
        view.configure(files: files, collapsedFiles: binding.wrappedValue, theme: theme) { fileID in
            var next = binding.wrappedValue
            if next.contains(fileID) {
                next.remove(fileID)
            } else {
                next.insert(fileID)
            }
            binding.wrappedValue = next
        }
    }
}

@MainActor
final class DiffFileListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView(frame: .zero)
    let tableView = NSTableView(frame: .zero)

    private let documentView = DiffFileListDocumentView(frame: .zero)
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DiffFileColumn"))
    private var documents: [String: DiffPreparedText] = [:]
    private var metrics: [DiffTextMetricsKey: DiffTextMetrics] = [:]
    private var savedTextStates: [String: DiffTextViewState] = [:]
    private var records: [DiffFileListRecord] = []
    private var identities: [DiffFileListIdentity] = []
    private var collapsedFiles: Set<String> = []
    private var palette = DiffTextPalette(theme: Theme(scheme: .light, accent: .blue))
    private var geometryInput: DiffFileListGeometryInput?
    private var toggleFile: ((String) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView

        tableView.headerView = nil
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 1
        tableView.intercellSpacing = NSSize(width: 0, height: DiffFileListRecord.gap)
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        documentView.addSubview(tableView)
        addSubview(scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollerStyleDidChange(_:)),
                                               name: NSScroller.preferredScrollerStyleDidChangeNotification,
                                               object: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        if !refreshGeometryPreservingViewport() {
            updateDocumentExtentIfNeeded()
        }
    }

    /// This is also the focused-check seam. It accepts immutable prepared files and only writes the
    /// SwiftUI binding from an explicit header click, never from AppKit sizing or view reuse.
    func configure(files: [DiffPreparedFile], collapsedFiles: Set<String>, theme: Theme,
                   toggleFile: @escaping (String) -> Void) {
        let newIdentities = files.map(DiffFileListIdentity.init)
        let validIDs = Set(files.map(\.id))
        let effectiveCollapsed = collapsedFiles.intersection(validIDs)
        let newPalette = DiffTextPalette(theme: theme)
        let snapshotChanged = newIdentities != identities
        let collapseChanged = effectiveCollapsed != self.collapsedFiles
        let paletteChanged = newPalette != palette
        self.toggleFile = toggleFile

        if snapshotChanged || collapseChanged {
            captureVisibleTextStates()
            let anchor = captureAnchor()
            if snapshotChanged {
                rebuildRecords(files: files, collapsedFiles: effectiveCollapsed)
                identities = newIdentities
            } else {
                for index in records.indices {
                    records[index].collapsed = effectiveCollapsed.contains(records[index].file.id)
                }
            }
            self.collapsedFiles = effectiveCollapsed
            palette = newPalette
            geometryInput = nil
            _ = updateGeometryIfNeeded(force: true)
            restore(anchor: anchor)
        } else if paletteChanged {
            palette = newPalette
            refreshVisibleRows()
        }
    }

#if ORCHESTRA_DIFF_CHECKS
    func diffCheckSavedTextState(for key: String) -> DiffTextViewState? {
        savedTextStates[key]
    }
#endif

    func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard records.indices.contains(row) else { return 1 }
        return records[row].geometry.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("DiffFileRow")
        let rowView = (tableView.makeView(withIdentifier: identifier, owner: self) as? DiffFileRowView)
            ?? DiffFileRowView(frame: .zero)
        rowView.identifier = identifier
        configure(rowView, with: records[row])
        return rowView
    }

    /// A view-based table removes its NSTableRowView when it leaves the viewport, but can keep the
    /// cell view below that row view alive in a reuse queue. Capture here rather than relying only
    /// on the cell's own superview transition, so a return jump can restore state into any cell.
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        captureTextStatesForRemoval(in: rowView)
    }

    private func configure(_ rowView: DiffFileRowView, with record: DiffFileListRecord) {
        rowView.configure(record: record, palette: palette, savedState: { [weak self] key in
            self?.savedTextStates[key]
        }, saveState: { [weak self] key, state in
            guard let self, self.documents[key] != nil else { return }
            self.savedTextStates[key] = state
        }, toggleFile: { [weak self] fileID in
            self?.toggleFile?(fileID)
        })
    }

    private func captureTextStatesForRemoval(in view: NSView) {
        if let row = view as? DiffFileRowView {
            row.captureTextStateForRemoval()
            return
        }
        for subview in view.subviews {
            captureTextStatesForRemoval(in: subview)
        }
    }

    private func rebuildRecords(files: [DiffPreparedFile], collapsedFiles: Set<String>) {
        let keys = Set(files.flatMap { DiffFileListIdentity($0).contentKeys })
        documents = documents.filter { keys.contains($0.key) }
        metrics = metrics.filter { keys.contains($0.key.contentKey) }
        savedTextStates = savedTextStates.filter { keys.contains($0.key) }
        records = files.map { file in
            DiffFileListRecord(file: file, body: preparedBody(for: file),
                               collapsed: collapsedFiles.contains(file.id))
        }
        cacheMissingMetrics()
    }

    /// TextKit is allowed to calculate fractional line metrics, so every document is measured before
    /// any table geometry asks for it. One scratch editor serves this whole snapshot and then dies;
    /// the cache retains only scalar dimensions keyed by the prepared content and gutter style.
    private func cacheMissingMetrics() {
        let missing = records.flatMap(\.body.documents).filter {
            metrics[DiffTextMetricsKey($0)] == nil
        }
        guard !missing.isEmpty else { return }
        let measurer = DiffTextMeasurer()
        var measured = Set<DiffTextMetricsKey>()
        for document in missing {
            let key = DiffTextMetricsKey(document)
            guard measured.insert(key).inserted else { continue }
            metrics[key] = measurer.measure(document)
        }
    }

    private func preparedBody(for file: DiffPreparedFile) -> DiffFileBody {
        switch file.body {
        case .unified(let pane):
            return .unified(document(for: pane, gutterWidth: numberWidth(for: pane) * 2))
        case .split(let remove, let add):
            let gutter = max(numberWidth(for: remove), numberWidth(for: add))
            return .split(left: document(for: remove, gutterWidth: gutter),
                          right: document(for: add, gutterWidth: gutter))
        }
    }

    private func document(for pane: DiffTextPane, gutterWidth: CGFloat) -> DiffPreparedText {
        if let document = documents[pane.contentKey], document.gutterWidth == gutterWidth {
            return document
        }
        let document = DiffPreparedText(pane: pane, gutterWidth: gutterWidth)
        documents[pane.contentKey] = document
        return document
    }

    private func numberWidth(for pane: DiffTextPane) -> CGFloat {
        CGFloat(max(2, String(pane.maxLineNumber).count)) * 7 + 12
    }

    @discardableResult
    private func updateGeometryIfNeeded(force: Bool = false) -> Bool {
        let input = DiffFileListGeometryInput(width: availableTableWidth(),
                                              scrollerStyle: NSScroller.preferredScrollerStyle)
        guard force || input != geometryInput else { return false }
        for index in records.indices {
            records[index].geometry = geometry(for: records[index], input: input)
        }
        geometryInput = input
        updateTableFrame(width: input.width)
        tableView.reloadData()
        return true
    }

    /// Width and legacy-scroller-style changes can alter a row's cached height even though its text
    /// did not change. Preserve both ephemeral editor state and the visible file before reloading the
    /// table, because NSTableView is allowed to reuse those rows during the reload.
    @discardableResult
    private func refreshGeometryPreservingViewport() -> Bool {
        let input = DiffFileListGeometryInput(width: availableTableWidth(),
                                              scrollerStyle: NSScroller.preferredScrollerStyle)
        guard input != geometryInput else { return false }
        captureVisibleTextStates()
        let anchor = captureAnchor()
        let changed = updateGeometryIfNeeded()
        restore(anchor: anchor)
        return changed
    }

    @objc private func scrollerStyleDidChange(_ notification: Notification) {
        geometryInput = nil
        _ = refreshGeometryPreservingViewport()
    }

    private func geometry(for record: DiffFileListRecord,
                          input: DiffFileListGeometryInput) -> DiffFileRowGeometry {
        guard !record.collapsed else { return .collapsed }
        switch record.body {
        case .unified(let document):
            let metrics = metrics(for: document)
            let overflows = metrics.contentWidth > input.width + 0.5
            let scrollerBand: CGFloat
            if overflows && input.scrollerStyle == .legacy {
                scrollerBand = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            } else {
                scrollerBand = 0
            }
            let textWidth = max(input.width, metrics.contentWidth)
            return .unified(textHeight: metrics.textHeight, documentWidth: textWidth,
                            bodyHeight: metrics.textHeight + scrollerBand)
        case .split(let left, let right):
            return .split(leftHeight: metrics(for: left).textHeight,
                          rightHeight: metrics(for: right).textHeight)
        }
    }

    private func metrics(for document: DiffPreparedText) -> DiffTextMetrics {
        let key = DiffTextMetricsKey(document)
        if let cached = metrics[key] { return cached }
        assertionFailure("prepared document was not measured before table geometry")
        let measured = DiffTextMeasurer().measure(document)
        metrics[key] = measured
        return measured
    }

    private func availableTableWidth() -> CGFloat {
        let width = scrollView.contentView.bounds.width > 0 ? scrollView.contentView.bounds.width : bounds.width
        return max(1, width - DiffFileListRecord.horizontalInset * 2)
    }

    private func updateTableFrame(width: CGFloat) {
        let rowHeight = records.reduce(CGFloat.zero) { $0 + $1.geometry.rowHeight }
        let gaps = CGFloat(max(0, records.count - 1)) * DiffFileListRecord.gap
        let tableHeight = rowHeight + gaps
        column.width = width
        tableView.frame = NSRect(x: DiffFileListRecord.horizontalInset, y: DiffFileListRecord.verticalInset,
                                 width: width, height: tableHeight)
        updateDocumentExtentIfNeeded()
    }

    /// A vertical viewport resize changes only the scroll view's required document extent. It must not
    /// force a TextKit measurement or a table reload, but it must drop stale empty scroll range when a
    /// previously tall all-collapsed view becomes shorter.
    private func updateDocumentExtentIfNeeded() {
        let requiredHeight = max(tableView.frame.height + DiffFileListRecord.verticalInset * 2,
                                 scrollView.contentView.bounds.height)
        let requiredWidth = max(scrollView.contentView.bounds.width,
                                tableView.frame.maxX + DiffFileListRecord.horizontalInset)
        let required = NSRect(x: 0, y: 0, width: requiredWidth, height: requiredHeight)
        guard documentView.frame != required else { return }
        documentView.frame = required
    }

    private func captureVisibleTextStates() {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound else { return }
        for row in range.location..<NSMaxRange(range) {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? DiffFileRowView)?.captureTextState()
        }
    }

    private func refreshVisibleRows() {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound else { return }
        for row in range.location..<NSMaxRange(range) where records.indices.contains(row) {
            if let rowView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? DiffFileRowView {
                configure(rowView, with: records[row])
            }
        }
    }

    private func captureAnchor() -> DiffFileListAnchor? {
        guard !records.isEmpty else { return nil }
        let documentPoint = scrollView.contentView.bounds.origin
        let tablePoint = tableView.convert(documentPoint, from: documentView)
        // The table sits inside the document's horizontal padding. Its converted viewport x can be
        // negative even though the vertical point is valid, and NSTableView rejects row hits outside
        // its first column. Probe with a known point in that column instead.
        let column = tableView.rect(ofColumn: 0)
        let rowPoint = NSPoint(x: column.midX, y: tablePoint.y)
        let row = tableView.row(at: rowPoint)
        guard records.indices.contains(row) else { return nil }
        let rect = tableView.rect(ofRow: row)
        return DiffFileListAnchor(fileID: records[row].file.id,
                                  relativeOffset: max(0, rowPoint.y - rect.minY), fallbackRow: row)
    }

    private func restore(anchor: DiffFileListAnchor?) {
        guard let anchor, !records.isEmpty else { return }
        let row = records.firstIndex { $0.file.id == anchor.fileID }
            ?? min(anchor.fallbackRow, records.count - 1)
        let rowRect = tableView.rect(ofRow: row)
        // An anchor inside a body that just collapsed has no corresponding body offset any more.
        // Put that file's fixed header at the viewport top rather than scrolling through later files.
        let relativeOffset: CGFloat
        if records[row].collapsed {
            relativeOffset = 0
        } else {
            relativeOffset = min(max(0, anchor.relativeOffset), max(0, rowRect.height - 1))
        }
        let tablePoint = NSPoint(x: 0, y: rowRect.minY + relativeOffset)
        let documentPoint = documentView.convert(tablePoint, from: tableView)
        let maxY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, documentPoint.y), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

private final class DiffFileListDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private struct DiffFileListIdentity: Equatable {
    let id: String
    let title: String
    let additions: Int
    let deletions: Int
    let hunks: Int
    let contentKeys: [String]

    init(_ file: DiffPreparedFile) {
        id = file.id
        title = file.section.title
        additions = file.section.additions
        deletions = file.section.deletions
        hunks = file.section.hunks
        switch file.body {
        case .unified(let pane): contentKeys = [pane.contentKey]
        case .split(let left, let right): contentKeys = [left.contentKey, right.contentKey]
        }
    }
}

private struct DiffFileListGeometryInput: Equatable {
    let width: CGFloat
    let scrollerStyle: NSScroller.Style

    init(width: CGFloat, scrollerStyle: NSScroller.Style) {
        self.width = width.rounded()
        self.scrollerStyle = scrollerStyle
    }
}

@MainActor
private struct DiffTextMetricsKey: Hashable {
    let contentKey: String
    let gutterWidth: CGFloat
    let showsBothNumbers: Bool

    init(_ document: DiffPreparedText) {
        contentKey = document.contentKey
        gutterWidth = document.gutterWidth
        showsBothNumbers = document.showsBothNumbers
    }
}

private struct DiffFileListAnchor {
    let fileID: String
    let relativeOffset: CGFloat
    let fallbackRow: Int
}
