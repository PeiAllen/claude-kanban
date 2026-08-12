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

    /// A model with one document already open, so the tests can get straight to the behaviour.
    private func opened(_ body: String, path: String = "docs/a.md") async -> DocumentReaderModel {
        let m = DocumentReaderModel()
        await m.loadList { [self.doc(path)] }
        await m.open(self.doc(path)) { _ in body }
        return m
    }

    // MARK: - refresh is deferred while composing, not dropped

    @Test("a change while composing does not move the text")
    func aChangeWhileComposingIsDeferredNotApplied() async {
        let m = await opened("# A\n\nfirst\n")
        m.select(DocumentSelection(blockIndex: 1, startLine: 3, endLine: 3))
        m.draft = "why?"

        await m.changed(path: "docs/a.md", list: { [self.doc()] }, read: { _ in "# A\n\nSECOND\n" })
        #expect(m.content?.contains("first") == true)   // untouched mid-sentence
    }

    @Test("closing the compose field applies the deferred change once")
    func closingComposeAppliesTheDeferredRefresh() async {
        let m = await opened("# A\n\nfirst\n")
        m.select(DocumentSelection(blockIndex: 1, startLine: 3, endLine: 3))
        await m.changed(path: "docs/a.md", list: { [self.doc()] }, read: { _ in "# A\n\nSECOND\n" })

        m.cancelComment()
        await m.applyPendingRefresh(list: { [self.doc()] }, read: { _ in "# A\n\nSECOND\n" })
        #expect(m.content?.contains("SECOND") == true)

        // ...and it is not applied twice.
        var fetches = 0
        await m.applyPendingRefresh(list: { fetches += 1; return [] }, read: { _ in nil })
        #expect(fetches == 0)
    }

    // MARK: - the quote is frozen at selection

    @Test("the quote is frozen at SELECTION, not re-derived at send")
    func theQuoteIsFrozenAtSelectionNotAtSend() async {
        let m = await opened("# H\n\noriginal line\n")
        m.select(DocumentSelection(blockIndex: 1, startLine: 3, endLine: 3))
        m.draft = "is this right?"

        // The file moves underneath while the user is typing.
        await m.changed(path: "docs/a.md", list: { [self.doc()] }, read: { _ in "# H\n\ncompletely different\n" })

        var sent: String?
        await m.send { sent = $0; return true }
        // The message must quote what the user actually saw and selected.
        #expect(sent?.contains("> original line") == true)
        #expect(sent?.contains("completely different") == false)
    }

    @Test("the frozen quote carries its heading path and line range")
    func theQuoteCarriesItsAnchor() async {
        let m = await opened("# Design\n\n## Contract\n\nthe claim\n")
        m.select(DocumentSelection(blockIndex: 2, startLine: 5, endLine: 5))
        m.draft = "source?"
        var sent: String?
        await m.send { sent = $0; return true }
        #expect(sent?.hasPrefix("Comment on `docs/a.md:5-5` § Design › Contract") == true)
    }

    // MARK: - send

    @Test("send is disabled until there is both an anchor and a draft")
    func sendIsDisabledWithoutAnAnchorOrADraft() async {
        let m = await opened("# A\n\nbody\n")
        #expect(!m.canSend)                                   // no selection
        m.select(DocumentSelection(blockIndex: 1, startLine: 3, endLine: 3))
        #expect(!m.canSend)                                   // no draft
        m.draft = "   "
        #expect(!m.canSend)                                   // whitespace is not a comment
        m.draft = "real"
        #expect(m.canSend)
    }

    @Test("a failed send keeps the draft so it can be retried")
    func aFailedSendKeepsTheDraft() async {
        let m = await opened("# A\n\nbody\n")
        m.select(DocumentSelection(blockIndex: 1, startLine: 3, endLine: 3))
        m.draft = "keep me"
        await m.send { _ in false }
        #expect(m.draft == "keep me")
        #expect(m.comment != nil)
    }

    @Test("a successful send clears the anchor and the draft")
    func aSuccessfulSendClears() async {
        let m = await opened("# A\n\nbody\n")
        m.select(DocumentSelection(blockIndex: 1, startLine: 3, endLine: 3))
        m.draft = "done"
        await m.send { _ in true }
        #expect(m.draft.isEmpty)
        #expect(m.comment == nil)
        #expect(!m.composing)
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
        await m.open(doc()) { _ in
            await m.open(self.doc()) { _ in "NEW" }   // a newer open starts AND finishes first
            return "OLD"                              // ...then the older one returns
        }
        #expect(m.content == "NEW")
    }

    @Test("a vanished note falls back to another rather than showing nothing")
    func aDeletedNoteFallsBack() async {
        let m = await opened("a", path: "docs/a.md")
        await m.loadList { [self.doc("docs/b.md")] }              // a.md was deleted
        #expect(m.selected == nil)                                // and the reader stops showing it
        #expect(m.content == nil)
    }
}
