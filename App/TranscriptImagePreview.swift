import AppKit
import Quartz
import Foundation
import OrchestraKit

/// Where a transcript image is staged so QuickLook can preview it.
///
/// QuickLook previews a *file*, so the daemon's bytes cannot stay in memory — and the same staged file
/// is what `Open with` or a drag out of the panel hands to another application, which may still be
/// reading it after the panel closes. That rules out deleting on dismiss.
///
/// It is not a cache: nothing is ever read back. The sweep is therefore not an eviction policy but two
/// coarse boundaries — the whole spool is wiped at launch, and a card's subdirectory when that card is
/// archived (the same boundary the daemon applies to its own copy). Both sit far from the only window
/// that matters, between staging and the receiving app reading the URL; and deleting a file another app
/// already holds open is safe regardless, since unlink keeps the inode alive for open descriptors.
enum TranscriptImagePreviewSpool {
    private static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptImageExports", isDirectory: true)
    }

    /// Nothing survives a launch: a staged file only ever needs to outlive the app session that made it.
    static func wipeAtLaunch() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A card's media dies with the card, so its staged files do too.
    static func removeExports(cardId: UUID) {
        try? FileManager.default.removeItem(at: cardDirectory(cardId))
    }

    /// The caption is the filename because `TranscriptImageCaption` constrained it to a legal one at the
    /// `publish-image` boundary — that validation is what lets agent text reach a path with no sanitizing
    /// here. Uniqueness comes from a UUID *directory* rather than a UUID filename, so two images sharing a
    /// caption cannot collide while QuickLook's title bar still shows the human a real name.
    static func materialize(data: Data, mimeType: String, caption: String, cardId: UUID) throws -> URL {
        let directory = cardDirectory(cardId).appendingPathComponent(UUID().uuidString.lowercased(),
                                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = TranscriptImageCaption.isValid(caption) ? caption : "image"
        let url = directory
            .appendingPathComponent(stem)
            .appendingPathExtension(fileExtension(for: mimeType))
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func cardDirectory(_ cardId: UUID) -> URL {
        root.appendingPathComponent(cardId.uuidString.lowercased(), isDirectory: true)
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/jpeg": "jpg"
        default: "png" // The presenter validates MIME before staging.
        }
    }
}

private final class TranscriptPreviewItem: NSObject, QLPreviewItem {
    var previewItemURL: URL?
    var previewItemTitle: String?
}

private enum TranscriptImagePreviewError: Error {
    case expired
}

/// Presents an opaque transcript image reference in **QuickLook** — the same viewer Space bar opens
/// anywhere else on the Mac, so zoom, pan, share, Open with, full screen, and Esc-to-dismiss are the
/// system's rather than ours. It owns no daemon path: its only inputs are the reference UUID and the
/// app client's bounded media payload.
///
/// The panel is deliberately NOT dismissed when the terminal scrolls: it is a viewer you can leave up
/// and read the transcript alongside, not a popover tethered to one line.
@MainActor
final class TranscriptImagePreviewPresenter: NSObject {
    fileprivate var previewItem: TranscriptPreviewItem?
    private var loadTask: _Concurrency.Task<Void, Never>?
    private var requestID: UUID?
    private weak var anchorView: NSView?

    /// Reports a reference that can no longer be resolved. QuickLook has no notion of "expired" and an
    /// empty panel would read as a broken app, so the failure surfaces the way every other failure in
    /// this app does — a red toast — rather than as an unexplained beep.
    var onUnavailable: ((String) -> Void)?

    func show(referenceID: UUID, from terminal: NSView,
              load: @escaping (UUID) async throws -> TranscriptImagePayload) {
        loadTask?.cancel()
        anchorView = terminal

        let requestID = UUID()
        self.requestID = requestID
        loadTask = _Concurrency.Task { @MainActor [weak self] in
            do {
                let payload = try await load(referenceID)
                guard !_Concurrency.Task.isCancelled, let self, self.requestID == requestID else { return }
                let url = try Self.stagedFile(from: payload, expectedReferenceID: referenceID)
                guard !_Concurrency.Task.isCancelled, self.requestID == requestID else { return }
                self.present(url: url, caption: payload.reference.caption)
            } catch is CancellationError {
                // Replacing a pending preview cancels the fetch without terminal feedback.
            } catch {
                guard let self, self.requestID == requestID, !_Concurrency.Task.isCancelled else { return }
                // The reference outlived its session (a new epoch or an archive dropped the media).
                self.dismiss()
                self.onUnavailable?("Ask the agent to publish it again.")
            }
        }
    }

    func dismiss() {
        loadTask?.cancel()
        loadTask = nil
        requestID = nil
        guard let panel = QLPreviewPanel.shared(), panel.isVisible,
              panel.dataSource === self
        else { return }
        panel.orderOut(nil)
    }

    private func present(url: URL, caption: String) {
        let item = TranscriptPreviewItem()
        item.previewItemURL = url
        // QuickLook titles the panel with this; the staged filename already IS the caption, so this only
        // matters for the empty-caption case.
        item.previewItemTitle = caption.isEmpty ? "Image" : caption
        self.previewItem = item

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        // After QuickLook has sized itself to the image, move it clear of the inspector so the agent's
        // transcript stays readable beside it. Deferred because the panel picks its own frame as it
        // opens; setting it first would just be overwritten.
        DispatchQueue.main.async { [weak self] in self?.moveClearOfInspector(panel) }
    }

    /// Park the panel to the LEFT of the inspector it was opened from, rather than centred over the text
    /// that referenced it. The anchor view is the agent terminal, which lives in the inspector, so its
    /// left edge is the boundary to clear.
    private func moveClearOfInspector(_ panel: QLPreviewPanel) {
        guard let anchorView, let window = anchorView.window else { return }
        let terminalOnScreen = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
        var frame = panel.frame
        let gap: CGFloat = 12
        let targetMaxX = terminalOnScreen.minX - gap
        // Never push it off the left of the screen: if the inspector is wide enough that the panel cannot
        // fit beside it, leave QuickLook's own placement alone rather than shoving it out of reach.
        guard let screen = window.screen ?? NSScreen.main,
              targetMaxX - frame.width >= screen.visibleFrame.minX
        else { return }
        frame.origin.x = targetMaxX - frame.width
        frame.origin.y = terminalOnScreen.midY - frame.height / 2
        panel.setFrame(frame, display: true, animate: false)
    }

    private static func stagedFile(from payload: TranscriptImagePayload,
                                   expectedReferenceID: UUID) throws -> URL {
        guard payload.reference.id == expectedReferenceID,
              payload.reference.mimeType == "image/png" || payload.reference.mimeType == "image/jpeg",
              let data = Data(base64Encoded: payload.dataBase64),
              !data.isEmpty,
              // Sniff before staging: the panel would happily preview whatever bytes we wrote, so the
              // MIME allowlist has to be checked against the CONTENT, not just the declared type.
              NSImage(data: data) != nil
        else {
            throw TranscriptImagePreviewError.expired
        }
        return try TranscriptImagePreviewSpool.materialize(
            data: data, mimeType: payload.reference.mimeType,
            caption: payload.reference.caption, cardId: payload.reference.cardId)
    }

}

// QuickLook's protocols predate strict concurrency and aren't main-actor annotated, so the conformance
// is `@preconcurrency`. It is honest here: QuickLook only ever calls these on the main thread, which is
// where the panel itself lives.
extension TranscriptImagePreviewPresenter: @preconcurrency QLPreviewPanelDataSource,
                                           @preconcurrency QLPreviewPanelDelegate {
    // `sourceFrameOnScreenFor` is deliberately NOT implemented: QuickLook reads its absence as "no
    // zoom origin" and fades in at the natural size. Supplying the link's rect pinned the panel AT that
    // rect instead (measured: a 16x16 source rect opened a 17x16 panel), and zooming from a link on the
    // right to a panel parked on the left would fight the placement anyway.
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItem == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewItem }
}
