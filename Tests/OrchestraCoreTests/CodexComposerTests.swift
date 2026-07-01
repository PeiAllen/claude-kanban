import Foundation
import Testing
@testable import OrchestraCore

@Suite("C4 · CodexComposer (idle + composer-empty heuristic; fragile by nature)")
struct CodexComposerTests {

    // An idle pane with an empty composer line → nudgeable.
    @Test("idle + empty composer → canNudge true, composer .empty")
    func idleEmpty() {
        let pane = """
        ● Ran the tests — all green.

        ›
        """
        #expect(CodexComposer.composer(pane) == .empty)
        #expect(CodexComposer.isWorking(pane) == false)
        #expect(CodexComposer.canNudge(pane) == true)
    }

    // A user draft in the composer → defer.
    @Test("draft in composer → canNudge false, composer .draft")
    func draftDefers() {
        let pane = """
        ● Ran the tests — all green.

        › let me think before I answer
        """
        #expect(CodexComposer.composer(pane) == .draft("let me think before I answer"))
        #expect(CodexComposer.canNudge(pane) == false)
    }

    // A turn is streaming (interrupt hint present) even with an empty composer → defer (not idle).
    @Test("in-flight turn (esc to interrupt) → canNudge false even with empty composer")
    func workingDefers() {
        let pane = """
        ● Thinking… (Esc to interrupt)

        ›
        """
        #expect(CodexComposer.isWorking(pane) == true)
        #expect(CodexComposer.canNudge(pane) == false)
    }

    // No composer marker located → we can't confirm empty → conservative defer.
    @Test("no composer line found → composer .unknown → canNudge false")
    func unknownDefers() {
        let pane = "just some scrollback with no input line at all\n"
        #expect(CodexComposer.composer(pane) == .unknown)
        #expect(CodexComposer.canNudge(pane) == false)
    }

    // An empty pane (capture failed / session gone) → unknown → defer.
    @Test("empty pane → canNudge false")
    func emptyPaneDefers() {
        #expect(CodexComposer.composer("") == .unknown)
        #expect(CodexComposer.canNudge("") == false)
    }

    // A greyed placeholder in an empty composer must NOT read as a draft.
    @Test("empty-composer placeholder text is treated as empty, not a draft")
    func placeholderIsEmpty() {
        let pane = """
        ● Done.

        › Send a message
        """
        #expect(CodexComposer.composer(pane) == .empty)
        #expect(CodexComposer.canNudge(pane) == true)
    }
}
