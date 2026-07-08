import Foundation
import OrchestraKit

/// Push registration surface (N1). The phone hands its APNs device token + notification-pref snapshot to
/// the daemon over the `registerDevice` RPC; the daemon persists it (keyed by clientId) so `PushNotifier`
/// can deliver attention pushes while the phone is backgrounded.
public extension OrchestraService {
    /// Register (or update) a device for push. Replaces any prior registration for the same client.
    @discardableResult
    func registerDevice(_ reg: DeviceRegistration) async throws -> DeviceRegistration {
        // Not surfaced in the activity feed — a token handshake is plumbing, not board activity.
        try await devices.register(reg)
    }

    /// Drop a client's push registration (the phone revoked notifications / signed out). Idempotent.
    func unregisterDevice(clientId: String) async throws {
        try await devices.unregister(clientId: clientId)
    }

    /// All registered devices — the `PushNotifier` fan-out target.
    func registeredDevices() async -> [DeviceRegistration] {
        await devices.all()
    }
}
