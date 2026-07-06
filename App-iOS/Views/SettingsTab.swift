import SwiftUI
import OrchestraKit
import OrchestraUI

/// Settings tab (M5): Connection (status banner + `ConnectionStore` list) · Notifications (3 triggers) ·
/// Appearance · About. Grouped inset lists, grounded in the shared `Connection` + notification models.
struct SettingsTab: View {
    @EnvironmentObject var model: BoardModel
    @State private var daemonVersion: String?

    var body: some View {
        NavigationStack {
            List {
                ConnectionSettingsSections()
                TerminalTargetSettingsSection()
                SecuritySettingsSection()
                NotificationsSettingsSection()
                AppearanceSettingsSection()
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
        }
        // Refresh the daemon version whenever the link comes up (and once on appear).
        .task(id: model.connectionState) {
            daemonVersion = model.connectionState == .live ? await model.daemonVersion() : nil
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: "Orchestra iOS \(OrchestraVersion.current)")
            LabeledContent("Daemon", value: daemonVersion ?? (model.connectionState == .live ? "…" : "—"))
        }
    }
}
