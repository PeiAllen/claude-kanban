import Foundation
import Testing
@testable import OrchestraCore

/// `Column`'s three display forms. These exist because a chip in a narrow row (the desktop and phone
/// peek rows, the drill banner) must render a stage in a fixed-width pill: a long word there gets
/// squeezed and wraps character-by-character into a tall pill, which is exactly the row-height bug the
/// compact forms were added to kill.
///
/// So the assertions pin the LENGTH BUDGET, not the literal spellings — a tautological
/// `letter == "P"` test would pass while someone added a `case backlog` whose letter is "BACKLOG" and
/// reintroduced the bug. Every case is checked via `allCases`, so a new column can't skip the budget.
@Suite("Column — compact display forms for tight chips")
struct ColumnDisplayTests {

    @Test("every column's letter is exactly one character")
    func letterIsSingleCharacter() {
        for c in Column.allCases {
            #expect(c.letter.count == 1, "\(c) letter '\(c.letter)' must be 1 char to fit the tight pill")
        }
    }

    @Test("every column's shortName stays pill-sized and is not the prose displayName")
    func shortNameIsPillSized() {
        for c in Column.allCases {
            #expect(c.shortName.count <= 6, "\(c) shortName '\(c.shortName)' is too long for a chip")
            #expect(!c.shortName.contains(" "), "\(c) shortName must be one word")
        }
        // The whole point: the prose form is too long for a chip, which is why `shortName` exists.
        #expect(Column.impl.displayName.count > Column.impl.shortName.count)
    }

    @Test("the forms distinguish the columns — no two share a letter or a short name")
    func formsAreUnambiguous() {
        #expect(Set(Column.allCases.map(\.letter)).count == Column.allCases.count)
        #expect(Set(Column.allCases.map(\.shortName)).count == Column.allCases.count)
    }
}
