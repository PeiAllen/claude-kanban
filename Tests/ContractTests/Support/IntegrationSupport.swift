import Foundation

/// Shared helpers for contract tests that touch real git / tmux. (The E2E tier carries its own copy
/// with the fixture-bundle lookup; these two small helpers are duplicated rather than sharing a target.)
enum IntegrationSupport {
    /// Is a tool available on PATH?
    static func hasTool(_ name: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", name]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static var gitAvailable: Bool { hasTool("git") }
    static var tmuxAvailable: Bool { hasTool("tmux") }

    static func tempDir(_ tag: String) -> String {
        let dir = NSTemporaryDirectory() + "orch-it-\(tag)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
