import XCTest
@testable import OrchestraKit

// F3 dev-transport resolver. Lives in OrchestraCoreTests because that target already `@testable import`s
// OrchestraKit and the package has no separate OrchestraKitTests target (see reconciliation O-1).
final class ConnectionSocketResolverTests: XCTestCase {
    func testLocalUsesDevOverrideWhenSet() {
        let env = ["ORCH_DEV_SOCKET": "/Users/dev/Library/Application Support/Orchestra/orchestrad.sock"]
        let path = ConnectionSocketResolver.socketPath(for: .local, env: env)
        XCTAssertEqual(path, "/Users/dev/Library/Application Support/Orchestra/orchestrad.sock")
    }

    func testLocalFallsBackToConfigWhenNoOverride() {
        let path = ConnectionSocketResolver.socketPath(for: .local, env: [:])
        XCTAssertEqual(path, Config.socketPath)
    }

    func testEmptyOverrideIsIgnored() {
        let path = ConnectionSocketResolver.socketPath(for: .local, env: ["ORCH_DEV_SOCKET": ""])
        XCTAssertEqual(path, Config.socketPath)
    }

    func testRemoteConnectionIgnoresDevOverride() {
        // The override is a LOCAL-only Simulator shortcut; a remote resolves to its own socket path.
        let remote = Connection(name: "linux-box", kind: .remote,
                                sshTarget: "box", remoteSocketPath: "/run/orchestrad.sock")
        let path = ConnectionSocketResolver.socketPath(
            for: remote, env: ["ORCH_DEV_SOCKET": "/should/not/be/used"])
        XCTAssertEqual(path, "/run/orchestrad.sock")
        XCTAssertNotEqual(path, "/should/not/be/used")
    }
}
