#if DEBUG
import Foundation
import OrchestraUI

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

    /// Headless UI-verification hook, the iOS counterpart of the Mac app's `ORCH_SHOW`. Screenshotting
    /// an iOS screen otherwise means synthetic taps (an `idb` dependency) or driving the Simulator
    /// window on the human's actual display; both are worse than a DEBUG-only env switch that puts the
    /// app on the screen under test by itself.
    ///
    ///   ORCH_IOS_SHOW=detail   push the first card's detail (pinned header + tabs)
    ///
    /// Selection is client state (`selectedId` drives `navigationDestination`), so no daemon-side
    /// seeding can reach it — this is the only non-intrusive lever. Compiled out of Release.
    static func applyLaunchHook(model: BoardModel) async {
        guard ProcessInfo.processInfo.environment["ORCH_IOS_SHOW"] == "detail" else { return }
        // The board arrives asynchronously over the transport; wait for the first card rather than
        // racing the connect (and give up rather than hang if nothing ever lands).
        for _ in 0..<80 {
            let selected = await MainActor.run { () -> Bool in
                guard let first = model.tasks.first else { return false }
                model.selectedId = first.id
                return true
            }
            if selected { return }
            try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
#endif
