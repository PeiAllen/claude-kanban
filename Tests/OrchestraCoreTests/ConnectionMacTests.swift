import Foundation
import Testing
@testable import OrchestraKit

/// P1.4 — the single "my Mac over Tailscale" connection factory. Reuses the existing `.remote` kind
/// (see notes/designs/ios-real-device-transport/02-contract.md).
@Suite("Connection.mac")
struct ConnectionMacTests {
    @Test("mac() builds a .remote connection carrying the tailnet target + default daemon socket")
    func macDefaults() {
        let c = Connection.mac(sshTarget: "me@my-mac.tailnet.ts.net")
        #expect(c.kind == .remote)
        #expect(c.sshTarget == "me@my-mac.tailnet.ts.net")
        #expect(c.remoteSocketPath == Connection.defaultMacSocketPath)
        #expect(c.name == "My Mac")
        #expect(c.isLocal == false)
    }

    @Test("mac() honors an explicit name and socket override")
    func macOverrides() {
        let c = Connection.mac(sshTarget: "me@host.ts.net", name: "Studio",
                               remoteSocketPath: "/tmp/x.sock")
        #expect(c.name == "Studio")
        #expect(c.remoteSocketPath == "/tmp/x.sock")
    }

    @Test("default Mac socket path points at the daemon's Application Support socket")
    func defaultSocket() {
        #expect(Connection.defaultMacSocketPath.hasSuffix("Orchestra/orchestrad.sock"))
    }
}
