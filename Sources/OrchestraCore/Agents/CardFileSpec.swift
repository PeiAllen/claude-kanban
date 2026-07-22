import Foundation
import OrchestraKit

/// A derived per-card file that Orchestra writes into a directory it owns, OUTSIDE the card's worktree,
/// and must reap when the card is gone. Pure data — the single home of the djb2 hash that was duplicated
/// byte-for-byte across `ClaudeCodeAdapter.cardSettingsPath` and `CodexLaunchConfiguration.profileName`.
///
/// A writer builds its path from a token it computes locally (it holds an `AdapterContext`, not a `Task`);
/// the sweep derives the token from a live `Task`. `path(token:)` is total by design so both callers can
/// reach it — the token/path consistency per writer is pinned by a test (see `CardFileSpecTests` + the
/// adapter consistency tests), not by the type.
public struct CardFileSpec: Sendable {
    /// How a card maps to its filename token.
    public enum Key: Sendable {
        case cwdHash   // djb2(card.cwd) — the launch configs. Cards sharing a cwd share the file.
        case shortId   // card.shortId  — the inspect read-only settings.
    }
    public let directory: String
    public let prefix: String
    public let suffix: String
    public let key: Key

    public init(directory: String, prefix: String, suffix: String, key: Key) {
        self.directory = directory; self.prefix = prefix; self.suffix = suffix; self.key = key
    }

    /// The absolute path for a given filename token. Total (no precondition): writers pass a locally-built
    /// token, the sweep passes `token(for:)`.
    public func path(token: String) -> String { "\(directory)/\(prefix)\(token)\(suffix)" }

    /// The filename token this card would use, per `key`.
    public func token(for card: Task) -> String {
        switch key {
        case .cwdHash: return Self.cwdHash(card.cwd)
        case .shortId: return card.shortId
        }
    }

    /// The ONE djb2 (5381 / ×33) over the cwd's UTF-8, hex. MUST stay byte-identical to the legacy adapter
    /// implementations — any drift silently orphans every file already on disk.
    public static func cwdHash(_ cwd: String) -> String {
        var h: UInt64 = 5381
        for b in cwd.utf8 { h = (h &* 33) &+ UInt64(b) }
        return String(h, radix: 16)
    }
}
