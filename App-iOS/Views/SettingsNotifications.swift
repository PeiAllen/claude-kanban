import SwiftUI
import OrchestraKit
import OrchestraUI

/// Notifications settings: one row per attention trigger (🔐 Permission needed · 🙋 Needs you · 💀 Card
/// died), each with a **scope dial** (Off / Background only / Always) and a **sound dial**. Prefs persist
/// client-side through the shared `NotificationPrefs` (same UserDefaults keys the macOS notifier reads).
/// Push delivery is wired in N1 (device registration → daemon → APNs); the scope/sound dials here gate it.
struct NotificationsSettingsSection: View {
    @State private var refresh = 0   // bumped on write so the bindings re-read the store
    // Observe the shared accent key directly so this section recomputes when the accent changes (this
    // view doesn't hold the BoardModel in Release). Used only to re-key the `.menu` Sound picker below,
    // which otherwise keeps its mount-time tint — same SwiftUI quirk fixed in SettingsAppearance.
    @AppStorage("orch_accent") private var accentRaw = Accent.blue.rawValue
    private let prefs = NotificationPrefs()
    #if DEBUG
    @EnvironmentObject private var model: BoardModel
    #endif

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
        #if DEBUG
        simulationSection
        #endif
    }

    #if DEBUG
    /// A labeled **simulation** stand-in for a real APNs push (which needs a device + auth key). Schedules
    /// a LOCAL notification built from the same payload an attention transition would push, flowing through
    /// the exact foreground-gate + deep-link handlers a remote push does — so the routing is verifiable on
    /// the Simulator. NOT a real delivered push.
    @ViewBuilder private var simulationSection: some View {
        Section {
            ForEach(NotifyTrigger.allCases, id: \.self) { trigger in
                Button {
                    let card = model.tasks.first
                    PushCoordinator.shared.simulateLocalPush(
                        trigger: trigger,
                        cardId: card?.id ?? UUID(),
                        cardTitle: card?.title ?? "Sample card")
                } label: {
                    Label("Simulate \(Self.title(trigger)) push", systemImage: "bell.badge")
                }
            }
        } header: {
            Text("Developer — push simulation")
        } footer: {
            Text("DEBUG only. Fires a LOCAL notification (no APNs server) so the foreground gate + "
                 + "deep-link into the card can be verified on the Simulator.")
        }
    }
    #endif

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
            .id(accentRaw)   // remount on accent change so the menu picker re-reads the current tint
        }
        .padding(.vertical, 4)
    }

    // MARK: - bindings (read/write the shared store, bump refresh so the UI reflects the write)

    private func scopeBinding(_ t: NotifyTrigger) -> Binding<NotifyScope> {
        Binding(get: { prefs.scope(t) },
                set: { prefs.setScope($0, for: t); refresh += 1; prefsChanged() })
    }
    private func soundBinding(_ t: NotifyTrigger) -> Binding<NotifySound> {
        Binding(get: { prefs.sound(t) },
                set: { prefs.setSound($0, for: t); refresh += 1; prefsChanged() })
    }

    /// A written pref must **re-register** the device so the daemon's scope/sound snapshot tracks it (N1).
    /// The daemon can't read this phone's UserDefaults; it only holds the snapshot handed over at
    /// registration. Posting drives `BoardModel` to re-register with the fresh snapshot — without it a
    /// backgrounded phone keeps receiving pushes for a trigger just turned Off (the foreground
    /// `willPresent` gate never runs for a background delivery, so it can't save you). This is decoupled
    /// via NotificationCenter so the section needs no `BoardModel` reference in Release.
    private func prefsChanged() {
        NotificationCenter.default.post(name: .orchNotificationPrefsChanged, object: nil)
    }

    // MARK: - labels

    static func emoji(_ t: NotifyTrigger) -> String {
        switch t {
        case .permission:    return "🔐"
        case .needsYou:      return "🙋"
        case .died:          return "💀"
        case .deliveryStuck: return "📪"
        case .mergeStalled:  return "🚧"
        }
    }
    static func title(_ t: NotifyTrigger) -> String {
        switch t {
        case .permission:    return "Permission needed"
        case .needsYou:      return "Needs you"
        case .died:          return "Card died"
        case .deliveryStuck: return "Delivery stuck"
        case .mergeStalled:  return "Merge stalled"
        }
    }
}
