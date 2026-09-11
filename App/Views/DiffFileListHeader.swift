import AppKit
import OrchestraCore

/// Fixed-height native equivalent of the old SwiftUI file card header. It keeps the directory dimmed,
/// preserves the filename emphasis, and leaves one transparent button over the whole header so every
/// part of the row remains the collapse target.
@MainActor
final class DiffFileHeaderView: NSView {
    private let chevron = NSTextField(labelWithString: "")
    private let directory = NSTextField(labelWithString: "")
    private let filename = NSTextField(labelWithString: "")
    private let hunks = NSTextField(labelWithString: "")
    private let additions = DiffFileHeaderPill()
    private let deletions = DiffFileHeaderPill()
    private let button = NSButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        [chevron, directory, filename, hunks].forEach {
            $0.isBezeled = false
            $0.drawsBackground = false
            $0.isEditable = false
            $0.isSelectable = false
            addSubview($0)
        }
        chevron.alignment = .center
        chevron.font = .systemFont(ofSize: 11, weight: .semibold)
        directory.font = .systemFont(ofSize: 12, weight: .regular)
        filename.font = .systemFont(ofSize: 12, weight: .semibold)
        directory.lineBreakMode = .byTruncatingMiddle
        filename.lineBreakMode = .byTruncatingMiddle
        hunks.font = .systemFont(ofSize: 10, weight: .medium)
        addSubview(additions)
        addSubview(deletions)

        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(activate)
        addSubview(button)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(file: DiffFileSection, collapsed: Bool, palette: DiffTextPalette,
                   action: @escaping () -> Void) {
        self.action = action
        layer?.backgroundColor = palette.headerBackground.cgColor
        chevron.stringValue = collapsed ? "▸" : "▾"
        chevron.textColor = palette.gutterText
        configurePath(file.title, palette: palette)
        hunks.stringValue = file.hunks > 0 ? "\(file.hunks) \(file.hunks == 1 ? "hunk" : "hunks")" : ""
        hunks.textColor = palette.gutterText
        additions.configure(text: file.additions > 0 ? "+\(file.additions)" : "",
                            textColor: palette.addText, fill: palette.addTint)
        deletions.configure(text: file.deletions > 0 ? "−\(file.deletions)" : "",
                            textColor: palette.removeText, fill: palette.removeTint)
        button.setAccessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(file.title)")
        toolTip = file.title
        needsLayout = true
    }

    override func layout() {
        super.layout()
        button.frame = bounds
        chevron.frame = chevron.frame(forAlignmentRect: NSRect(x: 10, y: 8, width: 12, height: 18))
        var right = bounds.width - 12
        for view in [deletions, additions] where !view.isHidden {
            let width = view.fittingWidth
            view.frame = NSRect(x: right - width, y: 8, width: width, height: 18)
            right -= width + 8
        }
        if !hunks.stringValue.isEmpty {
            let width = ceil(hunks.intrinsicContentSize.width)
            hunks.frame = hunks.frame(forAlignmentRect:
                NSRect(x: right - width, y: 9, width: width, height: 16))
            right -= width + 10
        } else {
            hunks.frame = .zero
        }

        let pathLeft: CGFloat = 30
        let pathWidth = max(0, right - pathLeft)
        guard !directory.stringValue.isEmpty else {
            directory.frame = .zero
            filename.frame = filename.frame(forAlignmentRect:
                NSRect(x: pathLeft, y: 8, width: pathWidth, height: 18))
            return
        }
        let wantedDirectory = ceil(directory.intrinsicContentSize.width)
        let wantedFilename = ceil(filename.intrinsicContentSize.width)
        let directoryWidth: CGFloat
        let filenameWidth: CGFloat
        if wantedDirectory + wantedFilename <= pathWidth {
            directoryWidth = wantedDirectory
            filenameWidth = wantedFilename
        } else {
            let reservedFilename = min(wantedFilename, max(0, pathWidth * 0.5))
            directoryWidth = min(wantedDirectory, max(0, pathWidth - reservedFilename))
            filenameWidth = max(0, pathWidth - directoryWidth)
        }
        // NSTextField's intrinsic width describes its alignment rectangle. Manual frames must also
        // include the cell's side insets, or a label truncates even when its measured text fits.
        directory.frame = directory.frame(forAlignmentRect:
            NSRect(x: pathLeft, y: 8, width: directoryWidth, height: 18))
        filename.frame = filename.frame(forAlignmentRect:
            NSRect(x: pathLeft + directoryWidth, y: 8, width: filenameWidth, height: 18))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? button : nil
    }

    private func configurePath(_ path: String, palette: DiffTextPalette) {
        if let slash = path.lastIndex(of: "/") {
            directory.stringValue = String(path[...slash])
            filename.stringValue = String(path[path.index(after: slash)...])
        } else {
            directory.stringValue = ""
            filename.stringValue = path
        }
        directory.textColor = palette.gutterText
        filename.textColor = palette.code
    }

    @objc private func activate() {
        action?()
    }
}

@MainActor
private final class DiffFileHeaderPill: NSView {
    private let label = NSTextField(labelWithString: "")

    var fittingWidth: CGFloat { ceil(label.intrinsicContentSize.width) + 12 }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(text: String, textColor: NSColor, fill: NSColor) {
        isHidden = text.isEmpty
        label.stringValue = text
        label.textColor = textColor
        layer?.backgroundColor = fill.cgColor
    }

    override func layout() {
        super.layout()
        label.frame = label.frame(forAlignmentRect: bounds.insetBy(dx: 6, dy: 1))
    }
}
