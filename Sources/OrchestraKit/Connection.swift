import Foundation

/// A client-side target the app/phone can talk to: the built-in local daemon, or a remote Linux box
/// reached over SSH. Lives in the shared core so iOS reuses it. The wire protocol is identical for all
/// kinds; only *reachability* differs (direct UDS vs SSH-forwarded socket).
public struct Connection: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public enum Kind: String, Codable, Sendable { case local, remote }
    public var kind: Kind
    public var sshTarget: String?
    public var identityFile: String?
    public var remoteSocketPath: String?
    public var remoteTmuxSocket: String

    public init(id: UUID = UUID(), name: String, kind: Kind, sshTarget: String? = nil,
                identityFile: String? = nil, remoteSocketPath: String? = nil,
                remoteTmuxSocket: String = "orchestra") {
        self.id = id; self.name = name; self.kind = kind
        self.sshTarget = sshTarget; self.identityFile = identityFile
        self.remoteSocketPath = remoteSocketPath; self.remoteTmuxSocket = remoteTmuxSocket
    }

    /// Stable id for the built-in local connection (never persisted; synthesized).
    public static let localId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static var local: Connection {
        Connection(id: localId, name: "This Mac", kind: .local, remoteTmuxSocket: Config.tmuxSocket)
    }
    public var isLocal: Bool { kind == .local }
}
