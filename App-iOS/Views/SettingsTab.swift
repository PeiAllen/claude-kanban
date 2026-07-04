import SwiftUI
import OrchestraKit
import OrchestraUI

/// Stub until M5 (Connection · Notifications · Appearance · About). Surfaces just the live link state
/// and the resolved dev-transport socket so the skeleton has an at-a-glance connection readout.
struct SettingsTab: View {
    @EnvironmentObject var model: BoardModel
    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Status", value: model.connectionState.rawValue)
                    LabeledContent("Daemon", value: ConnectionSocketResolver.socketPath(for: .local))
                }
                Section("About") {
                    LabeledContent("App", value: "Orchestra iOS 0.1.0")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
