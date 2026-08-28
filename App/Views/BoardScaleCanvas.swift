import Foundation
import OrchestraKit
import SwiftUI

/// The persisted board-zoom target and the current viewport ceiling.
@MainActor
final class BoardZoom: ObservableObject {
    static let values = (5...20).map { Double($0) / 10 }

    @Published private(set) var scale: Double
    private let defaults: UserDefaults
    private var maximum = 2.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = (defaults.object(forKey: "orch_board_scale") as? NSNumber)?.doubleValue ?? 1
        scale = Self.clamp(stored)
    }

    func set(_ value: Double) {
        let value = Self.clamp(value)
        guard scale != value else { return }
        scale = value
        defaults.set(value, forKey: "orch_board_scale")
    }

    func zoom(_ action: TerminalZoomAction) {
        let visible = min(scale, maximum)
        switch action {
        case .increase:
            if scale < maximum { set(min(maximum, scale + 0.1)) }
        case .decrease: set(visible - 0.1)
        case .reset: set(1)
        }
    }

    func reportMaximum(_ value: Double) {
        maximum = Self.clamp(value)
    }

    private static func clamp(_ value: Double) -> Double {
        min(2, max(0.5, (value * 10).rounded() / 10))
    }
}

private struct BoardScaleEnvironmentKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    var boardScale: Double {
        get { self[BoardScaleEnvironmentKey.self] }
        set { self[BoardScaleEnvironmentKey.self] = newValue }
    }
}

/// Scales the board into its own region, leaving every sibling in native points.
struct BoardScaleCanvas<Content: View>: View {
    @ObservedObject var zoom: BoardZoom
    private let content: () -> Content

    init(zoom: BoardZoom, @ViewBuilder content: @escaping () -> Content) {
        _zoom = ObservedObject(wrappedValue: zoom)
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let maximum = maximumScale(for: proxy.size) ?? 2
            let scale = min(zoom.scale, maximum)

            content()
                .frame(width: proxy.size.width / scale, height: proxy.size.height / scale,
                       alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .environment(\.boardScale, scale)
                .onAppear { reportMaximum(for: proxy.size) }
                .onChange(of: proxy.size) { _, size in reportMaximum(for: size) }
        }
    }

    private func reportMaximum(for size: CGSize) {
        if let maximum = maximumScale(for: size) {
            zoom.reportMaximum(maximum)
        }
    }

    private func maximumScale(for size: CGSize) -> Double? {
        guard size.width > 0, size.height > 0 else { return nil }
        let fit = min(size.width / 690, size.height / 320)
        return min(2, max(0.5, floor(fit * 10 + 1e-9) / 10))
    }
}
