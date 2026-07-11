import Foundation

// Provider-neutral push-notification core (N1). Client-safe (Foundation only), so it links on iOS *and*
// the daemon: the daemon uses the transition→intent mapping + APNs payload builder to send; the phone
// uses the same gating + payload shape to present + deep-link. The macOS `AgentNotifier` is the reference
// this mirrors — its transition detection (`BoardModel.apply`, `#if os(macOS)`, commented "iOS
// notifications are N1") is lifted here into a pure, testable, shared place.

// MARK: - Notification intent

/// What an attention transition produced: which trigger fired, for which card. The *same* value drives
/// the daemon's APNs payload and the iOS deep-link target (Needs You queue / the card).
public struct NotificationIntent: Codable, Sendable, Equatable {
    public let trigger: NotifyTrigger
    public let cardId: UUID
    public let cardTitle: String
    public let cardRef: String
    public init(trigger: NotifyTrigger, cardId: UUID, cardTitle: String, cardRef: String) {
        self.trigger = trigger; self.cardId = cardId; self.cardTitle = cardTitle; self.cardRef = cardRef
    }
}

// MARK: - Attention transition mapping (the deterministic core)

public enum AttentionTransition {
    /// The push trigger a status transition warrants, or `nil`. Mirrors the macOS notifier exactly
    /// (`BoardModel.apply`):
    /// - `prev == nil` (a freshly-appended card / the post-reconnect wholesale set) → **never** fires.
    /// - `prev != .waiting && status == .waiting` → `.permission` if `waitReason == .permission`
    ///   else `.needsYou`.
    /// - `prev != .dead && status == .dead` → `.died`.
    ///
    /// **Background-wait suppression is by construction:** a card that yields its turn to a background
    /// task (`run_in_background` shell, subagent, `/loop`/cron) stays `.running` with no `waitReason`
    /// (the adapters emit no waiting report), so it never produces a `.waiting` transition and maps to
    /// `nil` here. Asserted directly by a test.
    public static func trigger(prev: Phase?, task: Task) -> NotifyTrigger? {
        guard let prev else { return nil }
        let now = task.phase
        if !prev.isWaiting, case .live(.waiting(let reason)) = now {
            return reason == .permission ? .permission : .needsYou
        }
        // `.dead(.completed)` is a read-only delegated child finishing its turn (report() sets it), NOT a
        // death — exclude it so it fires no push, matching NeedsYouQueue.reason's identical guard.
        if prev.kind != .dead, now.kind == .dead, now != .dead(.completed) { return .died }
        return nil
    }
}

private extension Phase {
    /// True while the card is blocked waiting on the human (either wait reason) — the state whose
    /// *entry* fires a Needs-You / permission notification.
    var isWaiting: Bool { if case .live(.waiting) = self { return true } else { return false } }
}

/// Stateful attention observer for the daemon: remembers each card's last status and emits an intent on a
/// genuine transition. Pure (no I/O) so the whole transition→intent path is unit-testable. Confined to a
/// single event-consuming context (the daemon's `PushNotifier` actor owns it); not thread-safe by itself.
public final class AttentionTracker {
    private var lastPhase: [UUID: Phase] = [:]
    public init() {}

    /// Feed the latest task snapshot; returns a `NotificationIntent` iff this snapshot is a genuine
    /// attention transition. An archived card is reaped (and never fires) so a later re-add starts fresh.
    public func observe(_ task: Task) -> NotificationIntent? {
        if task.archived { lastPhase[task.id] = nil; return nil }
        let prev = lastPhase[task.id]
        lastPhase[task.id] = task.phase
        guard let trigger = AttentionTransition.trigger(prev: prev, task: task) else { return nil }
        return NotificationIntent(trigger: trigger, cardId: task.id,
                                  cardTitle: task.title, cardRef: task.ref())
    }

    /// Forget a removed card so a re-created id starts fresh (no phantom `prev`).
    public func forget(_ id: UUID) { lastPhase[id] = nil }
}

// MARK: - Delivery gating (scope), mirrors AgentNotifier.shouldFire

public enum PushGate {
    /// Daemon pre-filter: send unless the trigger is Off for this device. The daemon can't know the
    /// phone's foreground state, so it never suppresses `.background` here — the client applies the
    /// foreground gate on receipt (`shouldPresent`).
    public static func shouldSend(scope: NotifyScope) -> Bool { scope != .off }

    /// Client foreground gate (`UNUserNotificationCenterDelegate.willPresent`): `.always` always presents;
    /// `.background` stays quiet while the app is foreground (design §7: "background-only alerts stay quiet
    /// while the app is open"); `.off` never presents.
    public static func shouldPresent(scope: NotifyScope, appForeground: Bool) -> Bool {
        switch scope {
        case .off:        return false
        case .always:     return true
        case .background: return !appForeground
        }
    }
}

// MARK: - Registration payload

/// A per-trigger `{scope, sound}` snapshot the phone sends at registration so the daemon's send/sound
/// decision tracks the phone's Settings screen (M5) without the daemon reading the phone's UserDefaults.
/// The phone re-registers whenever a pref changes.
public struct NotifyPrefsSnapshot: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var scope: NotifyScope
        public var sound: NotifySound
        public init(scope: NotifyScope, sound: NotifySound) { self.scope = scope; self.sound = sound }
    }
    public var permission: Entry
    public var needsYou: Entry
    public var died: Entry
    public init(permission: Entry, needsYou: Entry, died: Entry) {
        self.permission = permission; self.needsYou = needsYou; self.died = died
    }
    public func entry(for t: NotifyTrigger) -> Entry {
        switch t {
        case .permission: return permission
        case .needsYou:   return needsYou
        case .died:       return died
        }
    }
}

public extension NotificationPrefs {
    /// Snapshot the current per-trigger scope + sound for a device registration.
    func snapshot() -> NotifyPrefsSnapshot {
        NotifyPrefsSnapshot(
            permission: .init(scope: scope(.permission), sound: sound(.permission)),
            needsYou:   .init(scope: scope(.needsYou),   sound: sound(.needsYou)),
            died:       .init(scope: scope(.died),       sound: sound(.died)))
    }
}

/// A registered push device, keyed by `clientId` in the daemon's store (re-register replaces). `token`
/// is the hex-encoded APNs device token the phone hands over after `registerForRemoteNotifications`.
public struct DeviceRegistration: Codable, Sendable, Equatable {
    public var token: String
    public var clientId: String
    public var prefs: NotifyPrefsSnapshot
    public init(token: String, clientId: String, prefs: NotifyPrefsSnapshot) {
        self.token = token; self.clientId = clientId; self.prefs = prefs
    }
}

// MARK: - APNs payload (pure builder)

/// Builds the APNs JSON payload for an intent: the `aps` alert/sound plus the custom `taskId`/`trigger`/
/// `ref` keys the iOS deep-link handler reads to route to the Needs You queue / the card. Pure — no
/// network — so the payload shape is unit-tested independent of any send.
public enum APNsPayload {
    /// The alert body per trigger — matches the macOS `AgentNotifier.body(for:)` wording.
    public static func body(for trigger: NotifyTrigger) -> String {
        switch trigger {
        case .permission: return "Agent needs your approval"
        case .needsYou:   return "Agent finished — waiting on you"
        case .died:       return "Agent session ended — needs recovery"
        }
    }

    /// The APNs `sound` string for the *iOS* device that receives the push. `.none` → `nil` (silent,
    /// field omitted); everything else → `"default"`.
    ///
    /// The named choices (Hero, Submarine, …) are macOS **system** files in `/System/Library/Sounds`;
    /// on iOS a custom push sound must be a `.caf`/`.aiff` **bundled in the app**, and none of these are.
    /// A push naming e.g. `"Submarine.aiff"` finds no such file on the phone and APNs silently drops the
    /// sound entirely — a named pref would be *quieter* than Default. So until bundled sounds exist we
    /// map every audible pref to the system default: the user's Off/On (`.none`) choice is honored, and a
    /// sound actually plays. (The macOS `AgentNotifier` keeps its own `UNNotificationSound` mapping and is
    /// unaffected — this field is only the APNs → iOS payload.)
    public static func soundField(_ sound: NotifySound) -> String? {
        sound == .none ? nil : "default"
    }

    /// The full push payload for `intent`, sounded per `sound`.
    public static func build(intent: NotificationIntent, sound: NotifySound) -> JSONValue {
        var aps: [String: JSONValue] = [
            "alert": .object([
                "title": .string(intent.cardTitle),
                "body":  .string(body(for: intent.trigger)),
            ]),
        ]
        if let s = soundField(sound) { aps["sound"] = .string(s) }
        return .object([
            "aps":     .object(aps),
            "taskId":  .string(intent.cardId.uuidString),
            "trigger": .string(intent.trigger.rawValue),
            "ref":     .string(intent.cardRef),
        ])
    }
}
