import Foundation
import SwiftUI
import OrchestraKit

/// The reader's decision logic, split from its view so it can be tested without SwiftUI.
///
/// Three behaviours here are subtle enough to be worth stating up front:
///
///  - **The quote is frozen at SELECTION time.** Refresh is paused while composing and the file may
///    move underneath, so re-deriving the excerpt at send time could quote text the user never saw.
///  - **Refresh is deferred, not dropped, while composing.** Text must not move under someone
///    mid-sentence, but the pending change still applies the moment the field closes.
///  - **Every load is epoch-gated.** Two rapid edits can complete out of order; without a gate the
///    older response overwrites the newer one and nothing repairs it, because no further event is
///    coming.
@MainActor
public final class NoteReaderModel: ObservableObject {
    @Published public private(set) var notes: [NoteFile] = []
    @Published public private(set) var loading = true
    @Published public var selectedPath: String?

    /// The frozen anchor for the comment being written. Non-nil once the user picks a passage.
    @Published public private(set) var comment: NoteComment?
    @Published public var draft = ""
    @Published public private(set) var sending = false

    /// True while the compose field is open. Live refresh is held off for exactly this window.
    public var composing: Bool { comment != nil }
    /// A change arrived while composing; applied when the field closes.
    private var pendingRefresh = false
    /// Monotonic load counter. A response whose epoch is stale is discarded.
    private var loadEpoch = 0

    public init() {}

    public var current: NoteFile? {
        notes.first { $0.path == selectedPath } ?? notes.first
    }

    /// Send is disabled while a request is in flight. That is the ONLY double-send guard, and it is
    /// deliberate: a comment carries no dedup key, because a deliberate re-send is meaningful and must
    /// never be silently suppressed.
    public var canSend: Bool { !sending && !draft.trimmed.isEmpty && comment != nil }

    // MARK: - loading

    /// Fetch the card's changed notes. Epoch-gated, so an older in-flight load can never overwrite a
    /// newer one.
    public func load(fetch: () async -> [NoteFile]) async {
        loadEpoch &+= 1
        let mine = loadEpoch
        let fetched = await fetch()
        guard mine == loadEpoch else { return }        // a newer load already won
        notes = fetched
        if selectedPath == nil || !fetched.contains(where: { $0.path == selectedPath }) {
            selectedPath = fetched.first?.path
        }
        loading = false
    }

    /// A live change for this card. Held while composing so the text cannot move mid-sentence.
    public func noteChanged(fetch: @escaping () async -> [NoteFile]) async {
        guard !composing else { pendingRefresh = true; return }
        await load(fetch: fetch)
    }

    /// Apply anything that arrived while the compose field was open.
    public func applyPendingRefresh(fetch: @escaping () async -> [NoteFile]) async {
        guard pendingRefresh else { return }
        pendingRefresh = false
        await load(fetch: fetch)
    }

    // MARK: - selecting + commenting

    /// Freeze a comment against the note as it reads RIGHT NOW.
    public func select(_ selection: NoteSelection) {
        guard let note = current else { return }
        comment = NoteComment.capture(path: note.path, source: note.content,
                                      startLine: selection.startLine, endLine: selection.endLine)
    }

    public func cancelComment() {
        comment = nil
        draft = ""
    }

    /// Build the message, hand it to `send`, and clear on success. Returns the text that was sent so a
    /// caller can assert on it.
    @discardableResult
    public func send(_ deliver: (String) async -> Bool) async -> String? {
        guard let c = comment, !draft.trimmed.isEmpty, !sending else { return nil }
        sending = true
        let message = c.message(note: draft)
        let ok = await deliver(message)
        sending = false
        guard ok else { return nil }                   // keep the draft so the user can retry
        comment = nil
        draft = ""
        return message
    }
}
