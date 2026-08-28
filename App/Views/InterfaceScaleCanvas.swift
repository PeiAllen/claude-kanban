import OrchestraKit
import SwiftUI

private struct BoardScaleEnvironmentKey: EnvironmentKey {
    static let defaultValue = InterfaceScale.defaultScale
}

extension EnvironmentValues {
    /// The scale of the board canvas only. It is exposed for gestures inside that canvas whose global
    /// drag translations need converting back to their logical board coordinates.
    var boardScale: Double {
        get { self[BoardScaleEnvironmentKey.self] }
        set { self[BoardScaleEnvironmentKey.self] = newValue }
    }
}

/// Scales only the board into the available board region. Other app surfaces remain in native points.
struct BoardScaleCanvas<Content: View>: View {
    @ObservedObject private var controller: InterfaceScaleController
    let minimumLogicalSize: InterfaceScale.Size
    private let content: () -> Content

    init(controller: InterfaceScaleController, minimumLogicalSize: InterfaceScale.Size,
         @ViewBuilder content: @escaping () -> Content) {
        _controller = ObservedObject(wrappedValue: controller)
        self.minimumLogicalSize = minimumLogicalSize
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let viewport = InterfaceScale.Size(width: Double(proxy.size.width), height: Double(proxy.size.height))
            let maximum = InterfaceScale.maximumFittingScale(viewport: viewport,
                                                              minimumLogicalSize: minimumLogicalSize)
            let effective = InterfaceScale.effectiveScale(requested: controller.requestedScale,
                                                          viewport: viewport,
                                                          minimumLogicalSize: minimumLogicalSize)

            content()
                .frame(width: proxy.size.width / effective, height: proxy.size.height / effective,
                       alignment: .topLeading)
                .scaleEffect(effective, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .environment(\.boardScale, effective)
                .onAppear { controller.reportMaximumFit(maximum) }
                .onChange(of: maximum) { _, value in controller.reportMaximumFit(value) }
        }
    }
}
