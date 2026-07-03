import AppKit
import UserNotifications
import OrchestraCore

/// Surfaces a macOS notification when an agent card transitions to `.waiting` — its turn ended and it
/// needs the human. Client-local: driven entirely by `BoardModel.apply` observing the daemon event
/// stream; nothing here touches the daemon.
///
/// Two independent, user-toggleable behaviours (both default on, persisted in UserDefaults):
///   • sound  (`orch_notify_sound`)   — plays on EVERY waiting transition, even when Orchestra is
///                                       frontmost (an always-audible "an agent needs you" cue).
///   • banner (`orch_notify_waiting`) — a Notification-Center banner, posted only while Orchestra is
///                                       backgrounded (no nagging while you're already watching the board).
/// Clicking the banner brings Orchestra forward and selects the card.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// UserDefaults keys — also the `@AppStorage` keys the Settings toggles bind to.
    static let bannerKey = "orch_notify_waiting"
    static let soundKey  = "orch_notify_sound"

    /// Wired by `BoardModel`: select a card when its banner is clicked.
    var onSelect: ((UUID) -> Void)?

    /// Retained so it isn't deallocated mid-play; a named system sound with a beep fallback.
    private let sound = NSSound(named: NSSound.Name("Submarine"))

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask once for permission to post banners. The sound path uses `NSSound`, which isn't gated by
    /// this, so a denial only costs the visual banner. Safe to call every launch.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A card just became `.waiting`. `BoardModel` guarantees this is a genuine transition on an
    /// existing card (not startup / reconnect), so here we only decide *how* to surface it.
    func agentBecameWaiting(_ task: Task) {
        if enabled(Self.soundKey) { playSound() }
        if enabled(Self.bannerKey) && !NSApp.isActive { postBanner(for: task) }
    }

    // MARK: - internals

    /// A toggle defaults to ON when the user has never touched it.
    private func enabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private func playSound() {
        if let sound { sound.stop(); sound.play() } else { NSSound.beep() }
    }

    private func postBanner(for task: Task) {
        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = "Agent needs your input"
        content.userInfo = ["taskId": task.id.uuidString]
        // The sound fires independently via NSSound (so it plays even when foregrounded); keep the
        // banner itself silent to avoid a double chime when backgrounded.
        let req = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - UNUserNotificationCenterDelegate

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
