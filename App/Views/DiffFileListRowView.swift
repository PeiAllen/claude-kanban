import AppKit
import OrchestraCore
import OrchestraUI

enum DiffFileBody {
    case unified(DiffPreparedText)
    case split(left: DiffPreparedText, right: DiffPreparedText)

    var contentKeys: [String] {
        switch self {
        case .unified(let document): return [document.contentKey]
        case .split(let left, let right): return [left.contentKey, right.contentKey]
        }
    }

    var documents: [DiffPreparedText] {
        switch self {
        case .unified(let document): return [document]
        case .split(let left, let right): return [left, right]
        }
    }
}

struct DiffFileListRecord {
    static let headerHeight: CGFloat = 34
    static let dividerHeight: CGFloat = 0.5
    static let gap: CGFloat = 10
    static let horizontalInset: CGFloat = 10
    static let verticalInset: CGFloat = 10

    let file: DiffPreparedFile
    let body: DiffFileBody
    var collapsed: Bool
    var geometry: DiffFileRowGeometry = .collapsed
}

enum DiffFileRowGeometry {
    case collapsed
    case unified(textHeight: CGFloat, documentWidth: CGFloat, bodyHeight: CGFloat)
    case split(leftHeight: CGFloat, rightHeight: CGFloat)

    var rowHeight: CGFloat {
        switch self {
        case .collapsed:
            DiffFileListRecord.headerHeight
        case .unified(_, _, let bodyHeight):
            DiffFileListRecord.headerHeight + bodyHeight
        case .split(let left, let right):
            DiffFileListRecord.headerHeight + max(left, right)
        }
    }

    var bodyHeight: CGFloat {
        switch self {
        case .collapsed: 0
        case .unified(_, _, let height): height
        case .split(let left, let right): max(left, right)
        }
    }
}

struct DiffTextViewState {
    let selection: NSRange
    let horizontalOffset: CGFloat
}

/// A unified diff pane owns horizontal scrolling only. AppKit otherwise stops a vertical wheel at
/// this nested NSScrollView even though its vertical document exactly fits, so forward that component
/// to the table's outer vertical owner. Non-Shift events go to both native scrollers: each ignores the
/// unsupported axis, which also keeps zero-delta gesture lifecycle events available to the outer owner.
/// Shift-wheel stays entirely in AppKit's standard horizontal-scrolling path.
@MainActor
private final class DiffFileListHorizontalScrollView: NSScrollView {
    weak var verticalScrollView: NSScrollView?

    override func scrollWheel(with event: NSEvent) {
        let shiftRequestsHorizontalScroll = event.modifierFlags.contains(.shift)
        guard !shiftRequestsHorizontalScroll, let verticalScrollView else {
            super.scrollWheel(with: event)
            return
        }

        verticalScrollView.scrollWheel(with: event)
        super.scrollWheel(with: event)
    }
}

@MainActor
final class DiffFileRowView: NSView {
    private let header = DiffFileHeaderView(frame: .zero)
    private let divider = NSView(frame: .zero)
    private var unifiedScroll: DiffFileListHorizontalScrollView?
    private var unifiedText: DiffTextView?
    private var splitLeftClip: NSView?
    private var splitRightClip: NSView?
    private var splitLeftText: DiffTextView?
    private var splitRightText: DiffTextView?
    private var splitDivider: NSView?
    private var record: DiffFileListRecord?
    private var palette: DiffTextPalette?
    private var saveState: ((String, DiffTextViewState) -> Void)?
    private var pendingOffsets: [String: CGFloat] = [:]
    private var stateCapturedOnRemoval = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        divider.wantsLayer = true
        addSubview(header)
        addSubview(divider)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(record: DiffFileListRecord, palette: DiffTextPalette,
                   savedState: (String) -> DiffTextViewState?,
                   saveState: @escaping (String, DiffTextViewState) -> Void,
                   toggleFile: @escaping (String) -> Void) {
        let bodyChanged = self.record?.body.contentKeys != record.body.contentKeys
        let restoreDetachedBody = !bodyChanged && stateCapturedOnRemoval
        if bodyChanged {
            if !stateCapturedOnRemoval {
                captureTextState()
            }
            pendingOffsets.removeAll()
        }
        self.record = record
        self.palette = palette
        self.saveState = saveState
        layer?.borderWidth = 0.5
        layer?.borderColor = palette.hair.cgColor
        header.configure(file: record.file.section, collapsed: record.collapsed, palette: palette) {
            toggleFile(record.file.id)
        }
        divider.layer?.backgroundColor = palette.hair.cgColor

        if record.collapsed {
            removeBodyViews()
        } else {
            configureBody(record.body, geometry: record.geometry, palette: palette, savedState: savedState,
                          restoreDetachedBody: restoreDetachedBody)
        }
        // The hairline overlays the body's 4pt text inset. Keeping the body on an integral origin
        // avoids NSClipView expanding an 86pt document to 87pt when it is tiled at y=34.5.
        addSubview(divider, positioned: .above, relativeTo: nil)
        stateCapturedOnRemoval = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let record else { return }
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: DiffFileListRecord.headerHeight)
        let bodyY = DiffFileListRecord.headerHeight
        divider.frame = NSRect(x: 0, y: bodyY, width: bounds.width,
                               height: record.collapsed ? 0 : DiffFileListRecord.dividerHeight)
        guard !record.collapsed else { return }

        let contentY = bodyY
        switch record.geometry {
        case .unified(let textHeight, let documentWidth, let bodyHeight):
            guard let scroll = unifiedScroll, let text = unifiedText else { return }
            scroll.frame = NSRect(x: 0, y: contentY, width: bounds.width, height: bodyHeight)
            text.frame = NSRect(x: 0, y: 0, width: documentWidth, height: textHeight)
            scroll.verticalScrollView = outerScrollView(excluding: scroll)
            restorePendingOffset(for: text, in: scroll)
        case .split:
            layoutSplitBody(y: contentY, height: record.geometry.bodyHeight)
        case .collapsed:
            break
        }
    }

    func captureTextState() {
        capture(text: unifiedText, scroll: unifiedScroll)
        capture(text: splitLeftText, scroll: nil)
        capture(text: splitRightText, scroll: nil)
    }

    func captureTextStateForRemoval() {
        guard !stateCapturedOnRemoval else { return }
        captureTextState()
        stateCapturedOnRemoval = true
    }

    private func capture(text: DiffTextView?, scroll: NSScrollView?) {
        guard let text, let key = text.appliedKey else { return }
        saveState?(key, DiffTextViewState(selection: text.selectedRange(),
                                          horizontalOffset: scroll?.contentView.bounds.origin.x ?? 0))
    }

    private func configureBody(_ body: DiffFileBody, geometry: DiffFileRowGeometry,
                               palette: DiffTextPalette,
                               savedState: (String) -> DiffTextViewState?,
                               restoreDetachedBody: Bool) {
        switch (body, geometry) {
        case (.unified(let document), .unified):
            removeSplitViews()
            let (scroll, text) = ensureUnifiedView()
            apply(document: document, to: text, palette: palette, savedState: savedState,
                  horizontalScroll: scroll, restoreDetachedBody: restoreDetachedBody)
        case (.split(let left, let right), .split):
            removeUnifiedView()
            let (leftText, rightText) = ensureSplitViews()
            apply(document: left, to: leftText, palette: palette, savedState: savedState,
                  horizontalScroll: nil, restoreDetachedBody: restoreDetachedBody)
            apply(document: right, to: rightText, palette: palette, savedState: savedState,
                  horizontalScroll: nil, restoreDetachedBody: restoreDetachedBody)
        default:
            break
        }
    }

    private func apply(document: DiffPreparedText, to text: DiffTextView, palette: DiffTextPalette,
                       savedState: (String) -> DiffTextViewState?, horizontalScroll: NSScrollView?,
                       restoreDetachedBody: Bool) {
        let changed = text.apply(document: document, palette: palette)
        guard changed || restoreDetachedBody else { return }
        let state = savedState(document.contentKey)
        if let state {
            text.setSelectedRange(clamped(state.selection, length: (text.string as NSString).length))
            if horizontalScroll != nil { pendingOffsets[document.contentKey] = state.horizontalOffset }
        } else {
            text.setSelectedRange(NSRange(location: 0, length: 0))
            if horizontalScroll != nil { pendingOffsets[document.contentKey] = 0 }
        }
    }

    private func clamped(_ selection: NSRange, length: Int) -> NSRange {
        let location = min(max(0, selection.location), length)
        return NSRange(location: location, length: min(selection.length, length - location))
    }

    private func restorePendingOffset(for text: DiffTextView, in scroll: NSScrollView) {
        guard let key = text.appliedKey, let requested = pendingOffsets.removeValue(forKey: key) else { return }
        let maxX = max(0, text.frame.width - scroll.contentView.bounds.width)
        scroll.contentView.scroll(to: NSPoint(x: min(max(0, requested), maxX), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func ensureUnifiedView() -> (DiffFileListHorizontalScrollView, DiffTextView) {
        if let unifiedScroll, let unifiedText { return (unifiedScroll, unifiedText) }
        let text = DiffTextView.makeConfiguredTextView()
        let scroll = DiffFileListHorizontalScrollView(frame: .zero)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        // A diagonal trackpad event must retain its horizontal component even while the outer owner
        // consumes the vertical component.
        scroll.usesPredominantAxisScrolling = false
        scroll.documentView = text
        addSubview(scroll)
        unifiedScroll = scroll
        unifiedText = text
        return (scroll, text)
    }

    private func outerScrollView(excluding nestedScroll: NSScrollView) -> NSScrollView? {
        var candidate = nestedScroll.superview
        while let view = candidate {
            if let scrollView = view as? NSScrollView, scrollView !== nestedScroll {
                return scrollView
            }
            candidate = view.superview
        }
        return nil
    }

    private func ensureSplitViews() -> (DiffTextView, DiffTextView) {
        if let splitLeftText, let splitRightText { return (splitLeftText, splitRightText) }
        let leftClip = clippedContainer()
        let rightClip = clippedContainer()
        let leftText = DiffTextView.makeConfiguredTextView()
        let rightText = DiffTextView.makeConfiguredTextView()
        let divider = NSView(frame: .zero)
        divider.wantsLayer = true
        leftClip.addSubview(leftText)
        rightClip.addSubview(rightText)
        addSubview(leftClip)
        addSubview(divider)
        addSubview(rightClip)
        splitLeftClip = leftClip
        splitRightClip = rightClip
        splitLeftText = leftText
        splitRightText = rightText
        splitDivider = divider
        return (leftText, rightText)
    }

    private func clippedContainer() -> NSView {
        let clip = NSView(frame: .zero)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        return clip
    }

    private func layoutSplitBody(y: CGFloat, height: CGFloat) {
        guard let leftClip = splitLeftClip, let rightClip = splitRightClip,
              let left = splitLeftText, let right = splitRightText, let divider = splitDivider else { return }
        let dividerWidth: CGFloat = 0.5
        let leftWidth = max(0, (bounds.width - dividerWidth) / 2)
        let rightWidth = max(0, bounds.width - leftWidth - dividerWidth)
        leftClip.frame = NSRect(x: 0, y: y, width: leftWidth, height: height)
        divider.frame = NSRect(x: leftWidth, y: y, width: dividerWidth, height: height)
        divider.layer?.backgroundColor = palette?.hair.cgColor
        rightClip.frame = NSRect(x: leftWidth + dividerWidth, y: y, width: rightWidth, height: height)
        left.frame = NSRect(x: 0, y: 0, width: leftWidth, height: height)
        right.frame = NSRect(x: 0, y: 0, width: rightWidth, height: height)
    }

    private func removeBodyViews() {
        removeUnifiedView()
        removeSplitViews()
    }

    private func removeUnifiedView() {
        unifiedScroll?.removeFromSuperview()
        unifiedScroll = nil
        unifiedText = nil
    }

    private func removeSplitViews() {
        splitLeftClip?.removeFromSuperview()
        splitRightClip?.removeFromSuperview()
        splitDivider?.removeFromSuperview()
        splitLeftClip = nil
        splitRightClip = nil
        splitLeftText = nil
        splitRightText = nil
    }
}
