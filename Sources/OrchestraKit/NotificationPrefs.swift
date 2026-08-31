import Foundation

/// Client-local notification preferences, shared across every client (the macOS notifier and the iOS
/// Settings screen). Each attention trigger has a focus **scope** (off / background / always)
/// and a **sound** (default / none / a named system sound). Persisted per-client in `UserDefaults` under
/// the SAME keys the macOS `AgentNotifier` reads (`orch_notify_<trigger>_scope` / `_sound`) so choosing
/// how notifications fire is one model, not two that drift.
///
/// This lives in the client-safe core (Foundation only — no AppKit/UserNotifications) so the phone can
/// persist prefs without APNs delivery, which is a backend follow-on (N1). The macOS notifier keeps its
/// own `UNNotificationSound` mapping; this type owns only the scope/sound *storage* contract.
public enum NotifyTrigger: String, CaseIterable, Codable, Sendable {
    case humanRequired, died, mergeStalled
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
/// always reflects what's on disk. Human-required is immediate because it combines the old permission
/// and Needs You categories; old per-category values are read as a migration fallback.
public struct NotificationPrefs {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static func scopeKey(_ t: NotifyTrigger) -> String { "orch_notify_\(t.rawValue)_scope" }
    public static func soundKey(_ t: NotifyTrigger) -> String { "orch_notify_\(t.rawValue)_sound" }

    public static func defaultScope(_ t: NotifyTrigger) -> NotifyScope {
        switch t {
        case .humanRequired: return .always
        case .died:          return .always
        case .mergeStalled:  return .background
        }
    }
    public static func defaultSound(_ t: NotifyTrigger) -> NotifySound {
        switch t {
        case .humanRequired: return .hero
        case .died:          return .basso
        case .mergeStalled:  return .submarine
        }
    }

    public func scope(_ t: NotifyTrigger) -> NotifyScope {
        if let current = defaults.string(forKey: Self.scopeKey(t)).flatMap(NotifyScope.init(rawValue:)) {
            return current
        }
        if t == .humanRequired {
            return legacyValue("permission", suffix: "scope", as: NotifyScope.self)
                ?? legacyValue("needsYou", suffix: "scope", as: NotifyScope.self)
                ?? Self.defaultScope(t)
        }
        return Self.defaultScope(t)
    }
    public func setScope(_ scope: NotifyScope, for t: NotifyTrigger) {
        defaults.set(scope.rawValue, forKey: Self.scopeKey(t))
    }

    public func sound(_ t: NotifyTrigger) -> NotifySound {
        if let current = defaults.string(forKey: Self.soundKey(t)).flatMap(NotifySound.init(rawValue:)) {
            return current
        }
        if t == .humanRequired {
            return legacyValue("permission", suffix: "sound", as: NotifySound.self)
                ?? legacyValue("needsYou", suffix: "sound", as: NotifySound.self)
                ?? Self.defaultSound(t)
        }
        return Self.defaultSound(t)
    }
    public func setSound(_ sound: NotifySound, for t: NotifyTrigger) {
        defaults.set(sound.rawValue, forKey: Self.soundKey(t))
    }

    private func legacyValue<T: RawRepresentable>(
        _ trigger: String,
        suffix: String,
        as type: T.Type
    ) -> T? where T.RawValue == String {
        defaults.string(forKey: "orch_notify_\(trigger)_\(suffix)").flatMap(T.init(rawValue:))
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
