import Foundation

/// The daemon-side telemetry TRANSPORT for `fileTail` agents (Codex). It owns nothing agent-specific:
/// it tails a rollout/transcript file, tracking a per-card byte offset, and hands complete lines to the
/// caller, which passes each to `adapter.parse(.fileTail(line:))`. The split of concerns is the seam —
/// the transport never inspects JSON (that's the adapter's parse), the adapter never touches files.
///
/// `newLines` returns only NEWLINE-TERMINATED lines appended since the last call for that card; a
/// trailing partial line is held until the writer completes it (rollout writes are line-at-a-time but
/// a poll can land mid-write). A file shorter than the stored offset (rotation/truncation) resets to 0.
public actor RolloutTailer {
    private var offsets: [UUID: UInt64] = [:]

    public init() {}

    public func newLines(cardId: UUID, path: String) -> [String] {
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
        return String(decoding: consumable, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Drop a card's cursor (on death/archive) so a later id reusing the path re-reads from 0.
    public func forget(_ cardId: UUID) { offsets[cardId] = nil }
}
