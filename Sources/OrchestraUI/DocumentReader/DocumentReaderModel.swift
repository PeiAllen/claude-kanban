import Foundation
import SwiftUI
import OrchestraKit

/// The reader's decision logic, split from its view so it can be tested without SwiftUI.
///
/// The list and the content are SEPARATE loads. Shipping content with the list is fine for three
/// changed documents and wrong for two hundred discovered documents — a phone pays for every byte, and the
/// reader only ever displays one document at a time.
///
/// Four behaviours here are subtle enough to state up front:
///
///  - **Staying current is a POLL, not a subscription.** Two of them, at different rates: the open
///    document is asked about often and cheaply, the document set rarely and expensively. Both send a
///    validator, so a poll that finds nothing transfers nothing. This replaced a filesystem watcher —
///    see `docs/09-design-decisions.md` for why.
///  - **A comment belongs to a READING PASS.** You anchor several passages, write them in any order,
///    and send them one at a time or all at once. The pass lives as long as the document stays open.
///    It is deliberately not durable, the same rule documents themselves follow.
///  - **The quote is frozen at SELECTION time.** The file can move underneath, so re-deriving the
///    excerpt at send time could quote text the user never saw.
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

    /// The reading pass: every passage anchored in this document, in document order.
    @Published public private(set) var comments: [PendingComment] = []
    /// Which card the rail has focused. The page tints that passage more strongly than the rest.
    @Published public var activeComment: UUID?
    /// The passage the page should scroll to.
    ///
    /// Separate from `activeComment` on purpose. The page reports which anchor is at the top of the
    /// viewport, and that report moves the focus — so if scrolling the page also derived a scroll
    /// COMMAND back to the page, the two would chase each other. Only an explicit click sets this.
    @Published public private(set) var revealHighlight: String?
    /// The comments with a request in flight. A set rather than a flag, because one card can be sending
    /// while the reviewer writes the next.
    @Published public private(set) var sending: Set<UUID> = []

    /// Insertion order, to break ties between two comments anchored to the same line. `sort` is not
    /// stable in Swift, so without this the rail could reorder cards on an unrelated change.
    private var nextSeq = 0

    /// Whether the content poll should HOLD.
    ///
    /// While ANY comment is open — written into or not. An anchor is a deliberate act now: you select,
    /// and then you take the offer. So an open card means someone is working on that passage, and the
    /// text under it must not move.
    ///
    /// This deliberately covers the empty card too. Otherwise there is a window between taking the
    /// offer and typing the first character where the agent can rewrite the passage out from under the
    /// anchor, which detaches a comment the reviewer had not even started. The window is only seconds
    /// wide, and it is entirely avoidable.
    ///
    /// SENT comments never hold. Sending is exactly when you want to watch the agent act on what you
    /// said. The residual cost is an abandoned empty card holding the document still — visible in the
    /// rail, and one click to discard.
    public var composing: Bool {
        comments.contains { !$0.sent }
    }

    /// The passages the page must keep tinted. Anything else it is holding is stale.
    public var liveHighlights: [String] { comments.map(\.highlightID) }

    /// The comments that are written but not sent. This is what "Send all" sends.
    public var unsent: [PendingComment] { comments.filter { !$0.sent && !$0.draft.trimmed.isEmpty } }

    /// Whether the sent group is expanded. Collapsed by default, and the same shape as `showingAll` for
    /// the document picker: the thing you came for stays on top, and the rest is one row away.
    @Published public var showingSent = false

    /// Still being written — the top of the rail.
    public var openComments: [PendingComment] { comments.filter { !$0.sent } }
    /// Already delivered. These collapse into a single row, because a long review otherwise ends as a
    /// rail of dimmed cards to dismiss one at a time. Their passages stay tinted either way.
    public var sentComments: [PendingComment] { comments.filter(\.sent) }

    /// Whether a comment is on screen in the rail right now. The focus-follow consults this, so
    /// scrolling the document never focuses a card that is collapsed out of view.
    public func isVisibleInRail(_ id: UUID) -> Bool {
        guard let c = comments.first(where: { $0.id == id }) else { return false }
        return !c.sent || showingSent
    }
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

    /// Send is disabled while that comment's request is in flight. That is the ONLY double-send guard,
    /// and it is deliberate: a comment carries no dedup key, because a repeated comment is meaningful
    /// and must never be silently suppressed.
    public func canSend(_ id: UUID) -> Bool {
        guard let c = comments.first(where: { $0.id == id }) else { return false }
        return !c.sent && !sending.contains(id) && !c.draft.trimmed.isEmpty
    }

    /// True when a whole pass is ready to go out as one message.
    public var canSendAll: Bool { !unsent.isEmpty && sending.isEmpty }

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
            clearComments()                            // its anchors no longer refer to anything
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
        clearComments()                                // an anchor belongs to the document it came from
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

    /// Anchor a passage, frozen against the document as it reads RIGHT NOW, and focus it.
    ///
    /// Returns the new comment's id. A selection with no highlight id is dropped: the page mints that
    /// id when it paints the tint, so its absence means the payload did not come from a real selection.
    @discardableResult
    public func select(_ selection: DocumentSelection) -> UUID? {
        guard let doc = selected, let body = content, let hid = selection.highlightID else { return nil }
        let anchor = DocumentComment.capture(path: doc.path, source: body,
                                             startLine: selection.startLine, endLine: selection.endLine,
                                             selectedText: selection.text)
        nextSeq += 1
        let new = PendingComment(id: UUID(), highlightID: hid, seq: nextSeq, anchor: anchor)
        comments.append(new)
        // Document order, so the rail reads top to bottom the way the document does.
        comments.sort { ($0.anchor.startLine ?? 0, $0.seq) < ($1.anchor.startLine ?? 0, $1.seq) }
        activeComment = new.id
        revealHighlight = nil                          // the passage is already under the user's cursor
        return new.id
    }

    /// Focus a card BY CLICK, which also scrolls its passage into view. The scroll report deliberately
    /// does not come through here — it sets `activeComment` alone.
    public func focus(_ id: UUID) {
        activeComment = id
        revealHighlight = comments.first { $0.id == id }?.highlightID
    }

    /// Drop one comment. Sent or not — discarding a sent card only clears the rail, and cannot unsend.
    public func discard(_ id: UUID) {
        comments.removeAll { $0.id == id }
        if activeComment == id { activeComment = comments.last?.id }
    }

    /// End the pass. Called when the document changes underneath it, because an anchor belongs to the
    /// document it came from.
    public func clearComments() {
        comments = []
        activeComment = nil
        revealHighlight = nil
        showingSent = false
        sending = []
    }

    /// The page could not re-place these passages after a refresh, so the agent rewrote them. The
    /// comment survives — its quote is frozen and still says what the reviewer read — but the rail
    /// must say the tint is gone rather than leave the reviewer looking for it.
    /// The page reports the WHOLE set each time, so this ASSIGNS rather than accumulates. An anchor
    /// re-attaches when the agent restores the text it pointed at, and a badge that could only ever be
    /// set would then contradict a passage that is visibly tinted again.
    public func setDetached(_ highlightIDs: [String]) {
        let gone = Set(highlightIDs)
        for i in comments.indices {
            comments[i].detached = gone.contains(comments[i].highlightID)
        }
    }

    /// A two-way binding onto one comment's draft. `comments` is read-only from outside, so the view
    /// cannot bind into the array directly.
    public func draftBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.comments.first(where: { $0.id == id })?.draft ?? "" },
            set: { text in
                guard let i = self.comments.firstIndex(where: { $0.id == id }) else { return }
                self.comments[i].draft = text
            })
    }

    /// Send ONE comment. Returns the sent text so a caller can assert on it.
    @discardableResult
    public func send(_ id: UUID, deliver: (String) async -> Bool) async -> String? {
        guard canSend(id), let c = comments.first(where: { $0.id == id }) else { return nil }
        sending.insert(id)
        let message = c.anchor.message(note: c.draft)
        let ok = await deliver(message)
        sending.remove(id)
        // Re-find rather than reuse the index: the rail can gain a comment while this was in flight.
        guard ok, let i = comments.firstIndex(where: { $0.id == id }) else { return nil }
        comments[i].sent = true                        // on failure the draft stays, so a retry is free
        // It has just left the open group. Holding focus on a card that collapsed out of sight would
        // leave a passage strongly tinted with nothing on screen explaining why.
        if activeComment == id, !showingSent { activeComment = nil }
        return message
    }

    /// Send the whole pass as ONE message, in document order.
    @discardableResult
    public func sendAll(deliver: (String) async -> Bool) async -> String? {
        let batch = unsent
        guard !batch.isEmpty, sending.isEmpty else { return nil }
        let ids = Set(batch.map(\.id))
        sending.formUnion(ids)
        let message = DocumentComment.batchMessage(batch.map { ($0.anchor, $0.draft) })
        let ok = await deliver(message)
        sending.subtract(ids)
        guard ok else { return nil }
        for i in comments.indices where ids.contains(comments[i].id) { comments[i].sent = true }
        if let active = activeComment, ids.contains(active), !showingSent { activeComment = nil }
        return message
    }
}

/// One comment in a reading pass: the frozen anchor, the text being written against it, and its state.
public struct PendingComment: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The reader page's id for this passage's tint. Swift never interprets it. It hands the set back
    /// so the page knows which highlights are still live and which one is focused.
    public let highlightID: String
    /// Insertion order, used only to break a tie between two comments on the same line.
    public let seq: Int
    public let anchor: DocumentComment
    public var draft: String = ""
    public var sent: Bool = false
    /// The agent rewrote the anchored passage, so the tint could not be re-placed after a refresh.
    public var detached: Bool = false
}
