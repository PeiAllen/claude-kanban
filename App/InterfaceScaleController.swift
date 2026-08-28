import AppKit
import Foundation
import OrchestraKit
import OrchestraUI

/// Owns the persisted *target* interface scale and the live fitting limits reported by each desktop
/// window. A target above a window's limit is deliberately retained, so enlarging that window restores
/// the requested scale without rewriting the user's preference.
@MainActor
final class InterfaceScaleController: ObservableObject {
    @Published private(set) var requestedScale: Double

    private let defaults: UserDefaults
    private var maximumFits: [ObjectIdentifier: Double] = [:]
    // Publishing this makes detached titlebar hosts re-evaluate their popover scale when their board
    // window changes size. The dictionary itself stays private implementation detail.
    @Published private var fitRevision = 0

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

    /// The scale currently applied in a particular window. A window that has not mounted its canvas yet
    /// uses the target briefly; the reporter immediately replaces that with its measured fit.
    func effectiveScale(in window: NSWindow?) -> Double {
        guard let window else { return requestedScale }
        let maximum = maximumFits[ObjectIdentifier(window)] ?? InterfaceScale.maximumScale
        return min(requestedScale, maximum)
    }

    /// Applies a shortcut/menu action to the window that owns it. Increasing at an existing fit cap is a
    /// no-op: it must not erase a larger retained target. Decreasing starts at what the user can see.
    func perform(_ action: ZoomAction, in window: NSWindow?) {
        let applied = effectiveScale(in: window)
        setRequestedScale(InterfaceScale.requestedScale(after: action,
                                                         requested: requestedScale,
                                                         applied: applied,
                                                         maximumFittingScale: maximumFittingScale(in: window)))
    }

    func reportMaximumFit(_ scale: Double, for window: NSWindow) {
        let key = ObjectIdentifier(window)
        let normalized = InterfaceScale.normalized(scale)
        guard maximumFits[key] != normalized else { return }
        maximumFits[key] = normalized
        fitRevision &+= 1
    }

    func removeFit(for window: NSWindow) {
        guard maximumFits.removeValue(forKey: ObjectIdentifier(window)) != nil else { return }
        fitRevision &+= 1
    }

    private func maximumFittingScale(in window: NSWindow?) -> Double {
        guard let window else { return InterfaceScale.maximumScale }
        return maximumFits[ObjectIdentifier(window)] ?? InterfaceScale.maximumScale
    }
}

/// One routing point for menu items and the AppKit keyboard monitor. The terminal keeps its physical
/// font policy only while a SwiftTerm view truly owns first responder; every other focus surface owns
/// the interface canvas scale.
@MainActor
enum ZoomController {
    static func perform(_ action: ZoomAction, model: BoardModel, interfaceScale: InterfaceScaleController,
                        window: NSWindow? = nil) {
        let window = window ?? NSApp.keyWindow
        if KeyboardContextResolver.current(model: model) == .terminal {
            TerminalZoomController.perform(action)
        } else {
            interfaceScale.perform(action, in: window)
        }
    }
}
