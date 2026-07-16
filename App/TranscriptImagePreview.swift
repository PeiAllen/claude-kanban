import AppKit
import Foundation
import OrchestraKit

/// Bounded local exports for the macOS Open action. These copies are intentionally independent of the
/// daemon's session media: another image app may still be decoding a file after the transcript popover
/// has closed or the originating session has expired.
enum TranscriptImagePreviewCache {
    private static let maxAge: TimeInterval = 7 * 86_400
    private static let maxBytes = 256 * 1024 * 1024

    static func pruneAtLaunch() {
        prune(now: Date())
    }

    @discardableResult
    static func materialize(data: Data, mimeType: String) throws -> URL {
        let directory = try cacheDirectory()
        prune(directory: directory, now: Date())

        let url = directory
            .appendingPathComponent(UUID().uuidString.lowercased())
            .appendingPathExtension(fileExtension(for: mimeType))
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func cacheDirectory() throws -> URL {
        let manager = FileManager.default
        guard let applicationSupport = manager.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask).first
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = applicationSupport
            .appendingPathComponent("Orchestra", isDirectory: true)
            .appendingPathComponent("TranscriptImagePreviews", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/png": "png"
        case "image/jpeg": "jpg"
        default: "png" // The presenter validates MIME before an export can reach this point.
        }
    }

    private static func prune(now: Date) {
        guard let directory = try? cacheDirectory() else { return }
        prune(directory: directory, now: now)
    }

    private static func prune(directory: URL, now: Date) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = try? manager.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: Array(keys),
                                                           options: [.skipsHiddenFiles])
        else { return }

        let entries = files.compactMap { url -> TranscriptImageCacheEntry? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modifiedAt = values.contentModificationDate
            else { return nil }
            return TranscriptImageCacheEntry(url: url, byteCount: size, modifiedAt: modifiedAt)
        }

        for url in TranscriptImageCachePolicy.filesToRemove(entries: entries, now: now,
                                                             maxAge: maxAge, maxBytes: maxBytes) {
            try? manager.removeItem(at: url)
        }
    }
}

/// The transient macOS preview for an opaque transcript image reference. It owns no daemon path: its
/// only inputs are the reference UUID and the app client's bounded media payload.
@MainActor
final class TranscriptImagePreviewPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var loadTask: _Concurrency.Task<Void, Never>?
    private var requestID: UUID?

    func show(referenceID: UUID, from terminal: NSView, anchor: NSPoint,
              load: @escaping (UUID) async throws -> TranscriptImagePayload) {
        dismiss()

        let content = TranscriptImagePreviewContentController()
        content.showLoading()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = content
        popover.contentSize = content.preferredContentSize

        self.popover = popover
        let requestID = UUID()
        self.requestID = requestID
        popover.show(relativeTo: activationRect(anchor, in: terminal), of: terminal, preferredEdge: .maxY)

        loadTask = _Concurrency.Task { @MainActor [weak self, weak content] in
            do {
                let payload = try await load(referenceID)
                guard !_Concurrency.Task.isCancelled,
                      let self,
                      self.requestID == requestID,
                      let content
                else { return }

                let validated = try Self.validatedImage(from: payload, expectedReferenceID: referenceID)
                guard !_Concurrency.Task.isCancelled, self.requestID == requestID else { return }
                content.showImage(image: validated.image, data: validated.data, mimeType: payload.reference.mimeType,
                                  caption: payload.reference.caption)
                self.popover?.contentSize = content.preferredContentSize
            } catch is CancellationError {
                // Closing or replacing a popover cancels the pending fetch without terminal feedback.
            } catch {
                guard let self, self.requestID == requestID, !_Concurrency.Task.isCancelled, let content else { return }
                content.showError()
                self.popover?.contentSize = content.preferredContentSize
            }
        }
    }

    func dismiss() {
        loadTask?.cancel()
        loadTask = nil
        requestID = nil
        let closingPopover = popover
        popover = nil
        closingPopover?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover, closedPopover === popover else { return }
        loadTask?.cancel()
        loadTask = nil
        requestID = nil
        popover = nil
    }

    private func activationRect(_ anchor: NSPoint, in terminal: NSView) -> NSRect {
        let x = min(max(anchor.x, terminal.bounds.minX), terminal.bounds.maxX)
        let y = min(max(anchor.y, terminal.bounds.minY), terminal.bounds.maxY)
        return NSRect(x: x, y: y, width: 1, height: 1)
    }

    private static func validatedImage(from payload: TranscriptImagePayload,
                                       expectedReferenceID: UUID) throws -> (image: NSImage, data: Data) {
        guard payload.reference.id == expectedReferenceID,
              payload.reference.mimeType == "image/png" || payload.reference.mimeType == "image/jpeg",
              let data = Data(base64Encoded: payload.dataBase64),
              !data.isEmpty,
              let image = NSImage(data: data),
              image.size.width > 0,
              image.size.height > 0
        else {
            throw TranscriptImagePreviewError.expired
        }
        return (image, data)
    }
}

private enum TranscriptImagePreviewError: Error {
    case expired
}

@MainActor
private final class TranscriptImagePreviewContentController: NSViewController {
    private let contentSize = NSSize(width: 540, height: 430)
    private var image: NSImage?
    private var imageData: Data?
    private var mimeType: String?
    private var scrollView: NSScrollView?
    private var copyButton: NSButton?
    private var fitScale: CGFloat = 1

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: contentSize))
        preferredContentSize = contentSize
    }

    func showLoading() {
        clear()
        preferredContentSize = NSSize(width: 220, height: 72)
        view.frame.size = preferredContentSize

        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 27, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        view.addSubview(spinner)

        let label = NSTextField(labelWithString: "Loading image preview…")
        label.font = .systemFont(ofSize: 12)
        label.frame = NSRect(x: 46, y: 25, width: 158, height: 20)
        view.addSubview(label)
    }

    func showError() {
        clear()
        preferredContentSize = NSSize(width: 220, height: 72)
        view.frame.size = preferredContentSize

        let label = NSTextField(wrappingLabelWithString: "Image preview expired")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.frame = NSRect(x: 16, y: 24, width: 188, height: 24)
        view.addSubview(label)
    }

    func showImage(image: NSImage, data: Data, mimeType: String, caption: String) {
        clear()
        self.image = image
        imageData = data
        self.mimeType = mimeType
        preferredContentSize = contentSize
        view.frame.size = contentSize

        let captionLabel = NSTextField(wrappingLabelWithString: caption.isEmpty ? "Image" : caption)
        captionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.maximumNumberOfLines = 2
        captionLabel.frame = NSRect(x: 16, y: 390, width: 508, height: 26)
        view.addSubview(captionLabel)

        // Magnification and panning are NSScrollView's own: pinch-to-zoom and scroll/trackpad panning
        // come free, which is what a Mac user reaches for inside a popover.
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 62, width: 508, height: 316))
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder
        scrollView.allowsMagnification = true

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        scrollView.documentView = imageView
        view.addSubview(scrollView)
        self.scrollView = scrollView

        let minus = button(title: "−", action: #selector(zoomOut))
        minus.frame = NSRect(x: 16, y: 16, width: 28, height: 28)
        view.addSubview(minus)

        let fit = button(title: "Fit", action: #selector(zoomToFit))
        fit.frame = NSRect(x: 48, y: 16, width: 42, height: 28)
        view.addSubview(fit)

        let plus = button(title: "+", action: #selector(zoomIn))
        plus.frame = NSRect(x: 94, y: 16, width: 28, height: 28)
        view.addSubview(plus)

        let copy = button(title: "Copy", action: #selector(copyImage))
        copy.frame = NSRect(x: 390, y: 16, width: 60, height: 28)
        view.addSubview(copy)
        copyButton = copy

        let open = button(title: "Open", action: #selector(openImage))
        open.frame = NSRect(x: 456, y: 16, width: 68, height: 28)
        view.addSubview(open)

        configureMagnification(for: image, in: scrollView)
    }

    @objc private func zoomOut() {
        guard let scrollView else { return }
        setMagnification(max(fitScale, scrollView.magnification / 1.25), in: scrollView)
    }

    @objc private func zoomToFit() {
        guard let scrollView else { return }
        setMagnification(fitScale, in: scrollView)
    }

    @objc private func zoomIn() {
        guard let scrollView else { return }
        setMagnification(min(scrollView.maxMagnification, scrollView.magnification * 1.25), in: scrollView)
    }

    @objc private func copyImage() {
        guard let image, let imageData, let mimeType, let copyData = pngData(image: image,
                                                                               sourceData: imageData,
                                                                               mimeType: mimeType)
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(copyData, forType: .png) else { return }
        copyButton?.title = "Copied"
        _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(1))
            guard !_Concurrency.Task.isCancelled else { return }
            self?.copyButton?.title = "Copy"
        }
    }

    @objc private func openImage() {
        guard let imageData, let mimeType,
              let url = try? TranscriptImagePreviewCache.materialize(data: imageData, mimeType: mimeType)
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func clear() {
        view.subviews.forEach { $0.removeFromSuperview() }
        image = nil
        imageData = nil
        mimeType = nil
        scrollView = nil
        copyButton = nil
    }

    private func configureMagnification(for image: NSImage, in scrollView: NSScrollView) {
        let viewport = scrollView.contentSize
        guard image.size.width > 0, image.size.height > 0,
              viewport.width > 0, viewport.height > 0
        else { return }
        fitScale = min(viewport.width / image.size.width, viewport.height / image.size.height)
        let nativeScale = image.representations.compactMap { representation -> CGFloat? in
            guard representation.pixelsWide > 0, image.size.width > 0 else { return nil }
            return CGFloat(representation.pixelsWide) / image.size.width
        }.max() ?? 1
        scrollView.minMagnification = fitScale
        scrollView.maxMagnification = max(8 * fitScale, nativeScale)
        setMagnification(fitScale, in: scrollView)
    }

    private func setMagnification(_ scale: CGFloat, in scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else { return }
        let center = NSPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
        scrollView.setMagnification(scale, centeredAt: center)
    }

    private func pngData(image: NSImage, sourceData: Data, mimeType: String) -> Data? {
        if mimeType == "image/png" { return sourceData }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func button(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }
}
