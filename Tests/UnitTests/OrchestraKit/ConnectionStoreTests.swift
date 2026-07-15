import Foundation
import Testing
@testable import OrchestraCore

@Suite("Connection + ConnectionStore")
struct ConnectionStoreTests {

    // MARK: - Connection value

    @Test("built-in local connection is stable + local kind")
    func builtInLocal() {
        let l = Connection.local
        #expect(l.kind == .local)
        #expect(l.id == Connection.localId)
        #expect(l.isLocal)
    }

    @Test("a remote Connection round-trips through Codable")
    func codableRoundTrip() throws {
        let c = Connection(name: "work box", kind: .remote, sshTarget: "me@box",
                           identityFile: "~/.ssh/id_ed25519",
                           remoteSocketPath: "/home/me/.local/share/orchestra/orchestrad.sock",
                           remoteTmuxSocket: "orchestra")
        let data = try OrchestraJSON.wire.encode(c)
        let back = try OrchestraJSON.decoder.decode(Connection.self, from: data)
        #expect(back == c)
    }

    // MARK: - ConnectionStore

    private func freshStore() -> ConnectionStore {
        let d = UserDefaults(suiteName: "orch-test-\(UUID().uuidString)")!
        return ConnectionStore(defaults: d)
    }

    @Test("store starts with only the built-in local, active = local")
    func startsLocal() {
        let s = freshStore()
        #expect(s.all.count == 1)
        #expect(s.all.first?.isLocal == true)
        #expect(s.active.id == Connection.localId)
    }

    @Test("upsert adds a remote, persists it, and it becomes selectable")
    func upsertRemote() {
        let s = freshStore()
        let c = Connection(name: "box", kind: .remote, sshTarget: "me@box",
                           remoteSocketPath: "/x/orchestrad.sock")
        s.upsert(c)
        #expect(s.remotes.count == 1)
        #expect(s.all.count == 2)
        s.activeId = c.id
        #expect(s.active.sshTarget == "me@box")
    }

    @Test("upsert on an existing id edits in place (no duplicate)")
    func upsertEdits() {
        let s = freshStore()
        var c = Connection(name: "box", kind: .remote, sshTarget: "me@box")
        s.upsert(c)
        c.name = "work box"; c.sshTarget = "me@box2"
        s.upsert(c)
        #expect(s.remotes.count == 1)
        #expect(s.remotes.first?.name == "work box")
        #expect(s.remotes.first?.sshTarget == "me@box2")
    }

    @Test("delete removes a remote; deleting the active one falls back to local")
    func deleteFallsBack() {
        let s = freshStore()
        let c = Connection(name: "box", kind: .remote, sshTarget: "me@box")
        s.upsert(c); s.activeId = c.id
        s.delete(c.id)
        #expect(s.remotes.isEmpty)
        #expect(s.active.id == Connection.localId)
    }

    @Test("edits persist across a fresh store on the same suite")
    func persistsAcrossInstances() {
        let d = UserDefaults(suiteName: "orch-test-\(UUID().uuidString)")!
        let s1 = ConnectionStore(defaults: d)
        let c = Connection(name: "box", kind: .remote, sshTarget: "me@box")
        s1.upsert(c); s1.activeId = c.id
        let s2 = ConnectionStore(defaults: d)
        #expect(s2.remotes.first?.sshTarget == "me@box")
        #expect(s2.active.id == c.id)
    }

    @Test("upsert ignores a local-kind connection (local is synthesized, never stored)")
    func upsertIgnoresLocal() {
        let s = freshStore()
        s.upsert(Connection(name: "nope", kind: .local))
        #expect(s.remotes.isEmpty)
    }
}
