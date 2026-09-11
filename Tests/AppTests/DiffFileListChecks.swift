import AppKit
import Foundation
import OrchestraCore
import OrchestraUI
import SwiftUI

/// Native regression checks for the diff file container. These are deliberately a standalone async
/// entry point rather than a SwiftPM test target: the app sources are outside the package and the
/// checks need a real AppKit window for table reuse and scroller geometry to settle.
@MainActor
func runDiffFileListChecks() async throws {
    let theme = Theme(scheme: .light, accent: .blue)
    try await checkStableDocumentExtent(theme: theme)
    try await checkUnicodeAndTrailingNewlineHeight(theme: theme)
    try await checkBoundedEditors(theme: theme)
    try await checkSelectionDoesNotMoveBetweenFiles(theme: theme)
    try await checkSelectionAndHorizontalOffsetRoundTrip(theme: theme)
    try await checkHeterogeneousReusePoolRoundTrip(theme: theme)
    try await checkCollapsedAnchor(theme: theme)
    try await checkTallFileCollapseAnchor(theme: theme)
    try await checkUnifiedAndSplitGeometry(theme: theme)
    try await runDiffFileListWheelChecks(theme: theme)
    try await checkHeaderActionAndAllCollapse(theme: theme)
    try await checkResizePreservesVisibleState(theme: theme)
    try await checkViewportResizeDropsEmptyScrollRange(theme: theme)
    try await checkNewGenerationResetsSelection(theme: theme)
    try await checkUnchangedConfigurationPreservesSelection(theme: theme)
}

private enum DiffFileListCheckFailure: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw DiffFileListCheckFailure.failed(message) }
}

private func preparedFiles(_ count: Int, layout: DiffTextLayout = .unified,
                           generation: Int = 1, longLineWords: Int = 0) -> [DiffPreparedFile] {
    let patch = (0..<count).map { index in
        let long = longLineWords > 0 && index == 0
            ? " +let value = \"" + String(repeating: "wide-", count: longLineWords) + "\""
            : " +let value = \(index)"
        return """
        diff --git a/Sources/File\(index).swift b/Sources/File\(index).swift
        --- a/Sources/File\(index).swift
        +++ b/Sources/File\(index).swift
        @@ -1,3 +1,4 @@
         let unchanged = \(index)
        -let previous = \(index)
        \(long)
        +let emoji = "café 👩🏽‍💻 漢字 \(index)"
        """
    }.joined(separator: "\n")
    return DiffPrepared.make(DiffFileParser.parse(patch), layout: layout, generation: generation)
}

private func tallPreparedFiles(_ count: Int, rows: Int, generation: Int = 1) -> [DiffPreparedFile] {
    let patch = (0..<count).map { index in
        let additions = (0..<rows).map { row in
            if index == 0, row == 0 {
                return "+let wideValue = \"" + String(repeating: "long-", count: 100) + "\""
            }
            return "+let detail\(row) = \(index)"
        }.joined(separator: "\n")
        return """
        diff --git a/Sources/Tall\(index).swift b/Sources/Tall\(index).swift
        --- a/Sources/Tall\(index).swift
        +++ b/Sources/Tall\(index).swift
        @@ -0,0 +1,\(rows) @@
        \(additions)
        """
    }.joined(separator: "\n")
    return DiffPrepared.make(DiffFileParser.parse(patch), layout: .unified, generation: generation)
}

private func heterogeneousReuseFiles() -> [DiffPreparedFile] {
    let patch = (0..<10).map { index -> String in
        if index == 5 {
            let tallBody = (0..<100).map { row in "+let tallDetail\(row) = \(row)" }.joined(separator: "\n")
            return """
            diff --git a/Sources/TallDestination.swift b/Sources/TallDestination.swift
            --- a/Sources/TallDestination.swift
            +++ b/Sources/TallDestination.swift
            @@ -0,0 +1,100 @@
            \(tallBody)
            """
        }
        let value = index < 3 ? String(repeating: "wide-", count: 100) : "\(index)"
        return """
        diff --git a/Sources/Reuse\(index).swift b/Sources/Reuse\(index).swift
        --- a/Sources/Reuse\(index).swift
        +++ b/Sources/Reuse\(index).swift
        @@ -1,3 +1,4 @@
         let unchanged = \(index)
        -let previous = \(index)
        +let selectedValue = "\(value)"
        +let emoji = "café 👩🏽‍💻 漢字 \(index)"
        """
    }.joined(separator: "\n")
    return DiffPrepared.make(DiffFileParser.parse(patch), layout: .unified, generation: 1)
}

@MainActor
private func withMountedList<T>(files: [DiffPreparedFile], collapsed: Set<String> = [], theme: Theme,
                                size: NSSize = NSSize(width: 680, height: 430),
                                toggleFile: @escaping (String) -> Void = { _ in },
                                _ body: (DiffFileListView) async throws -> T) async rethrows -> T {
    let list = DiffFileListView()
    list.configure(files: files, collapsedFiles: collapsed, theme: theme, toggleFile: toggleFile)

    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.contentView = list
    window.orderFront(nil)
    await settleWindow(window, list: list)
    defer { window.orderOut(nil) }
    return try await body(list)
}

@MainActor
private func settleWindow(_ window: NSWindow, list: DiffFileListView) async {
    for _ in 0..<4 {
        window.displayIfNeeded()
        list.layoutSubtreeIfNeeded()
        list.tableView.layoutSubtreeIfNeeded()
        await _Concurrency.Task.yield()
    }
}

@MainActor
private func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

@MainActor
private func editor(in list: DiffFileListView, key: String) -> DiffTextView? {
    descendants(of: list).compactMap { $0 as? DiffTextView }.first { $0.appliedKey == key }
}

@MainActor
private func headerButton(in list: DiffFileListView) -> NSButton? {
    descendants(of: list).compactMap { $0 as? NSButton }.first
}

private func pane(for file: DiffPreparedFile) -> DiffTextPane {
    guard case .unified(let pane) = file.body else { fatalError("expected unified fixture") }
    return pane
}

private struct DiffTextLayoutMeasurement {
    let height: CGFloat
    let usedRect: NSRect
    let containerSize: NSSize
    let frame: NSRect
}

/// Deliberately independent from `DiffPreparedText` / `DiffTextMeasurer`: it lays out the literal
/// renderer string in a new NSTextView so a shared measurement bug cannot make the assertion pass.
@MainActor
private func referenceTextMeasurement(_ pane: DiffTextPane) -> DiffTextLayoutMeasurement {
    let text = NSTextView(frame: .zero)
    text.textContainerInset = NSSize(width: 0, height: 4)
    text.isHorizontallyResizable = true
    text.isVerticallyResizable = true
    text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                          height: CGFloat.greatestFiniteMagnitude)
    text.textContainer?.lineFragmentPadding = 6
    text.textContainer?.widthTracksTextView = false
    text.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                      height: CGFloat.greatestFiniteMagnitude)
    let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    let rendered = pane.rows.map { row -> String in
        let marker: String
        switch row.kind {
        case .add: marker = "+"
        case .remove: marker = "−"
        case .context, .hunk: marker = " "
        }
        return row.kind == .hunk ? row.text + "\n" : marker + " " + row.text + "\n"
    }.joined()
    text.textStorage?.setAttributedString(NSAttributedString(string: rendered, attributes: [.font: font]))
    return layoutMeasurement(for: text)
}

@MainActor
private func layoutMeasurement(for text: NSTextView) -> DiffTextLayoutMeasurement {
    guard let layout = text.layoutManager, let container = text.textContainer else {
        return DiffTextLayoutMeasurement(height: 0, usedRect: .zero, containerSize: .zero, frame: text.frame)
    }
    layout.ensureLayout(for: container)
    let usedRect = layout.usedRect(for: container)
    return DiffTextLayoutMeasurement(height: ceil(usedRect.height + text.textContainerInset.height * 2),
                                     usedRect: usedRect, containerSize: container.containerSize, frame: text.frame)
}

@MainActor
private func scrollToRow(_ row: Int, in list: DiffFileListView) {
    let table = list.tableView
    let document = list.scrollView.documentView!
    let rowOrigin = document.convert(table.rect(ofRow: row).origin, from: table)
    list.scrollView.contentView.scroll(to: NSPoint(x: 0, y: rowOrigin.y))
    list.scrollView.reflectScrolledClipView(list.scrollView.contentView)
}

@MainActor
private func topVisibleFileID(in list: DiffFileListView, files: [DiffPreparedFile]) -> String? {
    guard let document = list.scrollView.documentView else { return nil }
    let point = list.tableView.convert(list.scrollView.contentView.bounds.origin, from: document)
    let column = list.tableView.rect(ofColumn: 0)
    let row = list.tableView.row(at: NSPoint(x: column.midX, y: point.y))
    guard files.indices.contains(row) else { return nil }
    return files[row].id
}

@MainActor
private func checkStableDocumentExtent(theme: Theme) async throws {
    let files = preparedFiles(80)
    try await withMountedList(files: files, theme: theme) { list in
        let initial = list.scrollView.documentView!.frame.height
        for row in stride(from: 0, to: files.count, by: 5) {
            scrollToRow(row, in: list)
            await settleWindow(list.window!, list: list)
            try require(abs(list.scrollView.documentView!.frame.height - initial) < 0.5,
                        "scrolling changed the native table document extent")
        }
    }
}

@MainActor
private func checkUnicodeAndTrailingNewlineHeight(theme: Theme) async throws {
    let files = preparedFiles(1)
    let reference = referenceTextMeasurement(pane(for: files[0]))
    try await withMountedList(files: files, theme: theme) { list in
        let key = pane(for: files[0]).contentKey
        guard let text = editor(in: list, key: key) else {
            throw DiffFileListCheckFailure.failed("the first file never mounted a native text editor")
        }
        let actual = layoutMeasurement(for: text)
        try require(abs(text.frame.height - reference.height) < 0.5,
                    "Unicode or the renderer's trailing newline produced a different TextKit height " +
                    "(actual=\(text.frame.height), reference=\(reference.height), " +
                    "actualUsed=\(actual.usedRect), referenceUsed=\(reference.usedRect), " +
                    "actualContainer=\(actual.containerSize), referenceContainer=\(reference.containerSize), " +
                    "actualFrame=\(actual.frame), referenceFrame=\(reference.frame))")
        text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
        let pasteboard = NSPasteboard.withUniqueName()
        // NSTextView declares its legacy NSString type alongside RTF; asking it for only the
        // modern `.string` type returns false even though the selected text is copyable.
        try require(text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes),
                    "the native diff editor could not copy selected text")
        try require(pasteboard.string(forType: .string) == text.string,
                    "copying a diff included its drawn line-number gutter")
    }
}

@MainActor
private func checkBoundedEditors(theme: Theme) async throws {
    let files = preparedFiles(500)
    try await withMountedList(files: files, theme: theme, size: NSSize(width: 700, height: 440)) { list in
        let count = descendants(of: list).compactMap { $0 as? DiffTextView }.count
        try require(count < 50, "opening 500 files mounted \(count) native text editors")
    }
}

@MainActor
private func checkSelectionDoesNotMoveBetweenFiles(theme: Theme) async throws {
    let files = preparedFiles(100)
    try await withMountedList(files: files, theme: theme) { list in
        let firstKey = pane(for: files[0]).contentKey
        guard let first = editor(in: list, key: firstKey) else {
            throw DiffFileListCheckFailure.failed("the selected file did not mount")
        }
        let selected = NSRange(location: 3, length: 5)
        first.setSelectedRange(selected)

        scrollToRow(files.count - 1, in: list)
        await settleWindow(list.window!, list: list)
        let visibleElsewhere = descendants(of: list).compactMap { $0 as? DiffTextView }
            .first { $0.appliedKey != firstKey }
        guard let visibleElsewhere else {
            throw DiffFileListCheckFailure.failed("scrolling away did not realize another file for reuse")
        }
        try require(visibleElsewhere.selectedRange() != selected,
                    "a reused editor transplanted the previous file's selection")

        scrollToRow(0, in: list)
        await settleWindow(list.window!, list: list)
        try require(editor(in: list, key: firstKey)?.selectedRange() == selected,
                    "returning to a file lost its selected text")
    }
}

@MainActor
private func checkSelectionAndHorizontalOffsetRoundTrip(theme: Theme) async throws {
    // The first file is wide and the rest are ordinary-width rows. A long jump can place the old
    // first cell in NSTableView's reuse pool without immediately configuring it for another file.
    let files = preparedFiles(100, longLineWords: 100)
    try await withMountedList(files: files, theme: theme, size: NSSize(width: 310, height: 350)) { list in
        let key = pane(for: files[0]).contentKey
        guard let original = editor(in: list, key: key) else {
            throw DiffFileListCheckFailure.failed("the wide selection fixture did not mount its first editor")
        }
        let selection = NSRange(location: 3, length: 6)
        original.setSelectedRange(selection)
        await settleWindow(list.window!, list: list)
        guard let settledOriginal = editor(in: list, key: key),
              let settledScroll = settledOriginal.enclosingScrollView else {
            throw DiffFileListCheckFailure.failed("the wide selection fixture lost its editor while settling selection")
        }
        try require(settledOriginal.selectedRange() == selection,
                    "the wide selection fixture did not settle its text selection")
        let requestedOffset = min(80, max(0, settledOriginal.frame.width - settledScroll.contentView.bounds.width))
        try require(requestedOffset > 0, "the wide selection fixture was not horizontally scrollable")
        settledScroll.contentView.scroll(to: NSPoint(x: requestedOffset, y: 0))
        settledScroll.reflectScrolledClipView(settledScroll.contentView)
        await settleWindow(list.window!, list: list)
        try require(abs(settledScroll.contentView.bounds.origin.x - requestedOffset) < 0.5,
                    "the round-trip fixture did not retain its requested horizontal offset before removal")

        scrollToRow(80, in: list)
        await settleWindow(list.window!, list: list)
        try require(editor(in: list, key: key) == nil,
                    "the selected editor did not leave the table hierarchy during the jump")
        let removedState = list.diffCheckSavedTextState(for: key)
        try require(abs((removedState?.horizontalOffset ?? -1) - requestedOffset) < 0.5,
                    "removing the selected editor did not retain its horizontal offset " +
                    "(expected=\(requestedOffset), saved=\(String(describing: removedState?.horizontalOffset)))")

        scrollToRow(0, in: list)
        await settleWindow(list.window!, list: list)
        guard let returned = editor(in: list, key: key), let returnedScroll = returned.enclosingScrollView else {
            throw DiffFileListCheckFailure.failed("the selected editor did not remount after the jump")
        }
        try require(returned.selectedRange() == selection,
                    "a selected editor lost its selection after leaving the table hierarchy")
        try require(abs(returnedScroll.contentView.bounds.origin.x - requestedOffset) < 0.5,
                    "a unified editor lost its horizontal offset after leaving the table hierarchy " +
                    "(expected=\(requestedOffset), actual=\(returnedScroll.contentView.bounds.origin.x), " +
                    "saved=\(String(describing: list.diffCheckSavedTextState(for: key)?.horizontalOffset)), " +
                    "textWidth=\(returned.frame.width), clipWidth=\(returnedScroll.contentView.bounds.width))")
    }
}

@MainActor
private func checkHeterogeneousReusePoolRoundTrip(theme: Theme) async throws {
    // Three short, wide rows fill the starting viewport. The later tall row needs only one editor,
    // leaving the selected rows' cells out of the hierarchy before the return jump asks for them again.
    let files = heterogeneousReuseFiles()
    try await withMountedList(files: files, theme: theme, size: NSSize(width: 320, height: 450)) { list in
        let selected = try (0..<3).map { index -> (key: String, selection: NSRange, offset: CGFloat) in
            let key = pane(for: files[index]).contentKey
            guard let text = editor(in: list, key: key) else {
                throw DiffFileListCheckFailure.failed("the short selected reuse fixture did not mount file \(index)")
            }
            let selection = NSRange(location: index + 1, length: 3)
            text.setSelectedRange(selection)
            return (key, selection, CGFloat(20 * (index + 1)))
        }
        await settleWindow(list.window!, list: list)
        for state in selected {
            guard let text = editor(in: list, key: state.key), let scroll = text.enclosingScrollView else {
                throw DiffFileListCheckFailure.failed("the short selected reuse fixture lost an editor while settling selection")
            }
            try require(text.selectedRange() == state.selection,
                        "the short selected reuse fixture did not settle a text selection")
            let maxOffset = max(0, text.frame.width - scroll.contentView.bounds.width)
            try require(maxOffset >= state.offset,
                        "the short selected reuse fixture did not expose the requested horizontal range")
            scroll.contentView.scroll(to: NSPoint(x: state.offset, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            try require(abs(scroll.contentView.bounds.origin.x - state.offset) < 0.5,
                        "the short selected reuse fixture rejected its requested horizontal offset")
        }
        await settleWindow(list.window!, list: list)
        for state in selected {
            let restored = editor(in: list, key: state.key)?.enclosingScrollView
            let actual = restored?.contentView.bounds.origin.x ?? -1
            try require(abs(actual - state.offset) < 0.5,
                        "the short selected reuse fixture lost its offset before removal " +
                        "(expected=\(state.offset), actual=\(actual), textWidth=\(restored?.documentView?.frame.width ?? -1), " +
                        "clipWidth=\(restored?.contentView.bounds.width ?? -1), frame=\(String(describing: restored?.frame)))")
        }

        scrollToRow(5, in: list)
        await settleWindow(list.window!, list: list)
        try require(selected.allSatisfy { editor(in: list, key: $0.key) == nil },
                    "the selected short editors did not leave the hierarchy for the tall destination")
        for state in selected {
            try require(abs((list.diffCheckSavedTextState(for: state.key)?.horizontalOffset ?? -1) - state.offset) < 0.5,
                        "removing a short selected editor did not retain its horizontal offset")
        }
        let destinationEditors = descendants(of: list).compactMap { $0 as? DiffTextView }.count
        try require(destinationEditors < selected.count,
                    "the tall destination did not shrink the active editor set for the reuse-pool path")

        scrollToRow(0, in: list)
        await settleWindow(list.window!, list: list)
        for state in selected {
            guard let text = editor(in: list, key: state.key), let scroll = text.enclosingScrollView else {
                throw DiffFileListCheckFailure.failed("a selected short editor did not remount after the tall destination")
            }
            try require(text.selectedRange() == state.selection,
                        "a reuse-pool return lost one selected short editor's selection")
            try require(abs(scroll.contentView.bounds.origin.x - state.offset) < 0.5,
                        "a reuse-pool return lost one selected short editor's horizontal offset")
        }
    }
}

@MainActor
private func checkCollapsedAnchor(theme: Theme) async throws {
    let files = preparedFiles(70)
    try await withMountedList(files: files, theme: theme) { list in
        scrollToRow(30, in: list)
        await settleWindow(list.window!, list: list)
        guard let before = topVisibleFileID(in: list, files: files) else {
            throw DiffFileListCheckFailure.failed("the anchor file was not visible before collapsing")
        }
        let beforeOrigin = list.scrollView.contentView.bounds.origin
        let beforePoint = list.tableView.convert(beforeOrigin, from: list.scrollView.documentView)
        let beforeRect = list.tableView.rect(ofRow: 30)
        list.configure(files: files, collapsedFiles: [files[0].id], theme: theme, toggleFile: { _ in })
        await settleWindow(list.window!, list: list)
        let after = topVisibleFileID(in: list, files: files)
        let afterOrigin = list.scrollView.contentView.bounds.origin
        let afterPoint = list.tableView.convert(afterOrigin, from: list.scrollView.documentView)
        let afterRect = list.tableView.rect(ofRow: 30)
        try require(after == before,
                    "collapsing a file above the viewport changed the visible-file anchor " +
                    "(before=\(before), after=\(after ?? "nil"), beforeOrigin=\(beforeOrigin), " +
                    "afterOrigin=\(afterOrigin), beforePoint=\(beforePoint), afterPoint=\(afterPoint), " +
                    "beforeRow30=\(beforeRect), afterRow30=\(afterRect))")
    }
}

@MainActor
private func checkTallFileCollapseAnchor(theme: Theme) async throws {
    let files = tallPreparedFiles(20, rows: 36)
    try await withMountedList(files: files, theme: theme, size: NSSize(width: 600, height: 360)) { list in
        let anchoredRow = 8
        let rowRect = list.tableView.rect(ofRow: anchoredRow)
        let point = list.scrollView.documentView!.convert(
            NSPoint(x: 0, y: rowRect.midY), from: list.tableView
        )
        list.scrollView.contentView.scroll(to: NSPoint(x: 0, y: point.y))
        list.scrollView.reflectScrolledClipView(list.scrollView.contentView)
        await settleWindow(list.window!, list: list)
        try require(topVisibleFileID(in: list, files: files) == files[anchoredRow].id,
                    "the tall-file collapse fixture never placed its anchor file at the viewport top")

        list.configure(files: files, collapsedFiles: Set(files.map(\.id)), theme: theme, toggleFile: { _ in })
        await settleWindow(list.window!, list: list)
        try require(topVisibleFileID(in: list, files: files) == files[anchoredRow].id,
                    "collapsing the anchor's own tall body scrolled past that file's header")
    }
}

@MainActor
private func checkUnifiedAndSplitGeometry(theme: Theme) async throws {
    let unified = preparedFiles(1, longLineWords: 90)
    try await withMountedList(files: unified, theme: theme, size: NSSize(width: 300, height: 300)) { list in
        guard let text = editor(in: list, key: pane(for: unified[0]).contentKey),
              let horizontal = text.enclosingScrollView else {
            throw DiffFileListCheckFailure.failed("unified content did not get a native horizontal scroller")
        }
        try require(horizontal.hasHorizontalScroller && horizontal.horizontalScroller?.isHidden == false,
                    "a long unified line was not horizontally scrollable")
        if NSScroller.preferredScrollerStyle == .legacy {
            let band = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            try require(horizontal.frame.height >= text.frame.height + band - 0.5,
                        "the legacy horizontal scroller was omitted from the cached row geometry")
        }
    }

    let split = preparedFiles(1, layout: .split, longLineWords: 90)
    try await withMountedList(files: split, theme: theme, size: NSSize(width: 460, height: 300)) { list in
        let editors = descendants(of: list).compactMap { $0 as? DiffTextView }
        try require(editors.count == 2, "split content did not mount both native panes")
        let frames = editors.compactMap { editor -> NSRect? in
            guard let clip = editor.superview else { return nil }
            return clip.convert(clip.bounds, to: list)
        }.sorted { $0.minX < $1.minX }
        try require(frames.count == 2, "split content did not mount clipped native pane regions")
        try require(frames[0].maxX <= frames[1].minX,
                    "split panes overlap instead of clipping at their divider")
        try require(editors.allSatisfy {
            guard let clip = $0.superview else { return false }
            return clip.bounds.height + 0.5 >= $0.frame.height
        }, "a split clip truncates a pane's final text line")
        let perPaneScrolls = descendants(of: list).compactMap { $0 as? NSScrollView }
            .filter { $0 !== list.scrollView && $0.documentView is DiffTextView }
        try require(perPaneScrolls.isEmpty, "split panes unexpectedly gained unified horizontal scrollers")
    }
}

@MainActor
private func checkHeaderActionAndAllCollapse(theme: Theme) async throws {
    let files = preparedFiles(12)
    var toggledFile: String?
    try await withMountedList(files: files, theme: theme, toggleFile: { toggledFile = $0 }) { list in
        guard let button = headerButton(in: list) else {
            throw DiffFileListCheckFailure.failed("the visible file header has no native collapse button")
        }
        button.performClick(nil)
        try require(toggledFile == files[0].id,
                    "the native header action did not identify the file it toggled")

        let firstKey = pane(for: files[0]).contentKey
        list.configure(files: files, collapsedFiles: [files[0].id], theme: theme, toggleFile: { _ in })
        await settleWindow(list.window!, list: list)
        try require(editor(in: list, key: firstKey) == nil,
                    "the individual header-collapse action did not remove its file's editor")
        list.configure(files: files, collapsedFiles: [], theme: theme, toggleFile: { _ in })
        await settleWindow(list.window!, list: list)
        try require(editor(in: list, key: firstKey) != nil,
                    "expanding the individually collapsed file did not restore its editor")

        let expandedHeight = list.scrollView.documentView!.frame.height
        list.configure(files: files, collapsedFiles: Set(files.map(\.id)), theme: theme, toggleFile: { _ in })
        await settleWindow(list.window!, list: list)
        try require(descendants(of: list).compactMap { $0 as? DiffTextView }.isEmpty,
                    "collapsing all files left live text editors mounted")
        try require(list.scrollView.documentView!.frame.height < expandedHeight,
                    "collapsing all files did not reduce the native document extent")

        list.configure(files: files, collapsedFiles: [], theme: theme, toggleFile: { _ in })
        await settleWindow(list.window!, list: list)
        try require(!descendants(of: list).compactMap { $0 as? DiffTextView }.isEmpty,
                    "expanding all files did not restore visible native editors")
    }
}

@MainActor
private func checkResizePreservesVisibleState(theme: Theme) async throws {
    let files = preparedFiles(70, longLineWords: 30)
    try await withMountedList(files: files, theme: theme, size: NSSize(width: 300, height: 380)) { list in
        let firstKey = pane(for: files[0]).contentKey
        guard let first = editor(in: list, key: firstKey), let firstScroll = first.enclosingScrollView else {
            throw DiffFileListCheckFailure.failed("the narrow unified fixture did not mount its long-line editor")
        }
        try require(firstScroll.horizontalScroller?.isHidden == false,
                    "the narrow width did not expose a horizontal scroller")

        scrollToRow(30, in: list)
        await settleWindow(list.window!, list: list)
        let selectedKey = pane(for: files[30]).contentKey
        guard let selectedEditor = editor(in: list, key: selectedKey),
              let before = topVisibleFileID(in: list, files: files) else {
            throw DiffFileListCheckFailure.failed("the resize fixture did not realize its anchored file")
        }
        let selection = NSRange(location: 1, length: 4)
        selectedEditor.setSelectedRange(selection)
        list.window!.setContentSize(NSSize(width: 1_300, height: 380))
        await settleWindow(list.window!, list: list)
        try require(topVisibleFileID(in: list, files: files) == before,
                    "resizing across the horizontal-scroller threshold lost the visible-file anchor")
        try require(editor(in: list, key: selectedKey)?.selectedRange() == selection,
                    "resizing rebuilt the visible editor and lost its selection")

        scrollToRow(0, in: list)
        await settleWindow(list.window!, list: list)
        guard let widened = editor(in: list, key: firstKey)?.enclosingScrollView else {
            throw DiffFileListCheckFailure.failed("the widened long-line editor did not remount")
        }
        guard let widenedText = editor(in: list, key: firstKey) else {
            throw DiffFileListCheckFailure.failed("the widened geometry lost its long-line text view")
        }
        let horizontalRange = max(0, widenedText.frame.width - widened.contentView.bounds.width)
        try require(horizontalRange < 0.5,
                    "the widened geometry retained horizontal overflow " +
                    "(textWidth=\(widenedText.frame.width), clipWidth=\(widened.contentView.bounds.width), " +
                    "range=\(horizontalRange), scrollerHidden=\(String(describing: widened.horizontalScroller?.isHidden)))")
        try require(widened.contentView.bounds.height + 0.5 >= widenedText.frame.height,
                    "the widened geometry clipped the bottom of its text " +
                    "(textHeight=\(widenedText.frame.height), clipHeight=\(widened.contentView.bounds.height), " +
                    "scrollerHidden=\(String(describing: widened.horizontalScroller?.isHidden)))")
    }
}

@MainActor
private func checkViewportResizeDropsEmptyScrollRange(theme: Theme) async throws {
    let files = preparedFiles(3)
    try await withMountedList(files: files, collapsed: Set(files.map(\.id)), theme: theme,
                              size: NSSize(width: 600, height: 900)) { list in
        list.window!.setContentSize(NSSize(width: 600, height: 280))
        await settleWindow(list.window!, list: list)
        let slack = list.scrollView.documentView!.frame.height - list.scrollView.contentView.bounds.height
        try require(abs(slack) < 0.5,
                    "a height-only resize retained empty vertical scroll range for collapsed files")
    }
}

@MainActor
private func checkNewGenerationResetsSelection(theme: Theme) async throws {
    let oldFiles = preparedFiles(3, generation: 1)
    let newFiles = preparedFiles(3, generation: 2)
    try await withMountedList(files: oldFiles, theme: theme) { list in
        let oldKey = pane(for: oldFiles[0]).contentKey
        guard let oldEditor = editor(in: list, key: oldKey) else {
            throw DiffFileListCheckFailure.failed("the generation fixture did not mount its initial editor")
        }
        oldEditor.setSelectedRange(NSRange(location: 2, length: 3))
        list.configure(files: newFiles, collapsedFiles: [], theme: theme, toggleFile: { _ in })
        await settleWindow(list.window!, list: list)
        let newKey = pane(for: newFiles[0]).contentKey
        try require(editor(in: list, key: newKey)?.selectedRange() == NSRange(location: 0, length: 0),
                    "a new content generation inherited the previous file's selection")
    }
}

@MainActor
private func checkUnchangedConfigurationPreservesSelection(theme: Theme) async throws {
    let files = preparedFiles(3)
    try await withMountedList(files: files, theme: theme) { list in
        let key = pane(for: files[0]).contentKey
        guard let text = editor(in: list, key: key) else {
            throw DiffFileListCheckFailure.failed("the unchanged-configuration editor did not mount")
        }
        let selected = NSRange(location: 2, length: 4)
        text.setSelectedRange(selected)
        list.configure(files: files, collapsedFiles: [], theme: theme, toggleFile: { _ in })
        await settleWindow(list.window!, list: list)
        try require(editor(in: list, key: key)?.selectedRange() == selected,
                    "an unchanged configuration rebuilt the text and cleared its selection")
    }
}
