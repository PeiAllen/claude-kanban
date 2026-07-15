import Foundation
import Testing
@testable import OrchestraCore

/// Shared helpers for integration tests that touch real git / tmux.
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

    /// Absolute path to the bundled fake-agent.sh fixture.
    static var fakeAgentPath: String {
        Bundle.module.path(forResource: "Fixtures/fake-agent", ofType: "sh")
            ?? Bundle.module.path(forResource: "fake-agent", ofType: "sh")
            ?? ""
    }

    static func tempDir(_ tag: String) -> String {
        let dir = NSTemporaryDirectory() + "orch-it-\(tag)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}

@Suite("Integration support sanity")
struct IntegrationSupportTests {
    @Test("fixtures bundle resolves")
    func fixtureResolves() {
        // The fake-agent fixture should be present in the test bundle.
        #expect(!IntegrationSupport.fakeAgentPath.isEmpty)
    }
}
