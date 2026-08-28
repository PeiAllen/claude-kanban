import Foundation
import OrchestraCore

/// App-local persistence for the shared terminal zoom setting. Both menu actions and the keyboard
/// monitor write this one key, which every mounted `AgentTerminalView` observes through `@AppStorage`.
enum TerminalZoomController {
    static func perform(_ action: TerminalZoomAction) {
        let defaults = UserDefaults.standard
        let current = (defaults.object(forKey: TerminalFontSize.preferenceKey) as? NSNumber)?.doubleValue
        defaults.set(TerminalFontSize.pointSize(after: action, current: current),
                     forKey: TerminalFontSize.preferenceKey)
    }
}
