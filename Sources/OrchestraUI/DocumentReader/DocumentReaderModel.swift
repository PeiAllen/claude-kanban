import Foundation
import SwiftUI
import OrchestraKit

/// The reader's decision logic, split from its view so it can be tested without SwiftUI.
///
/// The list and the content are SEPARATE loads. Shipping content with the list is fine for three
/// changed documents and wrong for two hundred discovered documents — a phone pays for every byte, and the
/// reader only ever displays one document at a time.
///
/// Three behaviours here are subtle enough to state up front:
///
///  - **Staying current is a POLL, not a subscription.** Two of them, at different rates: the open
///    document is asked about often and cheaply, the document set rarely and expensively. Both send a
///    validator, so a poll that finds nothing transfers nothing. This replaced a filesystem watcher —
///    see `docs/09-design-decisions.md` for why.
///  - **The quote is frozen at SELECTION time.** Polling is paused while composing and the file may
///    move underneath, so re-deriving the excerpt at send time could quote text the user never saw.
///  - **Every load is epoch-gated.** Two polls can complete out of order; without a gate the older
///    answer overwrites the newer one and nothing repairs it until the next tick.
@MainActor
public final class DocumentReaderModel: ObservableObject {
    /// Every document in the working directory, changed-first (the daemon sorts).
    @Published public private(set) var documents: [DocRef] = []
    /// The open document's content, fetched on demand. `nil` while loading or on failure.
    @Published public private(set) var content: String?
    @Published public private(set) var loadingList = true
    @Published public private(set) var loadingContent = false
    @Published public private(set) var selected: DocRef?

    /// The document-list filter. Most workspaces have far more documents than a chip bar can show.
    @Published public var search = ""
    /// Whether the "everything else" section is expanded. The reviewer came for what the card TOUCHED,
    /// so the untouched majority starts collapsed rather than burying it.
    @Published public var showingAll = false
    /// Whether the picker is showing. Opens automatically when nothing is selected yet.
    @Published public var browsing = false

    /// The frozen anchor for the comment being written. Non-nil once the user picks a passage.
    @Published public private(set) var comment: DocumentComment?
    @Published public var draft = ""
    @Published public private(set) var sending = false

    public var composing: Bool { comment != nil }
    /// The validators. Each is whatever the daemon last answered with, sent back on the next poll so it
    /// can reply "unchanged" instead of resending. Same contract as an HTTP `ETag`.
    private var contentHash: String?
    private var listHash: String?
    private var listEpoch = 0
    private var contentEpoch = 0

    public init() {}

    /// Documents this card modified or added — what the reviewer actually came for. `status` is git's
    /// opinion vs the branch base, so it is empty for a workspace git cannot speak about (a scratch
    /// dir, a non-repo), which is why `browseList` falls back to everything in that case.
    public var changedDocuments: [DocRef] { documents.filter { $0.status != nil } }
    /// Everything else in the workspace — present, but not the focus.
    public var otherDocuments: [DocRef] { documents.filter { $0.status == nil } }

    /// What the picker shows right now.
    ///
    /// SEARCH ALWAYS SPANS EVERYTHING: typing a filter means you are looking for a specific document,
    /// and silently excluding untouched ones would make it look absent. Without a search it shows the
    /// changed set, plus the rest only when expanded — and falls back to everything when nothing is
    /// changed, so a scratch card is never an empty screen.
    public var browseList: [DocRef] {
        let q = search.trimmed.lowercased()
        if !q.isEmpty { return documents.filter { $0.path.lowercased().contains(q) } }
        if changedDocuments.isEmpty { return documents }
        return showingAll ? documents : changedDocuments
    }

    /// True when there is an untouched remainder worth offering. Hidden while searching (the search
    /// already spans everything) and when nothing is changed (the list is already everything).
    public var canRevealAll: Bool {
        search.trimmed.isEmpty && !changedDocuments.isEmpty && !otherDocuments.isEmpty
    }

    /// Send is disabled while a request is in flight. That is the ONLY double-send guard, and it is
    /// deliberate: a comment carries no dedup key, because a repeated comment is meaningful and must
    /// never be silently suppressed.
    public var canSend: Bool { !sending && !draft.trimmed.isEmpty && comment != nil }

    // MARK: - loading

    /// Fetch the document LIST unconditionally — first load, and whenever the user opens the picker
    /// rather than waiting for the slow poll.
    public func loadList(fetch: (String?) async -> DocumentList?) async {
        listEpoch &+= 1
        let mine = listEpoch
        let answer = await fetch(nil)                  // nil validator: always answer with documents
        guard mine == listEpoch else { return }        // a newer load already won
        loadingList = false
        guard let answer, let docs = answer.documents else { return }
        listHash = answer.hash
        adopt(docs)
    }

    /// Take a new document set, keeping the selection if it survived.
    private func adopt(_ docs: [DocRef]) {
        documents = docs
        if let sel = selected, !docs.contains(where: { $0.path == sel.path }) {
            // The open document was deleted. Stop showing it rather than leaving stale text on screen.
            selected = nil
            content = nil
            contentHash = nil
            cancelComment()                            // its anchor no longer refers to anything
        }
        // Deliberately does NOT auto-select: `selected` must never be set without its content having
        // been fetched, or the reader claims a document is open while showing nothing. Choosing what
        // to open belongs to the caller, which can await the content load.
        if selected == nil { browsing = true }
    }

    /// Open a document: fetch its content. Epoch-gated separately from the list, so a slow content
    /// load for a document the user has already navigated away from cannot land.
    public func open(_ doc: DocRef, fetch: (String, String?) async -> DocumentContent?) async {
        selected = doc
        browsing = false
        cancelComment()                                // an anchor belongs to the document it came from
        // Clear the body FIRST. Leaving the previous document's text on screen under the new path lets
        // a selection freeze a comment that cites one file and quotes another — the same "wrong is
        // worse than coarse" failure the line refinement guards, at document granularity.
        content = nil
        contentHash = nil
        loadingContent = true
        contentEpoch &+= 1
        let mine = contentEpoch
        let answer = await fetch(doc.path, nil)        // nil validator: always answer with content
        guard mine == contentEpoch else { return }
        content = answer?.content
        contentHash = answer?.hash
        loadingContent = false
    }

    /// THE FAST POLL — ask whether the open document has moved, and take the new bytes if it has.
    ///
    /// Called on a short cadence while the reader is on screen. Costs one small request and no bytes
    /// when nothing changed, because `contentHash` is a validator and the daemon answers conditionally.
    ///
    /// Held while composing, so text cannot move under someone mid-sentence. Deferred, not dropped: the
    /// next tick after the field closes picks it up, and the validator makes that free.
    public func pollContent(_ fetch: (String, String?) async -> DocumentContent?) async {
        guard !composing, let sel = selected, let have = contentHash else { return }
        contentEpoch &+= 1
        let mine = contentEpoch
        let answer = await fetch(sel.path, have)
        guard mine == contentEpoch, let answer, let body = answer.content else { return }
        content = body
        contentHash = answer.hash
    }

    /// THE SLOW POLL — ask whether the document SET has moved.
    ///
    /// Separate from the content poll because it is the expensive one: the daemon walks the tree, and
    /// when the validator does not match it also pays two git forks to re-derive every status. So this
    /// runs on its own much slower cadence, and a document the agent creates appears within it rather
    /// than instantly. Opening the picker asks unconditionally, which is the impatient path.
    public func pollList(_ fetch: (String?) async -> DocumentList?) async {
        guard !composing else { return }
        listEpoch &+= 1
        let mine = listEpoch
        let answer = await fetch(listHash)
        guard mine == listEpoch, let answer else { return }
        listHash = answer.hash
        guard let docs = answer.documents else { return }
        adopt(docs)
    }

    // MARK: - selecting + commenting

    /// Freeze a comment against the document as it reads RIGHT NOW.
    public func select(_ selection: DocumentSelection) {
        guard let doc = selected, let body = content else { return }
        comment = DocumentComment.capture(path: doc.path, source: body,
                                      startLine: selection.startLine, endLine: selection.endLine)
    }

    public func cancelComment() {
        comment = nil
        draft = ""
    }

    /// Build the message, hand it to `deliver`, and clear on success. Returns the sent text so a caller
    /// can assert on it.
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
