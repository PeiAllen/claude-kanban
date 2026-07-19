#if DEBUG
import SwiftUI
import OrchestraKit
import OrchestraUI

/// A DEBUG-only harness to exercise the T1 terminal seam end-to-end before the product surfaces
/// (T2 Terminal tab / T3 Agent tab / T4 takeover) exist to mount it. It builds a `TmuxTarget` from
/// entered fields and hands it to the Environment-injected `terminalHost` — the exact call path
/// T2/T3/T4 will use. Compiled out of Release; not a product surface.
struct DebugTerminalTab: View {
    @Environment(\.terminalHost) private var terminalHost
    @EnvironmentObject private var model: BoardModel

    @State private var socket: String
    @State private var session: String
    @State private var window: String
    @State private var attached: Bool
    // PR T4 takeover entry (temporary DEBUG surface). The REAL entry — the "Take Over Agent Terminal"
    // button on the Agent tab — is T3's to wire; this exercises the full lease + attach flow before it exists.
    @State private var cardId: String
    @State private var takeover: Bool

    init() {
        // Prefill + optionally auto-attach from the launch environment so a `simctl` harness can drive
        // the terminal without UI text entry (there's no XCUITest here). ORCH_T1_AUTOATTACH=1 attaches
        // immediately when a session is provided; ORCH_T4_AUTOTAKEOVER=1 opens the takeover surface for a
        // card id (ORCH_T4_CARD).
        let env = ProcessInfo.processInfo.environment
        _socket = State(initialValue: env["ORCH_T1_SOCKET"] ?? "orchestra")
        let s = env["ORCH_T1_SESSION"] ?? ""
        _session = State(initialValue: s)
        _window = State(initialValue: env["ORCH_T1_WINDOW"] ?? "agent")
        _attached = State(initialValue: env["ORCH_T1_AUTOATTACH"] == "1" && !s.isEmpty)
        let card = env["ORCH_T4_CARD"] ?? ""
        _cardId = State(initialValue: card)
        _takeover = State(initialValue: env["ORCH_T4_AUTOTAKEOVER"] == "1" && !card.isEmpty)
    }

    private var target: TmuxTarget {
        TmuxTarget(socket: socket, session: session, window: window,
                   kind: window == "agent" ? .agent : .shell,
                   target: "\(session):\(window)",
                   attach: "tmux -L \(socket) attach -t \(session):\(window)")
    }

    var body: some View {
        // Image-tap repro (fix/ios-terminal-image-tap): a no-daemon SwiftUI harness that mounts the real
        // IOSTerminalView over a LoopbackChannel feeding a published-image marker, wired to onOpenImage.
        // Drives the exact tap-arbitration code (link-tap overlay vs SwiftTerm's own tap + the arm-tap) so
        // idb synthetic touches can confirm a tap on the marker opens the image instead of raising the
        // keyboard. Gated behind ORCH_IMGTAP_DEMO=1; not a product surface. See the PR body.
        if ProcessInfo.processInfo.environment["ORCH_IMGTAP_DEMO"] == "1" {
            return AnyView(ImageTapDemoView())
        }
        return AnyView(mainBody)
    }

    private var mainBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if attached {
                    terminalHost.attach(target: target)
                        .background(Color.black)
                    Divider()
                    Button("Detach") { attached = false }
                        .padding(8)
                } else {
                    Form {
                        Section("tmux target") {
                            TextField("socket", text: $socket).autocorrectionDisabled()
                            TextField("session (orchestra-<id>)", text: $session)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            TextField("window", text: $window).autocorrectionDisabled()
                        }
                        Section {
                            Button("Attach terminal") { attached = true }
                                .disabled(session.isEmpty)
                        } footer: {
                            Text("SSH target: \(SSHEndpoint.resolve(connection: model.connections.active).map { "\($0.user)@\($0.host):\($0.port)" } ?? "unset — add a Mac connection or set ORCH_SSH_TARGET")")
                        }
                    }
                }
            }
            .navigationTitle("Terminal (dev)")
        }
        .fullScreenCover(isPresented: $takeover) {
            if let id = UUID(uuidString: cardId) {
                AgentTakeoverView(cardId: id, model: model) { takeover = false }
                    .environmentObject(model)
            }
        }
    }
}

/// DEBUG image-tap repro. Reproduces the live-shell surface (a `control` handle + `forwardScroll`, so the
/// arm-tap and wheel-pan recognisers are present) — the richest tap-arbitration case — over a loopback
/// channel, with no network or daemon. A tap on the marker row must flip the banner to "OPENED …"; a tap
/// on the plain row must leave it "…awaiting tap" (and raise the keyboard, proving fall-through is intact).
struct ImageTapDemoView: View {
    @StateObject private var control = TerminalControl()
    @State private var opened: UUID?
    // A fixed reference so the expected id is known ahead of the tap (the harness asserts on its prefix).
    private static let referenceID = UUID(uuidString: "1A2B3C4D-5E6F-4A8B-9C0D-1E2F3A4B5C6D")!

    private var banner: String {
        let marker = TranscriptImageMarker.render(referenceID: Self.referenceID, caption: "diagram")
        return [
            "tap the image link on the next row:",
            marker,
            "plain text row — a tap here raises the keyboard",
        ].joined(separator: "\n") + "\n"
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(opened.map { "OPENED \($0.uuidString.prefix(8))" } ?? "…awaiting tap")
                .font(.headline.monospaced())
                .foregroundStyle(opened == nil ? Color.yellow : Color.green)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(opened == nil ? Color.black : Color.green.opacity(0.25))
                .accessibilityIdentifier("imgtap-status")

            IOSTerminalView(makeChannel: { LoopbackChannel(banner: banner) },
                            control: control, forwardScroll: true,
                            onOpenImage: { opened = $0 })
                .background(Color.black)
        }
        .ignoresSafeArea(.keyboard)
    }
}
#endif
