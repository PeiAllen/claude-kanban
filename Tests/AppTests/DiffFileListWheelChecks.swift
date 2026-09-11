import AppKit
import Foundation
import OrchestraCore
import OrchestraUI

/// Exercises NSWindow's actual wheel-event route. Calling an outer scroll view directly would miss
/// the nested horizontal scroller that AppKit hits first over unified text.
@MainActor
func runDiffFileListWheelChecks(theme: Theme) async throws {
    try await checkUnifiedWheelRouting(theme: theme)
    try await checkSplitVerticalWheelRouting(theme: theme)
}

private enum DiffFileListWheelCheckFailure: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

private func requireWheel(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw DiffFileListWheelCheckFailure.failed(message) }
}

private func wheelFiles(_ count: Int, layout: DiffTextLayout) -> [DiffPreparedFile] {
    let patch = (0..<count).map { index -> String in
        let body = (0..<36).map { line -> String in
            let value = line == 0 ? String(repeating: "wide-", count: 120) : "\(line)"
            switch layout {
            case .unified:
                return "+let value\(line) = \"\(value)\""
            case .split:
                return "-let previous\(line) = \"\(value)\"\n+let current\(line) = \"\(value)\""
            }
        }.joined(separator: "\n")
        return """
        diff --git a/Sources/Wheel\(index).swift b/Sources/Wheel\(index).swift
        --- a/Sources/Wheel\(index).swift
        +++ b/Sources/Wheel\(index).swift
        @@ -1,36 +1,36 @@
        \(body)
        """
    }.joined(separator: "\n")
    return DiffPrepared.make(DiffFileParser.parse(patch), layout: layout, generation: 1)
}

@MainActor
private func withWheelList<T>(files: [DiffPreparedFile], theme: Theme,
                              _ body: (DiffFileListView, NSWindow) async throws -> T) async rethrows -> T {
    let list = DiffFileListView()
    list.configure(files: files, collapsedFiles: [], theme: theme, toggleFile: { _ in })
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 360, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.contentView = list
    window.orderFront(nil)
    await settleWheelWindow(window, list: list)
    defer { window.orderOut(nil) }
    return try await body(list, window)
}

@MainActor
private func settleWheelWindow(_ window: NSWindow, list: DiffFileListView) async {
    for _ in 0..<2 {
        window.displayIfNeeded()
        list.layoutSubtreeIfNeeded()
        list.tableView.layoutSubtreeIfNeeded()
        try? await _Concurrency.Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor
private func waitForWheelOffset(_ window: NSWindow, list: DiffFileListView,
                                until condition: () -> Bool) async -> Bool {
    for _ in 0..<25 {
        window.displayIfNeeded()
        list.layoutSubtreeIfNeeded()
        list.tableView.layoutSubtreeIfNeeded()
        if condition() { return true }
        try? await _Concurrency.Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func sendWheel(to text: DiffTextView, in window: NSWindow, vertical: Int32, horizontal: Int32 = 0,
                       shift: Bool = false, units: CGScrollEventUnit = .pixel) throws -> NSEvent {
    let visible = text.visibleRect
    let point = text.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens.first else {
        throw DiffFileListWheelCheckFailure.failed("the private wheel test window has no screen")
    }
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                     wheel1: vertical, wheel2: horizontal, wheel3: 0)!
    if shift { cg.flags.insert(.maskShift) }
    cg.location = NSPoint(x: point.x, y: screen.frame.maxY - point.y)
    guard let event = NSEvent(cgEvent: cg) else {
        throw DiffFileListWheelCheckFailure.failed("could not bridge the private wheel event")
    }
    try requireWheel(abs(event.locationInWindow.x - point.x) < 0.5 &&
                     abs(event.locationInWindow.y - point.y) < 0.5,
                     "the private wheel event did not retain its text-pane coordinates")
    window.sendEvent(event)
    return event
}

@MainActor
private func resetWheelPosition(_ scrollView: NSScrollView, x: CGFloat = 0, y: CGFloat = 0) {
    scrollView.contentView.scroll(to: NSPoint(x: x, y: y))
    scrollView.reflectScrolledClipView(scrollView.contentView)
}

@MainActor
private func wheelDescendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(wheelDescendants)
}

@MainActor
private func wheelText(in list: DiffFileListView) -> DiffTextView? {
    wheelDescendants(of: list).compactMap { $0 as? DiffTextView }.first {
        !$0.visibleRect.isEmpty
    }
}

@MainActor
private func checkUnifiedWheelRouting(theme: Theme) async throws {
    let files = wheelFiles(24, layout: .unified)
    try await withWheelList(files: files, theme: theme) { list, window in
        guard let text = wheelText(in: list), let horizontal = text.enclosingScrollView else {
            throw DiffFileListWheelCheckFailure.failed("the unified wheel fixture did not mount its text scroller")
        }
        let outer = list.scrollView
        let outerLimit = outer.documentView!.frame.height - outer.contentView.bounds.height
        try requireWheel(outerLimit > 100, "the unified wheel fixture has no vertical outer scroll range")
        let horizontalLimit = text.frame.width - horizontal.contentView.bounds.width
        try requireWheel(horizontalLimit > 100, "the unified wheel fixture has no horizontal inner scroll range")

        resetWheelPosition(outer)
        resetWheelPosition(horizontal)
        await settleWheelWindow(window, list: list)
        let beforeVertical = outer.contentView.bounds.origin
        let vertical = try sendWheel(to: text, in: window, vertical: -100)
        try requireWheel(abs(vertical.scrollingDeltaY) > 0.5 && abs(vertical.scrollingDeltaX) < 0.5 &&
                         !vertical.modifierFlags.contains(.shift),
                         "the vertical wheel fixture did not produce a vertical-only event")
        let verticalMoved = await waitForWheelOffset(window, list: list) {
            outer.contentView.bounds.origin.y > beforeVertical.y + 0.5
        }
        try requireWheel(verticalMoved,
                         "a vertical wheel over unified text did not move the outer file scroller")
        try requireWheel(abs(horizontal.contentView.bounds.origin.x) < 0.5,
                         "a vertical wheel over unified text moved the horizontal pane")

        resetWheelPosition(outer)
        resetWheelPosition(horizontal, x: horizontalLimit / 2)
        await settleWheelWindow(window, list: list)
        let beforeHorizontal = horizontal.contentView.bounds.origin
        let horizontalEvent = try sendWheel(to: text, in: window, vertical: 0, horizontal: -100)
        try requireWheel(abs(horizontalEvent.scrollingDeltaX) > 0.5 &&
                         abs(horizontalEvent.scrollingDeltaY) < 0.5,
                         "the horizontal wheel fixture did not produce a horizontal-only event")
        let horizontalMoved = await waitForWheelOffset(window, list: list) {
            abs(horizontal.contentView.bounds.origin.x - beforeHorizontal.x) > 0.5
        }
        try requireWheel(abs(outer.contentView.bounds.origin.y) < 0.5,
                         "a horizontal wheel over unified text moved the outer file scroller")
        try requireWheel(horizontalMoved, "a horizontal wheel over unified text did not move its pane")

        resetWheelPosition(outer)
        resetWheelPosition(horizontal, x: horizontalLimit / 2)
        await settleWheelWindow(window, list: list)
        let beforeShift = horizontal.contentView.bounds.origin
        let shiftEvent = try sendWheel(to: text, in: window, vertical: -3, shift: true, units: .line)
        try requireWheel(shiftEvent.modifierFlags.contains(.shift) && abs(shiftEvent.scrollingDeltaX) > 0.5 &&
                         abs(shiftEvent.scrollingDeltaY) < 0.5,
                         "the Shift-wheel fixture did not become a native horizontal event")
        let shiftMoved = await waitForWheelOffset(window, list: list) {
            abs(horizontal.contentView.bounds.origin.x - beforeShift.x) > 0.5
        }
        try requireWheel(abs(outer.contentView.bounds.origin.y) < 0.5,
                         "a Shift-wheel over unified text moved the outer file scroller")
        try requireWheel(shiftMoved, "a Shift-wheel over unified text did not move its horizontal pane")

        resetWheelPosition(outer)
        resetWheelPosition(horizontal, x: horizontalLimit / 2)
        await settleWheelWindow(window, list: list)
        let beforeDiagonal = horizontal.contentView.bounds.origin
        let diagonal = try sendWheel(to: text, in: window, vertical: -100, horizontal: -100)
        try requireWheel(abs(diagonal.scrollingDeltaY) > 0.5 && abs(diagonal.scrollingDeltaX) > 0.5 &&
                         !diagonal.modifierFlags.contains(.shift),
                         "the diagonal wheel fixture did not retain both native deltas")
        let diagonalMoved = await waitForWheelOffset(window, list: list) {
            outer.contentView.bounds.origin.y > 0.5 &&
            abs(horizontal.contentView.bounds.origin.x - beforeDiagonal.x) > 0.5
        }
        try requireWheel(diagonalMoved,
                         "a diagonal wheel over unified text did not move the outer file scroller")
    }
}

@MainActor
private func checkSplitVerticalWheelRouting(theme: Theme) async throws {
    let files = wheelFiles(24, layout: .split)
    try await withWheelList(files: files, theme: theme) { list, window in
        guard let text = wheelText(in: list) else {
            throw DiffFileListWheelCheckFailure.failed("the split wheel fixture did not mount a visible text pane")
        }
        let outer = list.scrollView
        let outerLimit = outer.documentView!.frame.height - outer.contentView.bounds.height
        try requireWheel(outerLimit > 100, "the split wheel fixture has no vertical outer scroll range")
        resetWheelPosition(outer)
        await settleWheelWindow(window, list: list)
        let vertical = try sendWheel(to: text, in: window, vertical: -100)
        try requireWheel(abs(vertical.scrollingDeltaY) > 0.5 && abs(vertical.scrollingDeltaX) < 0.5,
                         "the split wheel fixture did not produce a vertical-only event")
        let splitMoved = await waitForWheelOffset(window, list: list) {
            outer.contentView.bounds.origin.y > 0.5
        }
        try requireWheel(splitMoved,
                         "a vertical wheel over split text did not move the outer file scroller")
    }
}
