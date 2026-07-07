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
}
#endif
