import QuickLook
import SwiftUI
import UIKit
import OrchestraKit
import OrchestraUI

/// A temporary image reference tied to the card that owns the transcript marker. The route carries only
/// daemon-issued IDs; a phone never receives an agent filesystem path or provider-specific tool output.
struct TranscriptImageRoute: Identifiable, Equatable {
    let cardID: UUID
    let referenceID: UUID

    var id: String { "\(cardID.uuidString)-\(referenceID.uuidString)" }
}

private enum TranscriptImagePreviewError: Error {
    case invalidPayload
}

/// Stages daemon bytes where QuickLook can reach them: QLPreviewController previews a file URL, so the
/// payload cannot stay purely in memory the way the hand-rolled viewer kept it.
///
/// The staging area is the app's *temporary* directory, deliberately — not Documents (backed up, ours
/// forever) and not Caches (purged only under storage pressure, so it needs an eviction policy like the
/// macOS export cache in App/TranscriptImagePreview.swift). iOS may purge tmp whenever the app isn't
/// running, so a file orphaned by a crash cannot accumulate, and the preview deletes its own file on
/// dismiss. That combination is why this side needs no age/size prune of its own.
enum TranscriptImagePreviewFile {
    /// The caption becomes the filename, because `TranscriptImageCaption` constrained it to a legal one
    /// at the `publish-image` boundary — no sanitizing here, and none is safe to add here either: this is
    /// a client, and the daemon is where that contract is enforced.
    ///
    /// It is worth the trouble because this name is what the human actually sees: QuickLook's share sheet
    /// header, the Save-to-Files dialog, and — verified — the `suggestedName` that rides along on the
    /// pasteboard when they Copy. Uniqueness comes from a UUID *directory*, so two images sharing a
    /// caption can't collide while the visible name stays real.
    static func write(data: Data, mimeType: String, caption: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptImagePreviews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The extension is what QuickLook types the file by; the caller validates MIME before staging.
        let stem = TranscriptImageCaption.isValid(caption) ? caption : "image"
        let url = directory
            .appendingPathComponent(stem)
            .appendingPathExtension(mimeType == "image/jpeg" ? "jpg" : "png")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Removes the staged file's whole UUID directory, not just the file — the directory is the unit of
    /// uniqueness, so leaving it behind would leak an empty dir per preview.
    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

/// Full-screen iPhone presentation for a transcript-anchored image. The media RPC validates the temporary
/// reference server-side; this view validates the returned MIME type and stages only PNG/JPEG bytes.
///
/// Zoom, pan, and the export popup (copy, share, save to Files, AirDrop) are QuickLook's, not ours — so
/// the image behaves like every other image on the phone.
struct MobileTranscriptImagePreview: View {
    let route: TranscriptImageRoute

    @EnvironmentObject private var model: BoardModel
    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?
    @State private var caption = ""
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let fileURL {
                QuickLookPreview(url: fileURL, title: caption) { dismiss() }
            } else {
                statusContent
                closeButton
            }
        }
        .preferredColorScheme(.dark)
        .task(id: route) { await load(route) }
        // The staged file exists only as long as the preview that owns it, and that is safe even for an
        // export the user already performed: QuickLook's share sheet is a child of the live preview, so
        // an activity always resolves the item while the file is still there, and it takes the BYTES —
        // Copy then dismiss leaves a full-resolution image on UIPasteboard with the file long gone, not
        // a lazy provider pointing at it. So nothing downstream outlives the file it came from.
        .onDisappear {
            TranscriptImagePreviewFile.remove(fileURL)
            fileURL = nil
        }
    }

    @ViewBuilder private var statusContent: some View {
        if let errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.72))
                Text(errorMessage).font(.headline).foregroundStyle(.white)
                Text("Ask the agent to publish it again if you still need it.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
        } else {
            ProgressView("Loading image…")
                .tint(.white)
                .foregroundStyle(.white)
        }
    }

    /// Loading and error states are ours, so they carry their own way out. Once QuickLook is up it owns
    /// the navigation bar, including Done.
    private var closeButton: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.58), in: Circle())
                }
                .accessibilityLabel("Close image preview")
                .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            Spacer()
        }
    }

    @MainActor
    private func load(_ route: TranscriptImageRoute) async {
        TranscriptImagePreviewFile.remove(fileURL)
        fileURL = nil
        caption = ""
        errorMessage = nil

        do {
            let payload = try await model.transcriptImage(route.cardID, referenceID: route.referenceID)
            guard payload.reference.id == route.referenceID,
                  payload.reference.cardId == route.cardID,
                  payload.reference.mimeType == "image/png" || payload.reference.mimeType == "image/jpeg",
                  let data = Data(base64Encoded: payload.dataBase64),
                  !data.isEmpty
            else {
                throw TranscriptImagePreviewError.invalidPayload
            }
            let staged = try TranscriptImagePreviewFile.write(data: data,
                                                              mimeType: payload.reference.mimeType,
                                                              caption: payload.reference.caption)
            guard !_Concurrency.Task.isCancelled else {
                TranscriptImagePreviewFile.remove(staged)
                return
            }
            caption = payload.reference.caption
            fileURL = staged
        } catch {
            guard !_Concurrency.Task.isCancelled else { return }
            errorMessage = "Image preview expired"
        }
    }
}

/// QuickLook owns the viewer. Wrapping QLPreviewController in a navigation controller is what gives it a
/// bar to hang its own export action on — the native popup with copy, share, save to Files, and AirDrop.
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let title: String
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url, title: title, onDone: onDone) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.done)
        )
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        guard context.coordinator.update(url: url, title: title, onDone: onDone) else { return }
        (controller.viewControllers.first as? QLPreviewController)?.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        private let item = TranscriptPreviewItem()
        private var onDone: () -> Void

        init(url: URL, title: String, onDone: @escaping () -> Void) {
            self.onDone = onDone
            super.init()
            _ = apply(url: url, title: title)
        }

        /// Returns whether the previewed item actually changed, so a re-render doesn't reload QuickLook
        /// out from under an open export sheet.
        @discardableResult
        func update(url: URL, title: String, onDone: @escaping () -> Void) -> Bool {
            self.onDone = onDone
            return apply(url: url, title: title)
        }

        private func apply(url: URL, title: String) -> Bool {
            guard item.previewItemURL != url || item.previewItemTitle != title else { return false }
            item.previewItemURL = url
            // QuickLook shows this as the bar title; an empty caption would read as a blank header.
            item.previewItemTitle = title.isEmpty ? "Image" : title
            return true
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            item
        }

        @objc func done() { onDone() }
    }
}

private final class TranscriptPreviewItem: NSObject, QLPreviewItem {
    var previewItemURL: URL?
    var previewItemTitle: String?
}
