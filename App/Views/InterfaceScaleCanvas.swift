import AppKit
import OrchestraKit
import SwiftUI

private struct InterfaceScaleEnvironmentKey: EnvironmentKey {
    static let defaultValue = InterfaceScale.defaultScale
}

extension EnvironmentValues {
    /// The effective scale for this particular SwiftUI hosting tree. It is intentionally per-window:
    /// a compact settings window can be capped while a large board window shows the requested target.
    var interfaceScale: Double {
        get { self[InterfaceScaleEnvironmentKey.self] }
        set { self[InterfaceScaleEnvironmentKey.self] = newValue }
    }

    /// The fitting ceiling of the canvas that supplied `interfaceScale`. Detached AppKit presentation
    /// windows inherit it so their own shortcut actions still step from the scale the user sees.
    var interfaceScaleMaximum: Double {
        get { self[InterfaceScaleMaximumEnvironmentKey.self] }
        set { self[InterfaceScaleMaximumEnvironmentKey.self] = newValue }
    }
}

private struct InterfaceScaleMaximumEnvironmentKey: EnvironmentKey {
    static let defaultValue = InterfaceScale.maximumScale
}

/// Scales a logical SwiftUI canvas into the physical space offered by its containing window. The canvas
/// never overflows for zoom alone: the pure `InterfaceScale` policy rounds the applied value down to a
/// supported tenth that fully fits the viewport.
struct InterfaceScaleCanvas<Content: View>: View {
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
                // Give the original UI logical points; `scaleEffect` turns them back into the physical
                // viewport after layout, so fonts, spacing, hit targets, and custom overlays agree.
                .frame(width: proxy.size.width / effective, height: proxy.size.height / effective,
                       alignment: .topLeading)
                .scaleEffect(effective, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .environment(\.interfaceScale, effective)
                .environment(\.interfaceScaleMaximum, maximum)
                .background(WindowScaleReporter(controller: controller, maximumFit: maximum))
        }
    }
}

/// Reports each canvas's fitting limit back to the shared controller without retaining its window. The
/// titlebar accessory is a separate SwiftUI host, so this registration lets its popovers use the board
/// window's effective scale too.
private struct WindowScaleReporter: NSViewRepresentable {
    let controller: InterfaceScaleController
    let maximumFit: Double

    func makeNSView(context: Context) -> ReportingView {
        ReportingView(controller: controller, maximumFit: maximumFit)
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.controller = controller
        nsView.maximumFit = maximumFit
        nsView.report()
    }

    static func dismantleNSView(_ nsView: ReportingView, coordinator: ()) {
        nsView.removeReport()
    }

    final class ReportingView: NSView {
        weak var controller: InterfaceScaleController?
        var maximumFit: Double
        private weak var reportedWindow: NSWindow?

        init(controller: InterfaceScaleController, maximumFit: Double) {
            self.controller = controller
            self.maximumFit = maximumFit
            super.init(frame: .zero)
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        func report() {
            guard let window else { return }
            if reportedWindow !== window { removeReport() }
            reportedWindow = window
            controller?.reportMaximumFit(maximumFit, for: window)
        }

        func removeReport() {
            guard let reportedWindow else { return }
            controller?.removeFit(for: reportedWindow)
            self.reportedWindow = nil
        }
    }
}

private struct InterfaceScaledPresentationSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Native popovers and sheets are hosted outside a transformed canvas, so they need a small measured
/// canvas of their own. The window chrome stays AppKit-native while the presented content matches the
/// scale of the surface that opened it.
struct InterfaceScaledPresentation<Content: View>: View {
    @EnvironmentObject private var controller: InterfaceScaleController
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.interfaceScaleMaximum) private var interfaceScaleMaximum
    @State private var logicalSize: CGSize = .zero
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            // Keep logical measurements intrinsic in both dimensions. Without the vertical fixed size,
            // the outer physical height becomes the next logical proposal after scaling down, causing a
            // capped ScrollView popover to measure smaller on every layout pass.
            .fixedSize(horizontal: true, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: InterfaceScaledPresentationSizeKey.self, value: proxy.size)
                }
            )
            // A sheet/popover is hosted in a distinct AppKit window. Register its inherited ceiling so
            // Cmd− starts from its visible parent scale instead of the retained target.
            .background(WindowScaleReporter(controller: controller, maximumFit: interfaceScaleMaximum))
            .scaleEffect(interfaceScale, anchor: .topLeading)
            .frame(width: logicalSize.width > 0 ? logicalSize.width * interfaceScale : nil,
                   height: logicalSize.height > 0 ? logicalSize.height * interfaceScale : nil,
                   alignment: .topLeading)
            .onPreferenceChange(InterfaceScaledPresentationSizeKey.self) { logicalSize = $0 }
    }
}
