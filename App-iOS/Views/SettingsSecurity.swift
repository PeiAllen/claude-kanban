import SwiftUI

/// Terminal SSH target (M5): the `user@host` the phone attaches terminals (and takeovers) over. Persisted
/// client-side under `SSHEndpoint.targetDefaultsKey`, which `SSHEndpoint.resolve` reads first (falling back
/// to the `ORCH_SSH_TARGET` env for the dev/Simulator path). Without this set, a takeover leases fine but
/// the terminal can't attach — it just shows the "configure SSH" banner. Inline validation reuses the same
/// tailnet guard the terminal enforces at connect time (`settingsRejectionReason`), so a bad target is
/// caught here with the exact reason rather than failing later.
struct TerminalTargetSettingsSection: View {
    @AppStorage(SSHEndpoint.targetDefaultsKey) private var target = ""

    /// Non-nil while the current field is a target the terminal would refuse (bad shape / non-tailnet).
    private var rejection: String? { SSHEndpoint.settingsRejectionReason(for: target) }

    var body: some View {
        Section {
            HStack {
                Text("SSH target").foregroundStyle(.secondary)
                TextField("me@my-mac.tailnet.ts.net", text: $target)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
            }
            if let rejection {
                Label(rejection, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Terminal")
        } footer: {
            Text("The Mac's Tailscale SSH target the phone attaches terminals and takeovers over — its "
                 + "MagicDNS name (user@my-mac.tailnet.ts.net) or a 100.64.0.0/10 tailnet IP. Must be a "
                 + "tailnet address: iOS trusts the server's host key only because the connection rides "
                 + "Tailscale.")
        }
    }
}

/// Security settings — reset the pinned SSH **host key**. The terminal pins the Mac's host key on first
/// connect (trust-on-first-use) and refuses a *changed* key as a possible MITM (security #5). If you
/// deliberately re-keyed the Mac (fresh OS install, regenerated host key), the pin would otherwise be a
/// dead end — this clears it so the next connect re-trusts on first use.
struct SecuritySettingsSection: View {
    /// The terminal pins by the resolved SSH endpoint host (`ORCH_SSH_TARGET`). Read-only use of the
    /// endpoint parser — no connect-setup changes (keeps this off the sibling tailnet-guard card's turf).
    private var host: String? { SSHEndpoint.resolve()?.host }
    private let store = SSHHostKeyPinStore()

    @State private var confirming = false
    @State private var status: String?

    var body: some View {
        Section {
            Button(role: .destructive) { confirming = true } label: {
                Label(host.map { "Reset trusted host key for \($0)" } ?? "Reset all trusted host keys",
                      systemImage: "lock.rotation")
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Security")
        } footer: {
            Text("The terminal pins the Mac's SSH host key on first connect and refuses a changed key "
                 + "(possible man-in-the-middle). Reset it only if you deliberately re-keyed the Mac.")
        }
        .confirmationDialog("Reset trusted host key?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next connection will trust whatever host key the server presents "
                 + "(trust-on-first-use). Only do this if you re-keyed the Mac yourself.")
        }
    }

    private func reset() {
        do {
            if let host { try store.reset(host: host) } else { try store.resetAll() }
            status = "Trusted host key cleared — the next connect will re-pin."
        } catch {
            status = "Couldn't clear the pin: \(error)"
        }
    }
}
