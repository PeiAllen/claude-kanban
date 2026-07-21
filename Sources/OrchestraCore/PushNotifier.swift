import Foundation
import OrchestraKit

/// Delivers a built APNs payload to one device token. Abstracted so the daemon can wire a real
/// `APNsHTTPSender`, a `DisabledPushSender` (no credentials configured), or a mock in tests — the
/// `PushNotifier` fan-out never changes.
public protocol PushSender: Sendable {
    /// Deliver `payload` to `token`. Throws on a delivery failure (bad token, transport error). A
    /// disabled sender returns without doing anything.
    func send(payload: JSONValue, to token: String) async throws
}

/// The no-op sender used when no APNs credentials are configured. Push is wired end-to-end but delivery
/// is a documented no-op — the honest boundary when the environment has no auth key / topic.
public struct DisabledPushSender: PushSender {
    public init() {}
    public func send(payload: JSONValue, to token: String) async throws { /* no APNs config — drop */ }
}

/// The daemon-side push emitter (N1). Subscribes to the service event stream, runs each task transition
/// through the shared `AttentionTracker` to get a `NotificationIntent`, then fans it out to every
/// registered device whose per-trigger scope allows a send (`PushGate.shouldSend`) — building the APNs
/// payload with that device's configured sound. Mirrors the macOS `AgentNotifier`, but daemon-side so a
/// backgrounded (disconnected) phone still gets pushed.
///
/// The mapping/gating live in the pure `OrchestraKit` core (unit-tested there + here via a mock sender);
/// this actor is only the plumbing: subscribe → observe → gate → send.
public actor PushNotifier {
    private let tracker = AttentionTracker()
    private let service: OrchestraService
    private let sender: PushSender

    public init(service: OrchestraService, sender: PushSender) {
        self.service = service
        self.sender = sender
    }

    /// A test seam fired between `subscribe()` and the baseline snapshot, so a race test can land a
    /// transition in exactly that window and prove buffered stale events are dropped by the rev boundary.
    /// Nil in production.
    var afterSubscribeForTest: (@Sendable () async -> Void)?
    /// A test seam fired AFTER the baseline is seeded and BEFORE the stream loop, so a race test can fire a
    /// genuine post-snapshot transition (rev > boundary) that MUST still notify. Nil in production.
    var afterBaselineForTest: (@Sendable () async -> Void)?
    func setAfterSubscribeForTest(_ hook: @escaping @Sendable () async -> Void) { afterSubscribeForTest = hook }
    func setAfterBaselineForTest(_ hook: @escaping @Sendable () async -> Void) { afterBaselineForTest = hook }

    /// Consume the service event stream until it ends. Wired as a second subscriber alongside the
    /// ControlServer's event pump.
    ///
    /// SEED A BOOT BASELINE before consuming live events, so a card that is ALREADY dead/stuck when the
    /// daemon (re)starts is the tracker's baseline — never re-notified — while its first GENUINE transition
    /// after boot still fires. Without it, `subscribe()` replays no snapshot and `AttentionTracker.observe`
    /// suppresses every first sighting (`prev == nil` / `seen == false`), so a survivor that dies after a
    /// restart has that death consumed as a first sighting and no push is ever sent.
    ///
    /// Subscribe FIRST (so nothing landing in the window is lost), take an ATOMIC `(tasks, rev)` baseline,
    /// seed from `tasks`, and DROP every buffered event with `rev <= baseline.rev`. Those are causally
    /// OLDER than the snapshot yet already reflected in the seed, so replaying them against the newer seed
    /// would misfire: a windowed death would no-op (dead→dead) and a superseded waiting would fire a stale
    /// needs-you against a running seed. Only `rev > baseline.rev` events are genuinely post-snapshot, and
    /// they fire normally. (`observe`'s phase-idempotency alone is NOT enough — it cannot tell a stale
    /// replay from a real transition; the rev boundary is what distinguishes them.)
    public func run() async {
        let stream = await service.subscribe()
        await afterSubscribeForTest?()
        let baseline = await service.attentionBaseline()
        seedBaseline(baseline.tasks)
        await afterBaselineForTest?()
        for await envelope in stream where envelope.rev > baseline.rev {
            await handle(envelope.event)
        }
    }

    /// Prime the tracker's per-card baseline from a board snapshot WITHOUT emitting: `observe` suppresses
    /// every first sighting by construction, so seeding fires nothing — it just records each card's boot
    /// phase/stuck state so a later genuine transition is measured against it. Exposed for the boot-baseline
    /// test; called by `run()` at startup.
    func seedBaseline(_ tasks: [Task]) {
        for task in tasks { _ = tracker.observe(task) }
    }

    /// Process one event: a genuine attention transition fans out a push; a removed card is forgotten so
    /// a re-created id starts fresh. Public so the fan-out is unit-testable without a live stream.
    public func handle(_ event: Event) async {
        switch event {
        case .taskUpserted(let task):
            guard let intent = tracker.observe(task) else { return }
            await deliver(intent)
        case .taskRemoved(let id):
            tracker.forget(id)
        default:
            break
        }
    }

    /// Fan an intent out to every registered device, honoring each device's per-trigger scope + sound.
    private func deliver(_ intent: NotificationIntent) async {
        for device in await service.registeredDevices() {
            let entry = device.prefs.entry(for: intent.trigger)
            guard PushGate.shouldSend(scope: entry.scope) else { continue }   // drop .off at source
            let payload = APNsPayload.build(intent: intent, sound: entry.sound)
            do {
                try await sender.send(payload: payload, to: device.token)
            } catch {
                await handleSendFailure(error, clientId: device.clientId, token: device.token)
            }
        }
    }

    /// A send failed. If APNs reported the token is permanently invalid (410 Unregistered, or 400
    /// BadDeviceToken) Apple *requires* we stop sending to it — drop the registration (#4). Any other
    /// error is transient (network blip, 5xx): log it but keep the device, so a live token is never
    /// evicted by a momentary failure.
    ///
    /// **Token-matched eviction**: the store keys devices by `clientId` and a re-register REPLACES the
    /// entry, so an in-flight send against an OLD token can fail 410 *after* the phone has already
    /// registered a fresh token under the same clientId. Unregistering by clientId alone would then evict
    /// the brand-new valid registration. So we only drop the entry when the currently-stored token still
    /// equals the one that just failed; if it has already been replaced, we leave the fresh token alone
    /// (it will self-heal or fail on its own next send).
    private func handleSendFailure(_ error: Error, clientId: String, token: String) async {
        guard case let PushError.badStatus(code, body) = error, Self.isDeadToken(code, body) else {
            FileHandle.standardError.write(Data("push: send failed for client \(clientId): \(error)\n".utf8))
            return
        }
        let current = await service.registeredDevices().first { $0.clientId == clientId }
        guard current?.token == token else {
            FileHandle.standardError.write(Data(
                "push: 410/bad-token for client \(clientId) but token already replaced — keeping fresh registration\n".utf8))
            return
        }
        try? await service.unregisterDevice(clientId: clientId)
    }

    /// APNs statuses meaning "this token is permanently invalid — remove it": 410 Unregistered, or a 400
    /// whose reason is BadDeviceToken.
    static func isDeadToken(_ code: Int, _ body: String) -> Bool {
        code == 410 || (code == 400 && body.contains("BadDeviceToken"))
    }
}
