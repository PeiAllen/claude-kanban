import AppKit
import UserNotifications
import OrchestraCore

/// macOS notifications for cards that need the human. Client-local, driven by `BoardModel.apply`
/// observing the daemon event stream. Three independently-configurable triggers, each with a focus
/// **scope** (off / background / always) and a **sound** (default / none / a named system sound). The
/// sound rides on the notification's own `content.sound` — no separate audio player.
///
/// Prefs are per-Mac `UserDefaults` (keys `orch_notify_<trigger>_scope` / `_sound`), read live so the
/// Settings panel and the notifier never drift. Clicking a banner brings Orchestra forward + selects
/// the card.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {

    enum NotifyTrigger: String { case permission, needsYou, died }
    enum NotifyScope: String, CaseIterable { case off, background, always }

    /// The 14 built-in macOS sounds (files in /System/Library/Sounds), resolvable by name.
    static let soundNames = ["Basso","Blow","Bottle","Frog","Funk","Glass","Hero","Morse",
                             "Ping","Pop","Purr","Sosumi","Submarine","Tink"]

    static func scopeKey(_ t: NotifyTrigger) -> String { "orch_notify_\(t.rawValue)_scope" }
    static func soundKey(_ t: NotifyTrigger) -> String { "orch_notify_\(t.rawValue)_sound" }

    static func defaultScope(_ t: NotifyTrigger) -> NotifyScope {
        switch t { case .permission: return .always; case .needsYou: return .background; case .died: return .always }
    }
    /// `"default"` (system) / `"none"` (silent) / a name from `soundNames`.
    static func defaultSound(_ t: NotifyTrigger) -> String {
        switch t { case .permission: return "Hero"; case .needsYou: return "Submarine"; case .died: return "Basso" }
    }

    /// Wired by `BoardModel`: select a card when its banner is clicked.
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

    /// A trigger fired for `task`. Decide whether to surface it (per scope + app focus) and, if so,
    /// post a macOS notification with the trigger's configured sound.
    func notify(_ trigger: NotifyTrigger, task: Task) {
        guard Self.shouldFire(scope(for: trigger), isActive: NSApp.isActive) else { return }
        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = Self.body(for: trigger)
        content.sound = Self.sound(forPref: soundPref(for: trigger))
        content.userInfo = ["taskId": task.id.uuidString]
        let req = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - pure decision helpers

    static func shouldFire(_ scope: NotifyScope, isActive: Bool) -> Bool {
        switch scope { case .off: return false; case .always: return true; case .background: return !isActive }
    }

    /// Map a stored sound pref to a notification sound. `default` → system; `none` → silent; else a
    /// named built-in (resolved from the Sounds search paths, which include /System/Library/Sounds).
    static func sound(forPref pref: String) -> UNNotificationSound? {
        switch pref {
        case "none": return nil
        case "default": return .default
        default: return UNNotificationSound(named: UNNotificationSoundName("\(pref).aiff"))
        }
    }

    static func body(for trigger: NotifyTrigger) -> String {
        switch trigger {
        case .permission: return "Agent needs your approval"
        case .needsYou:   return "Agent finished — waiting on you"
        case .died:       return "Agent session ended — needs recovery"
        }
    }

    // MARK: - prefs

    private func scope(for t: NotifyTrigger) -> NotifyScope {
        let raw = UserDefaults.standard.string(forKey: Self.scopeKey(t))
        return raw.flatMap(NotifyScope.init(rawValue:)) ?? Self.defaultScope(t)
    }
    private func soundPref(for t: NotifyTrigger) -> String {
        UserDefaults.standard.string(forKey: Self.soundKey(t)) ?? Self.defaultSound(t)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show (and chime) even when Orchestra is frontmost — needed for scope `.always`. A `nil`
    /// `content.sound` (pref `none`) yields a silent foreground banner via the same path.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Banner clicked → bring Orchestra forward and select the card. Delivered off the main actor, so
    /// pull the Sendable id out synchronously and hop back on.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
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
