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
        if prev.kind != .dead, now.kind == .dead { return .died }
        return nil
    }

    /// The stuck trigger a card currently warrants, or `nil` if it is not stuck. Two independent causes,
    /// delivery before merge (matching `NeedsYouQueue.reason(for:)`'s order): the delivery arm's
    /// `deliveryStuckSince` flag, then the merge-request loop's sticky `TreeStat.mergeStalled` give-up flag.
    /// Pure — the sole authority on "which stuck", shared by the daemon tracker and the mac `BoardStore`.
    public static func currentStuckTrigger(_ task: Task) -> NotifyTrigger? {
        if task.deliveryStuckSince != nil { return .deliveryStuck }
        if task.treeStat?.mergeStalled == true { return .mergeStalled }
        return nil
    }

    /// The one-shot "card stuck" edge: the trigger to fire iff the card just ROSE from not-stuck to stuck.
    /// The one-shot is on the stuck *boolean*, not the cause — a card that stays stuck while its cause
    /// changes (`deliveryStuck → mergeStalled`) does NOT re-fire. `seen == false` (a card observed for the
    /// first time) never fires, mirroring the phase path's fresh-card suppression.
    public static func stuckRise(wasStuck: Bool, seen: Bool, cur task: Task) -> NotifyTrigger? {
        guard seen, !wasStuck else { return nil }
        return currentStuckTrigger(task)
    }

    /// The single notification a snapshot warrants — the phase edge and the stuck rise reconciled into ONE
    /// trigger, with a precedence that mirrors `NeedsYouQueue.reason(for:)` so the banner/push can't disagree
    /// with the queue: a recovery/permission-critical phase edge (`died`/`permission`) outranks a stuck rise,
    /// which in turn outranks `needsYou`. The sole precedence authority for both the daemon tracker and the
    /// mac `BoardStore` — so the two paths can't drift. (The died/permission-vs-stuck collision needs a single
    /// event carrying BOTH a fresh death and a fresh stuck flip, which no single store write produces today;
    /// deciding it here is defense-in-depth, keeping the more-urgent recovery push from ever being dropped.)
    public static func notifyTrigger(prev: Phase?, wasStuck: Bool, seen: Bool, task: Task) -> NotifyTrigger? {
        let phase = trigger(prev: prev, task: task)
        if phase == .permission || phase == .died { return phase }
        return stuckRise(wasStuck: wasStuck, seen: seen, cur: task) ?? phase
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
    /// Per-card "was stuck" memory — the state a phase snapshot can't carry, so the stuck one-shot fires
    /// exactly once on the false→true rise and re-arms only after the card clears.
    private var stuckCards: Set<UUID> = []
    public init() {}

    /// Feed the latest task snapshot; returns a `NotificationIntent` iff this snapshot is a genuine
    /// attention transition. An archived card is reaped (and never fires) so a later re-add starts fresh.
    public func observe(_ task: Task) -> NotificationIntent? {
        if task.archived { lastPhase[task.id] = nil; stuckCards.remove(task.id); return nil }
        let seen = lastPhase[task.id] != nil
        let wasStuck = stuckCards.contains(task.id)
        let prev = lastPhase[task.id]
        lastPhase[task.id] = task.phase
        // Update the stuck memory every observe, regardless of what we return.
        if AttentionTransition.currentStuckTrigger(task) != nil { stuckCards.insert(task.id) }
        else { stuckCards.remove(task.id) }
        // One trigger per observe, reconciled by the shared precedence authority (died/permission > stuck
        // > needsYou) so the push can't disagree with the Needs You queue.
        let trigger = AttentionTransition.notifyTrigger(prev: prev, wasStuck: wasStuck, seen: seen, task: task)
        guard let trigger else { return nil }
        return NotificationIntent(trigger: trigger, cardId: task.id,
                                  cardTitle: task.title, cardRef: task.ref())
    }

    /// Forget a removed card so a re-created id starts fresh (no phantom `prev`).
    public func forget(_ id: UUID) { lastPhase[id] = nil; stuckCards.remove(id) }
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
    public var deliveryStuck: Entry
    public var mergeStalled: Entry

    /// The two stuck triggers default to their designed prefs so the existing 3-arg call sites
    /// (`snapshot()`, test helpers) keep compiling without change.
    public init(permission: Entry, needsYou: Entry, died: Entry,
                deliveryStuck: Entry = Self.defaultEntry(.deliveryStuck),
                mergeStalled: Entry = Self.defaultEntry(.mergeStalled)) {
        self.permission = permission; self.needsYou = needsYou; self.died = died
        self.deliveryStuck = deliveryStuck; self.mergeStalled = mergeStalled
    }

    /// A trigger's designed default `{scope, sound}` — the fallback for a missing snapshot key.
    public static func defaultEntry(_ t: NotifyTrigger) -> Entry {
        Entry(scope: NotificationPrefs.defaultScope(t), sound: NotificationPrefs.defaultSound(t))
    }

    private enum CodingKeys: String, CodingKey {
        case permission, needsYou, died, deliveryStuck, mergeStalled
    }

    /// Hand-rolled so the two triggers added after the wire format shipped decode tolerantly: an
    /// already-persisted `DeviceRegistration` (`DeviceTokenStore.load`) or an un-updated phone's 3-key
    /// snapshot is missing them, and a synthesized decoder would THROW on the absent required keys —
    /// dropping the whole registration. Missing → the trigger's DESIGNED default (background/submarine),
    /// NOT silently-Off, so an old phone still surfaces stuck pushes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.permission = try c.decode(Entry.self, forKey: .permission)
        self.needsYou = try c.decode(Entry.self, forKey: .needsYou)
        self.died = try c.decode(Entry.self, forKey: .died)
        self.deliveryStuck = try c.decodeIfPresent(Entry.self, forKey: .deliveryStuck) ?? Self.defaultEntry(.deliveryStuck)
        self.mergeStalled = try c.decodeIfPresent(Entry.self, forKey: .mergeStalled) ?? Self.defaultEntry(.mergeStalled)
    }

    public func entry(for t: NotifyTrigger) -> Entry {
        switch t {
        case .permission:    return permission
        case .needsYou:      return needsYou
        case .died:          return died
        case .deliveryStuck: return deliveryStuck
        case .mergeStalled:  return mergeStalled
        }
    }
}

public extension NotificationPrefs {
    /// Snapshot the current per-trigger scope + sound for a device registration.
    func snapshot() -> NotifyPrefsSnapshot {
        NotifyPrefsSnapshot(
            permission:    .init(scope: scope(.permission),    sound: sound(.permission)),
            needsYou:      .init(scope: scope(.needsYou),      sound: sound(.needsYou)),
            died:          .init(scope: scope(.died),          sound: sound(.died)),
            deliveryStuck: .init(scope: scope(.deliveryStuck), sound: sound(.deliveryStuck)),
            mergeStalled:  .init(scope: scope(.mergeStalled),  sound: sound(.mergeStalled)))
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
        case .permission:    return "Agent needs your approval"
        case .needsYou:      return "Agent finished — waiting on you"
        case .died:          return "Agent session ended — needs recovery"
        case .deliveryStuck: return "Agent can't reach you — delivery stuck"
        case .mergeStalled:  return "Merge request needs you — agent gave up asking"
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
