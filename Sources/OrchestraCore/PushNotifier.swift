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

    /// Consume the service event stream until it ends. Wired as a second subscriber alongside the
    /// ControlServer's event pump.
    public func run() async {
        for await event in await service.subscribe() {
            await handle(event)
        }
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
            try? await sender.send(payload: payload, to: device.token)
        }
    }
}
