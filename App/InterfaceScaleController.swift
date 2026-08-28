import Foundation
import OrchestraKit
import OrchestraUI

/// Owns the persisted board-zoom target and the fitting limit last measured by the single board
/// canvas. A target above that temporary limit is retained, so it returns when the board gets wider.
@MainActor
final class InterfaceScaleController: ObservableObject {
    @Published private(set) var requestedScale: Double

    private let defaults: UserDefaults
    private var maximumFit = InterfaceScale.maximumScale

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = (defaults.object(forKey: InterfaceScale.preferenceKey) as? NSNumber)?.doubleValue
        requestedScale = InterfaceScale.normalized(stored)
    }

    func setRequestedScale(_ scale: Double) {
        let normalized = InterfaceScale.normalized(scale)
        guard requestedScale != normalized else { return }
        requestedScale = normalized
        defaults.set(normalized, forKey: InterfaceScale.preferenceKey)
    }

    func perform(_ action: ZoomAction) {
        let applied = min(requestedScale, maximumFit)
        setRequestedScale(InterfaceScale.requestedScale(after: action,
                                                         requested: requestedScale,
                                                         applied: applied,
                                                         maximumFittingScale: maximumFit))
    }

    func reportMaximumFit(_ scale: Double) {
        maximumFit = InterfaceScale.normalized(scale)
    }
}

/// One routing point for the menu and AppKit keyboard monitor. A focused terminal owns its font zoom;
/// every other focus surface changes the board canvas scale.
@MainActor
enum ZoomController {
    static func perform(_ action: ZoomAction, model: BoardModel, interfaceScale: InterfaceScaleController) {
        if KeyboardContextResolver.current(model: model) == .terminal {
            TerminalZoomController.perform(action)
        } else {
            interfaceScale.perform(action)
        }
    }
}
