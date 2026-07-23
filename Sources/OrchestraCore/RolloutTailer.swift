import Foundation

/// One tailed rollout line WITH its provenance: the raw `line`, the byte `startOffset` where the line
/// begins in the file, and the `path` it was read from. B3's held-relaunch confirm fences on this —
/// a fileTail confirm requires `path == lease.tailPath && startOffset >= lease.tailWatermark`, so a
/// stale pre-kill line (below the watermark) or a line from a different rollout can never confirm.
public struct TailedLine: Sendable, Equatable {
    public let line: String
    public let startOffset: Int64
    public let path: String
    public init(line: String, startOffset: Int64, path: String) {
        self.line = line; self.startOffset = startOffset; self.path = path
    }
}

/// The daemon-side telemetry TRANSPORT for `fileTail` agents (Codex). It owns nothing agent-specific:
/// it tails a rollout/transcript file, tracking a per-card byte offset, and hands complete lines to the
/// caller, which passes each to `adapter.parse(.fileTail(line:))`. The split of concerns is the seam —
/// the transport never inspects JSON (that's the adapter's parse), the adapter never touches files.
///
/// `newLines` returns only NEWLINE-TERMINATED lines appended since the last call for that card, each
/// carrying its byte start offset + path (`TailedLine`); a trailing partial line is held until the
/// writer completes it (rollout writes are line-at-a-time but a poll can land mid-write). A file
/// shorter than the stored offset (rotation/truncation) resets to 0.
public actor RolloutTailer {
    private var offsets: [UUID: UInt64] = [:]

    public init() {}

    public func newLines(cardId: UUID, path: String) -> [TailedLine] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        var start = offsets[cardId] ?? 0
        if size < start { start = 0 }                       // rotation/truncation → re-read from the top
        guard size > start else { offsets[cardId] = size; return [] }

        try? fh.seek(toOffset: start)
        let data = fh.readDataToEndOfFile()
        guard let lastNL = data.lastIndex(of: 0x0A) else {  // no complete line yet — hold the partial
            return []
        }
        let consumable = data[...lastNL]                    // through the final newline (inclusive)
        offsets[cardId] = start + UInt64(consumable.count)

        // Walk newline-delimited segments, stamping each line with its ABSOLUTE file byte offset
        // (`start + lineStart`). Empty segments (blank lines) advance the offset but are not emitted —
        // preserving the prior `omittingEmptySubsequences` behavior while keeping offsets exact.
        let bytes = [UInt8](consumable)
        var out: [TailedLine] = []
        var lineStart = 0
        for i in 0..<bytes.count where bytes[i] == 0x0A {
            if i > lineStart {
                out.append(TailedLine(line: String(decoding: bytes[lineStart..<i], as: UTF8.self),
                                      startOffset: Int64(start) + Int64(lineStart), path: path))
            }
            lineStart = i + 1
        }
        return out
    }

    /// The rollout's current EOF byte offset — a STATELESS file stat (no per-card cursor), so it can run
    /// inside `finishLaunch`'s kill→ensure off-actor hop to capture the post-kill/pre-launch watermark
    /// with no extra actor suspension. A missing/unreadable file is `0`.
    public static func eofOffset(path: String) -> Int64 {
        guard let fh = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? fh.close() }
        return Int64((try? fh.seekToEnd()) ?? 0)
    }

    /// Drop a card's cursor (on death/archive) so a later id reusing the path re-reads from 0.
    public func forget(_ cardId: UUID) { offsets[cardId] = nil }

    /// Bring-up cursor seed: start tailing at `offset` UNLESS a cursor already exists (an existing
    /// cursor means continuous tailing — never skip forward over unread lines). With teardown's
    /// `forget`, this is what makes a resumed/reopened card start at its rollout's current EOF instead
    /// of replaying the file from byte 0 into the status funnel.
    public func seedCursor(_ cardId: UUID, at offset: UInt64) {
        if offsets[cardId] == nil { offsets[cardId] = offset }
    }
}
