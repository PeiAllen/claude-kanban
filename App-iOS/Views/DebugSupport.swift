#if DEBUG
import Foundation

/// DEBUG-only helpers for verifying T1 (the SSH-PTY terminal) end-to-end in the Simulator.
enum DebugSupport {
    /// Export this device's SSH `authorized_keys` line so a test harness can trust the Simulator's
    /// Keychain-generated key against a throwaway sshd — writes it into the app container's Documents
    /// dir (readable via `xcrun simctl get_app_container … data`) and logs it. Also *generates* the
    /// key on first call. Compiled out of Release.
    static func exportPubkey() {
        do {
            let line = try SSHKeyStore.authorizedKeyLine()
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try line.write(to: docs.appendingPathComponent("orchestra-ios-pubkey.txt"),
                               atomically: true, encoding: .utf8)
            }
            print("ORCHESTRA_IOS_PUBKEY \(line)")
        } catch {
            print("ORCHESTRA_IOS_PUBKEY_ERROR \(error)")
        }
    }

    /// Clear all TOFU host-key pins when `ORCH_RESET_HOSTKEY_PINS=1` — so a verify harness that points the
    /// terminal at a THROWAWAY sshd (whose host key is freshly generated each run) starts from a clean
    /// trust-on-first-use state instead of hitting a `hostKeyChanged` refusal against a pin left by a prior
    /// run to the same host (e.g. 127.0.0.1). DEBUG-only; production never sets this env.
    static func resetHostKeyPinsIfRequested() {
        guard ProcessInfo.processInfo.environment["ORCH_RESET_HOSTKEY_PINS"] == "1" else { return }
        do { try SSHHostKeyPinStore().resetAll(); print("ORCHESTRA_IOS_HOSTKEY_PINS_RESET") }
        catch { print("ORCHESTRA_IOS_HOSTKEY_PINS_RESET_ERROR \(error)") }
    }
}
#endif
