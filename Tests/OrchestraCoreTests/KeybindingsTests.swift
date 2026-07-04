import XCTest
@testable import OrchestraCore

final class KeybindingsTests: XCTestCase {
    private let vim = VimKeybindings()
    private let command = CommandKeybindings()

    /// Resolve through the full vim layer.
    private func map(_ c: KeyChord, _ ctx: KeyContext, goTo: Bool = false) -> KeyIntent? {
        vim.intent(for: c, in: ctx, awaitingGoTo: goTo)
    }
    /// Resolve through the generic (command-only) layer.
    private func base(_ c: KeyChord, _ ctx: KeyContext, goTo: Bool = false) -> KeyIntent? {
        command.intent(for: c, in: ctx, awaitingGoTo: goTo)
    }

    // MARK: - VimKeybindings

    func test_board_hjkl_moves() {
        XCTAssertEqual(map(KeyChord("j"), .board), .moveSelection(.down))
        XCTAssertEqual(map(KeyChord("k"), .board), .moveSelection(.up))
        XCTAssertEqual(map(KeyChord("h"), .board), .moveSelection(.left))
        XCTAssertEqual(map(KeyChord("l"), .board), .moveSelection(.right))
    }

    func test_board_verbs() {
        XCTAssertEqual(map(KeyChord("c"), .board), .spawn)
        XCTAssertEqual(map(KeyChord("a"), .board), .archive)
        XCTAssertEqual(map(KeyChord("o"), .board), .openNotes)
        XCTAssertEqual(map(KeyChord("O", .shift), .board), .openInZed)
        XCTAssertEqual(map(KeyChord("d"), .board), .toggleDiff)
        XCTAssertEqual(map(KeyChord("i"), .board), .enterTerminal)
        XCTAssertEqual(map(KeyChord("I", .shift), .board), .openInbox)
        XCTAssertEqual(map(KeyChord("t"), .board), .newShell)
    }

    func test_board_yank_prefix() {
        XCTAssertEqual(map(KeyChord("y"), .board), .beginYank)
    }

    func test_board_carry_is_shifted_hl() {
        XCTAssertEqual(map(KeyChord("H", .shift), .board), .carry(.left))
        XCTAssertEqual(map(KeyChord("L", .shift), .board), .carry(.right))
    }

    func test_board_ctrl_hjkl_is_pane_focus() {
        XCTAssertEqual(map(KeyChord("l", .control), .board), .focusPane(.right))
        XCTAssertEqual(map(KeyChord("j", .control), .board), .focusPane(.down))
        XCTAssertEqual(map(KeyChord("k", .control), .board), .focusPane(.up))
        XCTAssertEqual(map(KeyChord("h", .control), .board), .focusPane(.left))
    }

    func test_enter_and_esc() {
        XCTAssertEqual(map(KeyChord("\r"), .board), .openInspector)
        XCTAssertEqual(map(KeyChord("\u{1B}"), .board), .closeOrClear)
    }

    func test_search_and_help() {
        XCTAssertEqual(map(KeyChord("/"), .board), .search)
        XCTAssertEqual(map(KeyChord("?"), .board), .help)
    }

    func test_goto_prefix_and_targets() {
        XCTAssertEqual(map(KeyChord("g"), .board), .beginGoTo)
        XCTAssertEqual(map(KeyChord("p"), .board, goTo: true), .goTo(.plan))
        XCTAssertEqual(map(KeyChord("i"), .board, goTo: true), .goTo(.impl))
        XCTAssertEqual(map(KeyChord("r"), .board, goTo: true), .goTo(.review))
        XCTAssertEqual(map(KeyChord("f"), .board, goTo: true), .goTo(.freeform))
        XCTAssertEqual(map(KeyChord("s"), .board, goTo: true), .goTo(.settings))
    }

    func test_gg_and_G_select_ends() {
        XCTAssertEqual(map(KeyChord("g"), .board, goTo: true), .selectEnd(first: true))  // gg
        XCTAssertEqual(map(KeyChord("G", .shift), .board), .selectEnd(first: false))
    }

    func test_goto_unknown_letter_is_nil() {
        XCTAssertNil(map(KeyChord("z"), .board, goTo: true))
    }

    func test_cmd_accelerators_everywhere() {
        for ctx in [KeyContext.board, .terminal, .field, .overlay] {
            XCTAssertEqual(map(KeyChord("n", .command), ctx), .newCard)
            XCTAssertEqual(map(KeyChord("t", .command), ctx), .newShell)
            XCTAssertEqual(map(KeyChord("w", .command), ctx), .closeFrontmost)
        }
    }

    func test_unmapped_cmd_chord_does_not_fall_through_to_a_board_verb() {
        // ⌘D must pass through, not read as the bare `d` toggle-diff.
        XCTAssertNil(map(KeyChord("d", .command), .board))
        XCTAssertNil(map(KeyChord("a", .command), .board))
    }

    func test_terminal_passes_through_non_ctrl() {
        XCTAssertNil(map(KeyChord("j"), .terminal))
        XCTAssertNil(map(KeyChord("\u{1B}"), .terminal))    // Esc is sacred to the pty
        XCTAssertEqual(map(KeyChord("h", .control), .terminal), .focusPane(.left))
    }

    func test_field_only_ctrl_jk() {
        XCTAssertNil(map(KeyChord("j"), .field))
        XCTAssertEqual(map(KeyChord("j", .control), .field), .focusPane(.down))
        XCTAssertEqual(map(KeyChord("k", .control), .field), .focusPane(.up))
        XCTAssertNil(map(KeyChord("h", .control), .field))  // horizontal not used in a field
    }

    func test_overlay_only_esc() {
        XCTAssertEqual(map(KeyChord("\u{1B}"), .overlay), .closeOrClear)
        XCTAssertNil(map(KeyChord("j"), .overlay))
    }

    func test_new_board_verbs() {
        XCTAssertEqual(map(KeyChord("z"), .board), .toggleCollapse)
        XCTAssertEqual(map(KeyChord("f"), .board), .hint)
        XCTAssertEqual(map(KeyChord(":", .shift), .board), .palette)
        XCTAssertEqual(map(KeyChord("n"), .board), .searchNext)
        XCTAssertEqual(map(KeyChord("N", .shift), .board), .searchPrev)
    }

    func test_ctrl_shift_hjkl_resizes() {
        XCTAssertEqual(map(KeyChord("H", [.control, .shift]), .board), .resize(.left))
        XCTAssertEqual(map(KeyChord("L", [.control, .shift]), .board), .resize(.right))
        XCTAssertEqual(map(KeyChord("K", [.control, .shift]), .terminal), .resize(.up))
        XCTAssertEqual(map(KeyChord("J", [.control, .shift]), .terminal), .resize(.down))
        XCTAssertNil(map(KeyChord("J", [.control, .shift]), .field))
    }

    func test_ctrl_hjkl_still_focuses_without_shift() {
        XCTAssertEqual(map(KeyChord("l", .control), .board), .focusPane(.right))
    }

    // MARK: - CommandKeybindings (Vim keyboard off)

    func test_command_keeps_cmd_accelerators_everywhere() {
        for ctx in [KeyContext.board, .terminal, .field, .overlay] {
            XCTAssertEqual(base(KeyChord("n", .command), ctx), .newCard)
            XCTAssertEqual(base(KeyChord("t", .command), ctx), .newShell)
            XCTAssertEqual(base(KeyChord("w", .command), ctx), .closeFrontmost)
        }
    }

    func test_command_keeps_esc_on_board_and_overlay() {
        XCTAssertEqual(base(KeyChord("\u{1B}"), .board), .closeOrClear)
        XCTAssertEqual(base(KeyChord("\u{1B}"), .overlay), .closeOrClear)
        // Esc is still sacred to the pty / a text field even with the vim layer off.
        XCTAssertNil(base(KeyChord("\u{1B}"), .terminal))
        XCTAssertNil(base(KeyChord("\u{1B}"), .field))
    }

    func test_command_swallows_nothing_else() {
        XCTAssertNil(base(KeyChord("j"), .board))                     // navigation off
        XCTAssertNil(base(KeyChord("c"), .board))                     // verbs off
        XCTAssertNil(base(KeyChord("y"), .board))                     // yank off
        XCTAssertNil(base(KeyChord("f"), .board))                     // hints off
        XCTAssertNil(base(KeyChord(":", .shift), .board))             // palette off
        XCTAssertNil(base(KeyChord("/"), .board))                     // search off
        XCTAssertNil(base(KeyChord("l", .control), .board))          // pane focus off
        XCTAssertNil(base(KeyChord("H", [.control, .shift]), .board)) // resize off
        XCTAssertNil(base(KeyChord("g"), .board, goTo: true))        // goto off
    }
}
