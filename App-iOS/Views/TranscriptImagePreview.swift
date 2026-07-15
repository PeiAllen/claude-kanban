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

/// Full-screen iPhone presentation for a transcript-anchored image. The media RPC validates the temporary
/// reference server-side; this view validates the returned MIME type and decodes only PNG/JPEG bytes.
struct MobileTranscriptImagePreview: View {
    let route: TranscriptImageRoute

    @EnvironmentObject private var model: BoardModel
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var caption = ""
    @State private var errorMessage: String?
    @State private var zoomCommand = ImageZoomCommand(direction: .fit, revision: 0)
    @State private var shareImage: UIImage?
    @State private var sharePresented = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            previewContent
            controls
        }
        .preferredColorScheme(.dark)
        .task(id: route) { await load(route) }
        .sheet(isPresented: $sharePresented, onDismiss: { shareImage = nil }) {
            if let shareImage {
                ImageShareSheet(image: shareImage)
            }
        }
        // The share sheet retains its own activity item while it is open. Keeping `shareImage` separate
        // lets the viewer release its decoded image on close without breaking a share already in flight.
        .onDisappear {
            image = nil
            if !sharePresented { shareImage = nil }
        }
    }

    @ViewBuilder private var previewContent: some View {
        if let image {
            GeometryReader { proxy in
                ZoomableTranscriptImage(image: image, containerSize: proxy.size, command: zoomCommand)
            }
            .padding(.top, 56)
            .padding(.bottom, 108)
        } else if let errorMessage {
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

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.58), in: Circle())
                }
                .accessibilityLabel("Close image preview")

                Spacer()

                if image != nil {
                    Button {
                        shareImage = image
                        sharePresented = shareImage != nil
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.58), in: Circle())
                    }
                    .accessibilityLabel("Share image")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            if let image {
                VStack(spacing: 10) {
                    if !caption.isEmpty {
                        Text(caption)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    HStack(spacing: 6) {
                        zoomButton("minus") { issueZoom(.out) }
                        zoomButton("arrow.up.left.and.arrow.down.right") { issueZoom(.fit) }
                        zoomButton("plus") { issueZoom(.zoomIn) }
                    }
                }
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
                )
            }
        }
    }

    private func zoomButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 38, height: 34)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .foregroundStyle(.white)
        .accessibilityLabel(symbol == "minus" ? "Zoom out" : symbol == "plus" ? "Zoom in" : "Fit image")
    }

    private func issueZoom(_ direction: ImageZoomDirection) {
        zoomCommand = ImageZoomCommand(direction: direction, revision: zoomCommand.revision + 1)
    }

    @MainActor
    private func load(_ route: TranscriptImageRoute) async {
        image = nil
        caption = ""
        errorMessage = nil

        do {
            let payload = try await model.transcriptImage(route.cardID, referenceID: route.referenceID)
            guard payload.reference.id == route.referenceID,
                  payload.reference.cardId == route.cardID,
                  payload.reference.mimeType == "image/png" || payload.reference.mimeType == "image/jpeg",
                  let data = Data(base64Encoded: payload.dataBase64),
                  let decoded = UIImage(data: data)
            else {
                throw TranscriptImagePreviewError.invalidPayload
            }
            guard !_Concurrency.Task.isCancelled else { return }
            image = decoded
            caption = payload.reference.caption
        } catch {
            guard !_Concurrency.Task.isCancelled else { return }
            errorMessage = "Image preview expired"
        }
    }
}

private enum ImageZoomDirection: Equatable {
    case out
    case fit
    case zoomIn
}

private struct ImageZoomCommand: Equatable {
    let direction: ImageZoomDirection
    let revision: Int
}

/// UIKit owns zooming because `UIScrollView` gives pinch and magnified pan behavior that remains stable
/// across a high-resolution raster. At fit scale it cannot pan; once magnified, normal direct drag pans.
private struct ZoomableTranscriptImage: UIViewRepresentable {
    let image: UIImage
    let containerSize: CGSize
    let command: ImageZoomCommand

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        // At fit scale there is no movable content; disabling bounce keeps a direct drag from looking
        // like a pan until the user has deliberately magnified the image.
        scrollView.bounces = false
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.addSubview(context.coordinator.imageView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.update(scrollView: scrollView, image: image,
                                   containerSize: containerSize, command: command)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        private var renderedImage: UIImage?
        private var renderedContainerSize = CGSize.zero
        private var lastCommand: ImageZoomCommand?

        override init() {
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = false
            super.init()
        }

        func update(scrollView: UIScrollView, image: UIImage, containerSize: CGSize,
                    command: ImageZoomCommand) {
            guard containerSize.width > 0, containerSize.height > 0,
                  image.size.width > 0, image.size.height > 0
            else { return }

            let imageChanged = renderedImage !== image
            let sizeChanged = renderedContainerSize != containerSize
            if imageChanged || sizeChanged {
                renderedImage = image
                renderedContainerSize = containerSize
                imageView.image = image
                imageView.frame = CGRect(origin: .zero, size: image.size)
                scrollView.contentSize = image.size

                let fitScale = max(0.01, min(containerSize.width / image.size.width,
                                              containerSize.height / image.size.height))
                scrollView.minimumZoomScale = fitScale
                // `UIImage.scale` is the zoom level where its source pixels reach native point scale.
                scrollView.maximumZoomScale = max(8 * fitScale, image.scale)
                scrollView.zoomScale = fitScale
                centerImage(in: scrollView)
                lastCommand = command
                return
            }

            guard lastCommand != command else { return }
            lastCommand = command
            switch command.direction {
            case .out:
                scrollView.setZoomScale(max(scrollView.minimumZoomScale, scrollView.zoomScale / 1.5), animated: true)
            case .fit:
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            case .zoomIn:
                scrollView.setZoomScale(min(scrollView.maximumZoomScale, scrollView.zoomScale * 1.5), animated: true)
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage(in: scrollView)
        }

        private func centerImage(in scrollView: UIScrollView) {
            let horizontal = max(0, (scrollView.bounds.width - imageView.frame.width) / 2)
            let vertical = max(0, (scrollView.bounds.height - imageView.frame.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal,
                                                    bottom: vertical, right: horizontal)
        }
    }
}

private struct ImageShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
