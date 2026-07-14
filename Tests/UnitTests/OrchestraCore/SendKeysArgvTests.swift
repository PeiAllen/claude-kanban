import XCTest
import OrchestraKit

/// The CLI `send-keys` argv parser (#9). The regression: `--text` was appended AHEAD of the positional
/// keys regardless of where it appeared, so `send-keys <ref> Enter --text y` inverted to `y`-then-Enter.
/// The parser must preserve argv order.
final class SendKeysArgvTests: XCTestCase {

    func testArgvOrderIsPreservedTextAfterKey() {
        // `send-keys <ref> Enter --text y` → Enter THEN the literal "y" (NOT text-first).
        let p = SendKeysArgv.parse(["card1", "Enter", "--text", "y"])
        XCTAssertEqual(p.ref, "card1")
        XCTAssertEqual(p.window, "agent")
        XCTAssertEqual(p.tokens, [.named(.enter), .text("y")])
    }

    func testArgvOrderIsPreservedTextBeforeKey() {
        // The other order must also be honored: text FIRST, then Enter.
        let p = SendKeysArgv.parse(["card1", "--text", "y", "Enter"])
        XCTAssertEqual(p.tokens, [.text("y"), .named(.enter)])
    }

    func testKnownKeyNamesBecomeNamedKeysOthersText() {
        let p = SendKeysArgv.parse(["ref", "Up", "C-c", "hello", "Esc"])
        XCTAssertEqual(p.tokens, [.named(.up), .named(.ctrlC), .text("hello"), .named(.esc)])
    }

    func testWindowFlagIsParsedAndRemovedFromChord() {
        let p = SendKeysArgv.parse(["ref", "--window", "shell-1", "Enter"])
        XCTAssertEqual(p.window, "shell-1")
        XCTAssertEqual(p.tokens, [.named(.enter)])
    }

    func testDoubleDashMakesRemainderLiteralText() {
        // After `--`, even a key-name-looking token and a leading-dash token are literal text.
        let p = SendKeysArgv.parse(["ref", "--", "Enter", "-x"])
        XCTAssertEqual(p.tokens, [.text("Enter"), .text("-x")])
    }

    func testTextForcesLiteralEvenForKeyName() {
        // `--text Enter` sends the literal word "Enter", not the Enter key.
        let p = SendKeysArgv.parse(["ref", "--text", "Enter"])
        XCTAssertEqual(p.tokens, [.text("Enter")])
    }

    func testFirstBareTokenIsRefRestAreChord() {
        let p = SendKeysArgv.parse(["myref", "y"])
        XCTAssertEqual(p.ref, "myref")
        XCTAssertEqual(p.tokens, [.text("y")])
    }

    func testNoRefWhenOnlyFlags() {
        let p = SendKeysArgv.parse(["--text", "y"])
        XCTAssertNil(p.ref)                       // caller falls back to --ref
        XCTAssertEqual(p.tokens, [.text("y")])
    }
}
