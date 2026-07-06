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
                        // T3 wires the real Agent-tab "Take Over Agent Terminal" entry; this DEBUG button
                        // drives the same flow (lease → takeover attach → heartbeat) against a card id.
                        Section("Takeover (T4)") {
                            TextField("card id (UUID)", text: $cardId)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            Button("Take Over Agent Terminal") { takeover = true }
                                .disabled(UUID(uuidString: cardId) == nil)
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
#endif
