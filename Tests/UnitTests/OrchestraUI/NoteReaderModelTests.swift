import Foundation
import Testing
@testable import OrchestraUI
@testable import OrchestraKit

/// The reader's decision logic. No SwiftUI, no webview, no daemon — every behaviour here is one the
/// user would notice going wrong, and none of them are visible in a screenshot.
@Suite @MainActor struct NoteReaderModelTests {

    private func note(_ body: String, at path: String = "docs/a.md") -> NoteFile {
        NoteFile(path: path, status: .modified, content: body)
    }

    private func loaded(_ files: [NoteFile]) async -> NoteReaderModel {
        let m = NoteReaderModel()
        await m.load { files }
        return m
    }

    // MARK: - refresh is deferred while composing, not dropped

    @Test("a change while composing does not move the text")
    func aChangeWhileComposingIsDeferredNotApplied() async {
        let m = await loaded([note("# A\n\nfirst\n")])
        m.select(NoteSelection(blockIndex: 1, startLine: 3, endLine: 3))
        m.draft = "why?"

        await m.noteChanged { [self.note("# A\n\nSECOND\n")] }
        #expect(m.current?.content.contains("first") == true)   // untouched mid-sentence
    }

    @Test("closing the compose field applies the deferred change once")
    func closingComposeAppliesTheDeferredRefresh() async {
        let m = await loaded([note("# A\n\nfirst\n")])
        m.select(NoteSelection(blockIndex: 1, startLine: 3, endLine: 3))
        await m.noteChanged { [self.note("# A\n\nSECOND\n")] }

        m.cancelComment()
        await m.applyPendingRefresh { [self.note("# A\n\nSECOND\n")] }
        #expect(m.current?.content.contains("SECOND") == true)

        // ...and it is not applied twice.
        var fetches = 0
        await m.applyPendingRefresh { fetches += 1; return [] }
        #expect(fetches == 0)
    }

    // MARK: - the quote is frozen at selection

    @Test("the quote is frozen at SELECTION, not re-derived at send")
    func theQuoteIsFrozenAtSelectionNotAtSend() async {
        let m = await loaded([note("# H\n\noriginal line\n")])
        m.select(NoteSelection(blockIndex: 1, startLine: 3, endLine: 3))
        m.draft = "is this right?"

        // The file moves underneath while the user is typing.
        await m.noteChanged { [self.note("# H\n\ncompletely different\n")] }

        var sent: String?
        await m.send { sent = $0; return true }
        // The message must quote what the user actually saw and selected.
        #expect(sent?.contains("> original line") == true)
        #expect(sent?.contains("completely different") == false)
    }

    @Test("the frozen quote carries its heading path and line range")
    func theQuoteCarriesItsAnchor() async {
        let m = await loaded([note("# Design\n\n## Contract\n\nthe claim\n")])
        m.select(NoteSelection(blockIndex: 2, startLine: 5, endLine: 5))
        m.draft = "source?"
        var sent: String?
        await m.send { sent = $0; return true }
        #expect(sent?.hasPrefix("Comment on `docs/a.md:5-5` § Design › Contract") == true)
    }

    // MARK: - send

    @Test("send is disabled until there is both an anchor and a draft")
    func sendIsDisabledWithoutAnAnchorOrADraft() async {
        let m = await loaded([note("# A\n\nbody\n")])
        #expect(!m.canSend)                                   // no selection
        m.select(NoteSelection(blockIndex: 1, startLine: 3, endLine: 3))
        #expect(!m.canSend)                                   // no draft
        m.draft = "   "
        #expect(!m.canSend)                                   // whitespace is not a comment
        m.draft = "real"
        #expect(m.canSend)
    }

    @Test("a failed send keeps the draft so it can be retried")
    func aFailedSendKeepsTheDraft() async {
        let m = await loaded([note("# A\n\nbody\n")])
        m.select(NoteSelection(blockIndex: 1, startLine: 3, endLine: 3))
        m.draft = "keep me"
        await m.send { _ in false }
        #expect(m.draft == "keep me")
        #expect(m.comment != nil)
    }

    @Test("a successful send clears the anchor and the draft")
    func aSuccessfulSendClears() async {
        let m = await loaded([note("# A\n\nbody\n")])
        m.select(NoteSelection(blockIndex: 1, startLine: 3, endLine: 3))
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
        let m = await loaded([note("v1")])
        let old = note("OLD"), new = note("NEW")
        await m.load {
            await m.load { [new] }      // a newer load starts AND finishes first
            return [old]                // ...then the older one returns
        }
        #expect(m.current?.content == "NEW")
    }

    @Test("a vanished note falls back to another rather than showing nothing")
    func aDeletedNoteFallsBack() async {
        let m = await loaded([note("a", at: "docs/a.md"), note("b", at: "docs/b.md")])
        m.selectedPath = "docs/a.md"
        await m.load { [self.note("b", at: "docs/b.md")] }        // a.md was deleted
        #expect(m.selectedPath == "docs/b.md")
    }
}
