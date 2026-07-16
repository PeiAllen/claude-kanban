import Foundation
import Testing
import TestSupport
@testable import OrchestraCore

@Suite("tmux OSC 8 hyperlink transport", .enabled(if: IntegrationSupport.tmuxAvailable), .serialized)
struct HyperlinkTransportTests {
    @Test("embedded tmux preserves an opaque OSC 8 image reference and advertises hyperlinks")
    func preservesImageReference() throws {
        let socket = "orch-link-\(UUID().uuidString.prefix(8))"
        let session = "image-link"
        let id = UUID()
        let url = TranscriptImageLink.url(for: id)
        let visible = "ORCHESTRA_IMAGE_LINK_\(UUID().uuidString)"
        let conf = try #require(SessionManager.bundledConf)
        let script = "printf '\\033]8;id=orchestra-\(id.uuidString.lowercased());\(url)\\033\\\\\(visible)\\033]8;;\\033\\\\\\n'; sleep 5"

        defer { _ = try? Proc.run(["tmux", "-L", socket, "kill-server"]) }
        let started = try Proc.run([
            "tmux", "-L", socket, "-f", conf,
            "new-session", "-d", "-s", session, "/bin/sh", "-c", script,
        ])
        #expect(started.ok)

        let features = try Proc.run(["tmux", "-L", socket, "show-options", "-g", "terminal-features"])
        #expect(features.ok)
        // Assert only what this suite owns — that the tmux client's TERM advertises hyperlinks — rather
        // than pinning the whole ordered feature string, which breaks every time an unrelated feature
        // joins the list (`sync` for Codex render batching already did).
        let ours = try #require(features.stdout
            .split(separator: "\n")
            .first { $0.contains("xterm-256color:") })
        #expect(ours.contains(":hyperlinks"))

        var captured = try Proc.run(["tmux", "-L", socket, "capture-pane", "-e", "-p", "-t", "\(session):0"])
        for _ in 0..<20 where !captured.stdout.contains(visible) {
            Thread.sleep(forTimeInterval: 0.05)
            captured = try Proc.run(["tmux", "-L", socket, "capture-pane", "-e", "-p", "-t", "\(session):0"])
        }
        let open = "\u{1B}]8;id=orchestra-\(id.uuidString.lowercased());\(url)\u{1B}\\"
        #expect(captured.ok)
        #expect(captured.stdout.contains(open))
        #expect(captured.stdout.contains(visible))
        #expect(captured.stdout.contains("\u{1B}]8;;\u{1B}\\"))
    }
}
