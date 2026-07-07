#if os(macOS)
import AppKit
import UserNotifications
import OrchestraKit

/// macOS notifications for cards that need the human. Client-local, driven by `BoardStore.apply`
/// observing the daemon event stream.
///
/// **Single source of truth (Lens-1 HIGH #2):** this consumes the shared, provider-neutral push core in
/// OrchestraKit rather than duplicating it — `NotificationPrefs` (the `orch_notify_*` scope/sound storage
/// + defaults), `PushGate` (delivery gating), `AttentionTransition` (which status transition warrants
/// which trigger — applied in `BoardStore.apply`), and `APNsPayload.body` (the alert wording). The only
/// macOS-specific bit left here is mapping a stored `NotifySound` to a `UNNotificationSound`, which the
/// client-safe core can't name. So "add a trigger" is now one edit to the shared core and the Mac banner +
/// phone push move together — they can no longer silently diverge.
///
/// Prefs are per-Mac `UserDefaults` (keys `orch_notify_<trigger>_scope` / `_sound`), read live via a fresh
/// `NotificationPrefs` so the Settings panel and the notifier never drift. Clicking a banner brings
/// Orchestra forward + selects the card.
@MainActor
public final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {

    /// Live per-trigger scope + sound, from the shared client-safe store (same `orch_notify_*` keys).
    private let prefs = NotificationPrefs()

    /// Wired by `BoardStore`: select a card when its banner is clicked.
    var onSelect: ((UUID) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask once for permission to post banners + play sound. Safe to call every launch.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - firing

    /// A trigger fired for `task`. Decide whether to surface it (per scope + app focus, via the shared
    /// `PushGate`) and, if so, post a macOS notification with the shared body text + the trigger's sound.
    func notify(_ trigger: NotifyTrigger, task: Task) {
        guard PushGate.shouldPresent(scope: prefs.scope(trigger), appForeground: NSApp.isActive) else { return }
        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = APNsPayload.body(for: trigger)
        content.sound = Self.sound(for: prefs.sound(trigger))
        content.userInfo = ["taskId": task.id.uuidString]
        let req = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - macOS-specific sound mapping (the one thing the client-safe core can't name)

    /// Map a stored `NotifySound` to a `UNNotificationSound`. `.none` → silent (nil); `.systemDefault` →
    /// the system default; else a named built-in (resolved from the Sounds search paths, which include
    /// /System/Library/Sounds). Internal for unit-test visibility. `nonisolated` — a pure value mapping
    /// touching no main-actor state, so it's callable from any context (incl. a sync test).
    nonisolated static func sound(for sound: NotifySound) -> UNNotificationSound? {
        switch sound {
        case .none:          return nil
        case .systemDefault: return .default
        default:             return UNNotificationSound(named: UNNotificationSoundName("\(sound.rawValue).aiff"))
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show (and chime) even when Orchestra is frontmost — needed for scope `.always`. A `nil`
    /// `content.sound` (pref `none`) yields a silent foreground banner via the same path.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification,
                                                   withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Banner clicked → bring Orchestra forward and select the card. Delivered off the main actor, so
    /// pull the Sendable id out synchronously and hop back on.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse,
                                                   withCompletionHandler completionHandler: @escaping () -> Void) {
        let idStr = response.notification.request.content.userInfo["taskId"] as? String
        _Concurrency.Task { @MainActor [weak self] in
            if let idStr, let id = UUID(uuidString: idStr) {
                NSApp.activate(ignoringOtherApps: true)
                self?.onSelect?(id)
            }
        }
        completionHandler()
    }
}
#endif
