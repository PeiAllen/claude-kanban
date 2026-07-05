import SwiftUI
import UserNotifications
import UIKit
import OrchestraKit

/// iOS push wiring (N1). Bridges the UIKit remote-notification callbacks (which land on a plain
/// `UIApplicationDelegate`, outside the SwiftUI environment) to the SwiftUI world via a shared singleton:
///
/// - **Registration**: request authorization → `registerForRemoteNotifications` → on the device token,
///   publish it so `OrchestraApp` hands it to the daemon (`BoardModel.registerForPush`).
/// - **Foreground gate**: `willPresent` honors the local `NotificationPrefs` — a `.background`-scoped
///   trigger stays quiet while the app is open (design §7), a `.always` one presents. This is the same
///   `PushGate.shouldPresent` rule the desktop notifier uses.
/// - **Deep-link**: a tapped push carries `taskId` → publish it so the UI switches to the Needs You tab
///   and opens the card (design §6: "this in-app queue is what push notifications deep-link into").
@MainActor
final class PushCoordinator: ObservableObject {
    static let shared = PushCoordinator()

    /// The APNs device token (hex), set once registration succeeds. `OrchestraApp` observes this and
    /// registers it with the daemon.
    @Published var deviceToken: String?
    /// A card a tapped push wants to open. `RootView` switches to Needs You; `NeedsYouTab` consumes it to
    /// push the card (or Recovery, if dead), then clears it.
    @Published var pendingCardId: UUID?

    private init() {}

    func setToken(_ hex: String) { deviceToken = hex }
    func deepLink(cardId: UUID) { pendingCardId = cardId }
    func consumeDeepLink() { pendingCardId = nil }

    // MARK: - Local-notification simulation (DEBUG stand-in for a real APNs push)

    #if DEBUG
    /// Schedule a LOCAL notification built from the SAME `APNsPayload` an attention transition would
    /// push. This is a labeled **simulation** — no APNs server, no daemon send — used to exercise the
    /// foreground gate + the deep-link end-to-end on the Simulator (where real remote push isn't
    /// available). It flows through the exact `willPresent` / `didReceive` handlers a remote push does.
    func simulateLocalPush(trigger: NotifyTrigger, cardId: UUID, cardTitle: String) {
        let intent = NotificationIntent(trigger: trigger, cardId: cardId,
                                        cardTitle: cardTitle, cardRef: cardId.uuidString)
        let prefs = NotificationPrefs()
        // Build the REAL APNs payload and translate it into a local notification, so the sim carries the
        // exact custom keys (taskId/trigger) the deep-link handler reads — a faithful stand-in.
        let payload = APNsPayload.build(intent: intent, sound: prefs.sound(trigger))
        let content = UNMutableNotificationContent()
        content.title = cardTitle
        content.body = "[SIMULATED] " + APNsPayload.body(for: trigger)
        content.userInfo = ["taskId": payload["taskId"]?.stringValue ?? cardId.uuidString,
                            "trigger": payload["trigger"]?.stringValue ?? trigger.rawValue,
                            "simulated": true]
        switch APNsPayload.soundField(prefs.sound(trigger)) {
        case "default"?:              content.sound = .default
        case let s? where !s.isEmpty: content.sound = UNNotificationSound(named: UNNotificationSoundName(s))
        default:                      break   // NotifySound.none → silent
        }
        let req = UNNotificationRequest(identifier: "sim-\(cardId.uuidString)",
                                        content: content,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(req)
    }
    #endif
}

/// The `UIApplicationDelegate` that owns the remote-notification callbacks. Registered from
/// `OrchestraApp` via `@UIApplicationDelegateAdaptor`. All UI-facing state flows through
/// `PushCoordinator.shared`.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    /// APNs handed us a device token → hex-encode and publish for daemon registration.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        _Concurrency.Task { @MainActor in PushCoordinator.shared.setToken(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[push] remote registration failed: \(error.localizedDescription)")
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Foreground presentation gate: honor the local `NotificationPrefs` scope so a background-only
    /// trigger stays quiet while the app is open (design §7), while `.always` still banners+chimes.
    /// `nonisolated` (like the macOS notifier) so the delegate conformance doesn't cross main-actor
    /// isolation — the work here is thread-safe (UserDefaults read + a synchronous completion call).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Parse the trigger inline (a Sendable String) so no non-Sendable userInfo crosses isolation.
        let trigger = (notification.request.content.userInfo["trigger"] as? String)
            .flatMap(NotifyTrigger.init(rawValue:))
        let scope = trigger.map { NotificationPrefs().scope($0) } ?? .always
        if PushGate.shouldPresent(scope: scope, appForeground: true) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([])   // background-only + app foreground ⇒ silent, not shown
        }
    }

    /// Tapped push → deep-link to the card in the Needs You queue. `nonisolated` for the same reason as
    /// `willPresent`; the Sendable id is pulled out and the coordinator hop happens on the main actor.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let idStr = response.notification.request.content.userInfo["taskId"] as? String,
           let id = UUID(uuidString: idStr) {
            _Concurrency.Task { @MainActor in PushCoordinator.shared.deepLink(cardId: id) }
        }
        completionHandler()
    }
}
