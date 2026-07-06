import Foundation

/// Client-local notification preferences, shared across every client (the macOS notifier and the iOS
/// Settings screen). Three attention triggers, each with a focus **scope** (off / background / always)
/// and a **sound** (default / none / a named system sound). Persisted per-client in `UserDefaults` under
/// the SAME keys the macOS `AgentNotifier` reads (`orch_notify_<trigger>_scope` / `_sound`) so choosing
/// how notifications fire is one model, not two that drift.
///
/// This lives in the client-safe core (Foundation only — no AppKit/UserNotifications) so the phone can
/// persist prefs without APNs delivery, which is a backend follow-on (N1). The macOS notifier keeps its
/// own `UNNotificationSound` mapping; this type owns only the scope/sound *storage* contract.
public enum NotifyTrigger: String, CaseIterable, Codable, Sendable {
    case permission, needsYou, died
}

public enum NotifyScope: String, CaseIterable, Codable, Sendable {
    case off, background, always
}

/// The 14 built-in macOS system sounds (files in /System/Library/Sounds), plus the two synthetic
/// choices. A stored sound pref is one of these `rawValue`s. On the phone these are labels only until
/// APNs delivery (N1) maps them to a push sound; on the Mac the notifier resolves them to a
/// `UNNotificationSound`.
public enum NotifySound: String, CaseIterable, Codable, Sendable {
    case systemDefault = "default"
    case none
    case basso = "Basso", blow = "Blow", bottle = "Bottle", frog = "Frog", funk = "Funk"
    case glass = "Glass", hero = "Hero", morse = "Morse", ping = "Ping", pop = "Pop"
    case purr = "Purr", sosumi = "Sosumi", submarine = "Submarine", tink = "Tink"

    /// Human label for a picker row.
    public var label: String {
        switch self {
        case .systemDefault: return "Default"
        case .none:          return "None"
        default:             return rawValue
        }
    }
}

/// UserDefaults-backed read/write for the per-trigger scope + sound. Value semantics; a fresh instance
/// always reflects what's on disk. Defaults match the macOS notifier exactly (permission always/Hero,
/// needsYou background/Submarine, died always/Basso).
public struct NotificationPrefs {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static func scopeKey(_ t: NotifyTrigger) -> String { "orch_notify_\(t.rawValue)_scope" }
    public static func soundKey(_ t: NotifyTrigger) -> String { "orch_notify_\(t.rawValue)_sound" }

    public static func defaultScope(_ t: NotifyTrigger) -> NotifyScope {
        switch t {
        case .permission: return .always
        case .needsYou:   return .background
        case .died:       return .always
        }
    }
    public static func defaultSound(_ t: NotifyTrigger) -> NotifySound {
        switch t {
        case .permission: return .hero
        case .needsYou:   return .submarine
        case .died:       return .basso
        }
    }

    public func scope(_ t: NotifyTrigger) -> NotifyScope {
        defaults.string(forKey: Self.scopeKey(t)).flatMap(NotifyScope.init(rawValue:))
            ?? Self.defaultScope(t)
    }
    public func setScope(_ scope: NotifyScope, for t: NotifyTrigger) {
        defaults.set(scope.rawValue, forKey: Self.scopeKey(t))
    }

    public func sound(_ t: NotifyTrigger) -> NotifySound {
        defaults.string(forKey: Self.soundKey(t)).flatMap(NotifySound.init(rawValue:))
            ?? Self.defaultSound(t)
    }
    public func setSound(_ sound: NotifySound, for t: NotifyTrigger) {
        defaults.set(sound.rawValue, forKey: Self.soundKey(t))
    }
}

public extension Notification.Name {
    /// Posted (client-side) right after a notification pref — scope or sound — is written, so the push
    /// layer can **re-register the device** with the daemon (N1). The daemon holds the per-device
    /// scope/sound snapshot taken *at registration time*; without a re-register a pref the user changes
    /// while the app is foregrounded never reaches the daemon, so a backgrounded phone keeps getting
    /// pushes for a trigger the user just turned Off (the foreground `willPresent` gate can't suppress a
    /// delivery that arrives while the app isn't running). `BoardModel` observes this and re-registers
    /// with the fresh snapshot; the macOS notifier ignores it (it reads prefs live).
    static let orchNotificationPrefsChanged = Notification.Name("orchNotificationPrefsChanged")
}
