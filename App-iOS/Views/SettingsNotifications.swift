import SwiftUI
import OrchestraKit

/// Notifications settings: one row per attention trigger (🔐 Permission needed · 🙋 Needs you · 💀 Card
/// died), each with a **scope dial** (Off / Background only / Always) and a **sound dial**. Prefs persist
/// client-side through the shared `NotificationPrefs` (same UserDefaults keys the macOS notifier reads).
/// Actual push delivery is a backend follow-on (N1); this screen owns the preference model only.
struct NotificationsSettingsSection: View {
    @State private var refresh = 0   // bumped on write so the bindings re-read the store
    private let prefs = NotificationPrefs()

    var body: some View {
        Section {
            ForEach(NotifyTrigger.allCases, id: \.self) { trigger in
                triggerRow(trigger)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Background-only alerts stay quiet while the app is open. Agents paused on background "
                 + "tasks never alert — only a genuine hand-off to you does.")
        }
    }

    @ViewBuilder
    private func triggerRow(_ trigger: NotifyTrigger) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Self.emoji(trigger))  \(Self.title(trigger))").font(.body)
            Picker("Alert", selection: scopeBinding(trigger)) {
                Text("Off").tag(NotifyScope.off)
                Text("Background only").tag(NotifyScope.background)
                Text("Always").tag(NotifyScope.always)
            }
            .pickerStyle(.segmented)

            Picker("Sound", selection: soundBinding(trigger)) {
                ForEach(NotifySound.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .font(.subheadline)
            .disabled(scopeBinding(trigger).wrappedValue == .off)
        }
        .padding(.vertical, 4)
    }

    // MARK: - bindings (read/write the shared store, bump refresh so the UI reflects the write)

    private func scopeBinding(_ t: NotifyTrigger) -> Binding<NotifyScope> {
        Binding(get: { prefs.scope(t) },
                set: { prefs.setScope($0, for: t); refresh += 1 })
    }
    private func soundBinding(_ t: NotifyTrigger) -> Binding<NotifySound> {
        Binding(get: { prefs.sound(t) },
                set: { prefs.setSound($0, for: t); refresh += 1 })
    }

    // MARK: - labels

    static func emoji(_ t: NotifyTrigger) -> String {
        switch t {
        case .permission: return "🔐"
        case .needsYou:   return "🙋"
        case .died:       return "💀"
        }
    }
    static func title(_ t: NotifyTrigger) -> String {
        switch t {
        case .permission: return "Permission needed"
        case .needsYou:   return "Needs you"
        case .died:       return "Card died"
        }
    }
}
