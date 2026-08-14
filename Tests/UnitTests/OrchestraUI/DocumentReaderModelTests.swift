import Foundation
import Testing
@testable import OrchestraUI
@testable import OrchestraKit

/// The reader's decision logic. No SwiftUI, no webview, no daemon — every behaviour here is one the
/// user would notice going wrong, and none of them are visible in a screenshot.
@Suite @MainActor struct DocumentReaderModelTests {

    private func doc(_ path: String = "docs/a.md", _ status: DocumentStatus? = .modified) -> DocRef {
        DocRef(path: path, status: status)
    }

    /// An unconditional list answer — what the daemon sends when the validator does not match.
    private func list(_ docs: [DocRef], hash: String = "L1") -> DocumentList {
        DocumentList(hash: hash, documents: docs)
    }
    private func body(_ text: String, hash: String = "C1") -> DocumentContent {
        DocumentContent(hash: hash, content: text)
    }

    /// A model with one document already open, so the tests can get straight to the behaviour.
    private func opened(_ text: String, path: String = "docs/a.md") async -> DocumentReaderModel {
        let m = DocumentReaderModel()
        await m.loadList { _ in self.list([self.doc(path)]) }
        await m.open(self.doc(path)) { _, _ in self.body(text) }
        return m
    }

    /// A selection as the page reports one: a line range plus the id of the tint it just painted.
    private func sel(_ line: Int, _ highlight: String = "h1") -> DocumentSelection {
        DocumentSelection(startLine: line, endLine: line, text: nil, highlightID: highlight)
    }

    // MARK: - the poll

    @Test("the poll sends the validator it was last given")
    func pollSendsItsValidator() async {
        // This is the whole economy of the design: the reader asks constantly, and asking is cheap only
        // because the daemon can answer "unchanged" without sending bytes.
        let m = await opened("# A\n\nfirst\n")
        var sent: String??
        await m.pollContent { _, validator in sent = validator; return nil }
        #expect(sent == "C1")
    }

    @Test("an unchanged answer leaves the text exactly where it was")
    func pollWithNoChangeIsANoOp() async {
        let m = await opened("# A\n\nfirst\n")
        await m.pollContent { _, _ in DocumentContent(hash: "C1", content: nil) }
        #expect(m.content?.contains("first") == true)
    }

    @Test("a changed answer replaces the text and adopts the new validator")
    func pollAppliesAChange() async {
        let m = await opened("# A\n\nfirst\n")
        await m.pollContent { _, _ in self.body("# A\n\nSECOND\n", hash: "C2") }
        #expect(m.content?.contains("SECOND") == true)
        var sent: String??
        await m.pollContent { _, v in sent = v; return nil }
        #expect(sent == "C2")                          // the next poll asks against the NEW copy
    }

    @Test("the poll does not move the text while someone is mid-sentence")
    func pollIsHeldWhileComposing() async {
        let m = await opened("# A\n\nfirst\n")
        let id = m.select(sel(3))!
        m.draftBinding(id).wrappedValue = "why?"
        await m.pollContent { _, _ in self.body("# A\n\nSECOND\n", hash: "C2") }
        #expect(m.content?.contains("first") == true)   // untouched mid-sentence

        // ...and the very next tick after it goes out picks it up. Deferred, not dropped.
        await m.send(id) { _ in true }
        await m.pollContent { _, _ in self.body("# A\n\nSECOND\n", hash: "C2") }
        #expect(m.content?.contains("SECOND") == true)
    }

    /// The hold is narrow ON PURPOSE. An anchor with nothing written against it must not freeze the
    /// document: the whole point of the reader is watching the agent work, and the highlight re-anchors
    /// itself across a refresh anyway.
    @Test("an anchor with no text written against it does NOT hold the poll")
    func anEmptyAnchorDoesNotHoldThePoll() async {
        let m = await opened("# A\n\nfirst\n")
        m.select(sel(3))
        #expect(!m.composing)
        await m.pollContent { _, _ in self.body("# A\n\nSECOND\n", hash: "C2") }
        #expect(m.content?.contains("SECOND") == true)
    }

    @Test("the LIST poll only adopts a set when one is sent")
    func listPollRespectsItsValidator() async {
        let m = await opened("body")
        await m.pollList { _ in DocumentList(hash: "L1", documents: nil) }
        #expect(m.documents.map(\.path) == ["docs/a.md"])          // unchanged: nothing adopted
        await m.pollList { _ in self.list([self.doc("docs/a.md"), self.doc("docs/new.md")], hash: "L2") }
        #expect(m.documents.count == 2)                            // a new document appeared
    }

    // MARK: - the quote is frozen at selection

    @Test("the quote is frozen at SELECTION, not re-derived at send")
    func theQuoteIsFrozenAtSelectionNotAtSend() async {
        let m = await opened("# H\n\noriginal line\n")
        let id = m.select(sel(3))!
        m.draftBinding(id).wrappedValue = "is this right?"

        // The file moves underneath while the user is typing.
        await m.pollContent { _, _ in self.body("# H\n\ncompletely different\n", hash: "C2") }

        var sent: String?
        await m.send(id) { sent = $0; return true }
        // The message must quote what the user actually saw and selected.
        #expect(sent?.contains("> original line") == true)
        #expect(sent?.contains("completely different") == false)
    }

    @Test("the frozen quote carries its heading path and line range")
    func theQuoteCarriesItsAnchor() async {
        let m = await opened("# Design\n\n## Contract\n\nthe claim\n")
        let id = m.select(sel(5))!
        m.draftBinding(id).wrappedValue = "source?"
        var sent: String?
        await m.send(id) { sent = $0; return true }
        #expect(sent?.hasPrefix("Comment on `docs/a.md:5-5` § Design › Contract") == true)
    }

    // MARK: - the reading pass

    @Test("a selection with no highlight id is dropped")
    func aSelectionWithoutAHighlightIsDropped() async {
        let m = await opened("# A\n\nbody\n")
        #expect(m.select(DocumentSelection(startLine: 3, endLine: 3)) == nil)
        #expect(m.comments.isEmpty)
    }

    @Test("anchors accumulate, and the rail reads in DOCUMENT order")
    func anchorsAccumulateInDocumentOrder() async {
        let m = await opened("# A\n\none\n\ntwo\n\nthree\n")
        m.select(sel(7, "h3"))                                     // anchored out of order
        m.select(sel(3, "h1"))
        m.select(sel(5, "h2"))
        #expect(m.comments.map(\.highlightID) == ["h1", "h2", "h3"])
        #expect(m.comments.count == 3)
    }

    @Test("two anchors on the same line keep their insertion order")
    func sameLineAnchorsKeepInsertionOrder() async {
        let m = await opened("# A\n\nbody\n")
        m.select(sel(3, "h1"))
        m.select(sel(3, "h2"))
        m.select(sel(3, "h3"))
        #expect(m.comments.map(\.highlightID) == ["h1", "h2", "h3"])
    }

    @Test("the newest anchor takes focus, and the page is told which passages are live")
    func theNewestAnchorTakesFocus() async {
        let m = await opened("# A\n\none\n\ntwo\n")
        m.select(sel(3, "h1"))
        let second = m.select(sel(5, "h2"))
        #expect(m.activeComment == second)
        #expect(m.liveHighlights == ["h1", "h2"])
    }

    @Test("discarding a comment drops it from the pass and from the page's live set")
    func discardingDropsIt() async {
        let m = await opened("# A\n\none\n\ntwo\n")
        let first = m.select(sel(3, "h1"))!
        m.select(sel(5, "h2"))
        m.discard(first)
        #expect(m.liveHighlights == ["h2"])
    }

    @Test("a rewritten passage marks its comment detached, and the comment survives")
    func aRewrittenPassageDetachesItsComment() async {
        let m = await opened("# A\n\nbody\n")
        let id = m.select(sel(3, "h1"))!
        m.draftBinding(id).wrappedValue = "still true"
        m.markDetached(["h1"])
        #expect(m.comments[0].detached)
        #expect(m.comments[0].draft == "still true")               // the quote froze; it is not lost
        #expect(m.canSend(id))                                     // and it can still be sent
    }

    /// An anchor belongs to the document it came from, so opening another one ends the pass.
    @Test("opening another document ends the pass")
    func openingAnotherDocumentEndsThePass() async {
        let m = await opened("# A\n\nbody\n")
        m.select(sel(3, "h1"))
        await m.open(doc("docs/b.md")) { _, _ in self.body("# B\n", hash: "C9") }
        #expect(m.comments.isEmpty)
        #expect(m.activeComment == nil)
    }

    // MARK: - send

    @Test("send is disabled until there is both an anchor and a draft")
    func sendIsDisabledWithoutAnAnchorOrADraft() async {
        let m = await opened("# A\n\nbody\n")
        #expect(!m.canSend(UUID()))                                // no such comment
        let id = m.select(sel(3))!
        #expect(!m.canSend(id))                                    // no draft
        m.draftBinding(id).wrappedValue = "   "
        #expect(!m.canSend(id))                                    // whitespace is not a comment
        m.draftBinding(id).wrappedValue = "real"
        #expect(m.canSend(id))
    }

    @Test("a failed send keeps the draft so it can be retried")
    func aFailedSendKeepsTheDraft() async {
        let m = await opened("# A\n\nbody\n")
        let id = m.select(sel(3))!
        m.draftBinding(id).wrappedValue = "keep me"
        await m.send(id) { _ in false }
        #expect(m.comments[0].draft == "keep me")
        #expect(!m.comments[0].sent)
        #expect(m.canSend(id))
    }

    /// A sent card STAYS in the rail. The pass is a record of what you said, and clearing it the moment
    /// a comment goes out would lose your place in a long document.
    @Test("a successful send marks the card sent and keeps it on screen")
    func aSuccessfulSendMarksItSent() async {
        let m = await opened("# A\n\nbody\n")
        let id = m.select(sel(3))!
        m.draftBinding(id).wrappedValue = "done"
        await m.send(id) { _ in true }
        #expect(m.comments.count == 1)
        #expect(m.comments[0].sent)
        #expect(m.comments[0].draft == "done")
        #expect(!m.composing)                                      // the poll is free to run again
        #expect(!m.canSend(id))                                    // and it cannot be sent twice
    }

    @Test("send all delivers ONE message holding every written comment, in document order")
    func sendAllDeliversOneMessageInOrder() async {
        let m = await opened("# H\n\none\n\ntwo\n")
        let a = m.select(sel(3, "h1"))!
        let b = m.select(sel(5, "h2"))!
        m.draftBinding(a).wrappedValue = "about one"
        m.draftBinding(b).wrappedValue = "about two"

        var messages: [String] = []
        await m.sendAll { messages.append($0); return true }

        #expect(messages.count == 1)                               // ONE message, not two
        let sent = messages[0]
        #expect(sent.hasPrefix("2 comments on `docs/a.md`"))
        let one = sent.range(of: "about one")?.lowerBound
        let two = sent.range(of: "about two")?.lowerBound
        #expect(one != nil && two != nil && one! < two!)
        #expect(m.comments.allSatisfy { $0.sent })
    }

    @Test("send all skips anchors with nothing written against them")
    func sendAllSkipsEmptyAnchors() async {
        let m = await opened("# H\n\none\n\ntwo\n")
        let a = m.select(sel(3, "h1"))!
        m.select(sel(5, "h2"))                                     // anchored, never written
        m.draftBinding(a).wrappedValue = "only this one"

        var sent: String?
        await m.sendAll { sent = $0; return true }
        // One written comment is the SINGLE format, byte for byte — no batch header appears.
        #expect(sent?.hasPrefix("Comment on `docs/a.md:3-3`") == true)
        #expect(m.comments[0].sent)
        #expect(!m.comments[1].sent)                               // the empty anchor is untouched
    }

    @Test("a failed send-all leaves every comment unsent and retryable")
    func aFailedSendAllKeepsEverything() async {
        let m = await opened("# H\n\none\n\ntwo\n")
        let a = m.select(sel(3, "h1"))!
        let b = m.select(sel(5, "h2"))!
        m.draftBinding(a).wrappedValue = "one"
        m.draftBinding(b).wrappedValue = "two"
        await m.sendAll { _ in false }
        #expect(m.comments.allSatisfy { !$0.sent })
        #expect(m.canSendAll)
    }

    // MARK: - load ordering

    @Test("a stale load never overwrites a newer one")
    func aStaleFetchNeverOverwritesANewerOne() async {
        // Two edits complete out of order. Without the epoch gate the OLDER response wins and nothing
        // repairs it, because no further change event is coming.
        //
        // Modelled deterministically rather than with a race: the OLD load runs a COMPLETE newer load
        // from inside its own fetch, so by the time OLD returns its epoch is provably stale. No gate,
        // no timing, no flake.
        let m = await opened("v1")
        await m.open(doc()) { _, _ in
            await m.open(self.doc()) { _, _ in self.body("NEW") }  // a newer open finishes first
            return self.body("OLD")                               // ...then the older one returns
        }
        #expect(m.content == "NEW")
    }

    // MARK: - changed documents are the focus

    @Test("the picker shows what this card changed, not the whole workspace")
    func browseListFocusesOnChangedDocuments() async {
        let m = DocumentReaderModel()
        await m.loadList { _ in self.list([
            self.doc("docs/edited.md", .modified),
            self.doc("docs/added.md", .added),
            self.doc("README.md", nil),
            self.doc("docs/untouched.md", nil),
        ]) }
        // Opening a repo must not bury the two files the agent touched under everything else.
        #expect(m.browseList.map(\.path) == ["docs/edited.md", "docs/added.md"])
        #expect(m.canRevealAll)
    }

    @Test("the rest is one tap away")
    func theRestCanBeRevealed() async {
        let m = DocumentReaderModel()
        await m.loadList { _ in self.list([self.doc("a.md", .modified), self.doc("b.md", nil)]) }
        m.showingAll = true
        #expect(m.browseList.count == 2)
    }

    @Test("search always spans EVERY document, touched or not")
    func searchSpansEverything() async {
        let m = DocumentReaderModel()
        await m.loadList { _ in self.list([self.doc("docs/edited.md", .modified), self.doc("docs/untouched.md", nil)]) }
        m.search = "untouched"
        // Excluding untouched documents from search would make a document the user knows exists look
        // absent — the opposite of what typing a filter means.
        #expect(m.browseList.map(\.path) == ["docs/untouched.md"])
        #expect(!m.canRevealAll)                   // the search already spans everything
    }

    @Test("a workspace git cannot speak about shows everything, not nothing")
    func noChangedDocumentsFallsBackToAll() async {
        // A scratch dir is not a repo, so nothing has a status. Showing an empty focus section there
        // would make the reader look broken.
        let m = DocumentReaderModel()
        await m.loadList { _ in self.list([self.doc("plan.md", nil), self.doc("notes.md", nil)]) }
        #expect(m.browseList.count == 2)
        #expect(!m.canRevealAll)
    }

    @Test("a vanished document stops being displayed")
    func aDeletedNoteStopsBeingShown() async {
        let m = await opened("a", path: "docs/a.md")
        await m.loadList { _ in self.list([self.doc("docs/b.md")]) }             // a.md was deleted
        #expect(m.selected == nil)                                // and the reader stops showing it
        #expect(m.content == nil)
    }
}
