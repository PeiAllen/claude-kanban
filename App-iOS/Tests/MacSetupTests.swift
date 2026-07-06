import XCTest
@testable import OrchestraiOS
import OrchestraKit

/// Unit tests for the guided-onboarding view-model — the pure validation + connection-building logic
/// (`MacSetupModel`). The actual connect is driven by `BoardModel` and proven by the loopback e2e; here we
/// pin the decisions that gate the "Test" button and the connection it produces.
@MainActor
final class MacSetupTests: XCTestCase {

    func testBlankTargetIsNotTestableAndHasNoError() {
        let vm = MacSetupModel()
        vm.target = ""
        XCTAssertNil(vm.targetRejection, "a blank field is 'unset', not an error")
        XCTAssertFalse(vm.canTest)
        XCTAssertNil(vm.makeConnection())
    }

    func testTailnetTargetIsTestableAndBuildsAMacConnection() {
        let vm = MacSetupModel()
        vm.target = "me@my-mac.tailnet.ts.net"
        XCTAssertNil(vm.targetRejection)
        XCTAssertTrue(vm.canTest)
        let conn = vm.makeConnection()
        XCTAssertEqual(conn?.kind, .remote)
        XCTAssertEqual(conn?.sshTarget, "me@my-mac.tailnet.ts.net")
        // One field only: the socket path + tmux socket come from the Mac defaults.
        XCTAssertEqual(conn?.remoteSocketPath, Connection.defaultMacSocketPath)
    }

    func testTargetIsTrimmedBeforeBuilding() {
        let vm = MacSetupModel()
        vm.target = "  me@my-mac.tailnet.ts.net  "
        XCTAssertEqual(vm.makeConnection()?.sshTarget, "me@my-mac.tailnet.ts.net")
    }

    func testNonTailnetTargetIsRejectedAndNotTestable() {
        let vm = MacSetupModel()
        vm.target = "me@192.168.1.10"                 // LAN IP — blind host-key accept would be unsafe
        XCTAssertNotNil(vm.targetRejection)
        XCTAssertFalse(vm.canTest)
        XCTAssertNil(vm.makeConnection())
    }

    func testMalformedTargetIsRejected() {
        let vm = MacSetupModel()
        vm.target = "not-a-target"                     // no user@host
        XCTAssertNotNil(vm.targetRejection)
        XCTAssertFalse(vm.canTest)
    }

    func testWaitForLiveReturnsTrueAsSoonAsStateIsLive() async {
        let vm = MacSetupModel()
        let live = await vm.waitForLive(timeout: 1) { .live }
        XCTAssertTrue(live)
    }

    func testWaitForLiveTimesOutWhenNeverLive() async {
        let vm = MacSetupModel()
        let live = await vm.waitForLive(timeout: 0.5) { .retrying }
        XCTAssertFalse(live, "retrying/down must not be reported as connected")
    }
}
