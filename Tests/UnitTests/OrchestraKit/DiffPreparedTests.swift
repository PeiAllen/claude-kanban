import Testing
import Foundation
@testable import OrchestraKit

/// `DiffPrepared` builds the renderer's rows once per load instead of once per SwiftUI body pass, and
/// stamps each pane with a `contentKey`. The view applies rows to its `NSTextView` only when that key
/// changes, so a key that repeats across two different panes would leave one file showing another
/// file's text. These tests pin the key's uniqueness and the rows' equivalence to the old per-body
/// construction.
@Suite struct DiffPreparedTests {
    private let patch = """
    diff --git a/x.swift b/x.swift
    --- a/x.swift
    +++ b/x.swift
    @@ -1,3 +1,4 @@ func f()
     keep
    -gone
    +new
    +extra
    diff --git a/y.swift b/y.swift
    --- a/y.swift
    +++ b/y.swift
    @@ -10,2 +10,2 @@ func g()
     same
    -old
    +fresh
    """

    private var sections: [DiffFileSection] { DiffFileParser.parse(patch) }

    private func keys(_ files: [DiffPreparedFile]) -> [String] {
        files.flatMap { file -> [String] in
            switch file.body {
            case .unified(let p):            [p.contentKey]
            case .split(let l, let r):       [l.contentKey, r.contentKey]
            }
        }
    }

    @Test func test_everyPaneGetsADistinctKey() throws {
        let all = keys(DiffPrepared.make(sections, layout: .unified, generation: 1))
            + keys(DiffPrepared.make(sections, layout: .split, generation: 1))
        #expect(all.count == Set(all).count, "duplicate contentKey would show one file's text in another")
        #expect(all.count == 2 + 4)   // 2 files unified, 2 panes each in split
    }

    @Test func test_theSameInputsProduceTheSameKeys() throws {
        let a = DiffPrepared.make(sections, layout: .unified, generation: 3)
        let b = DiffPrepared.make(sections, layout: .unified, generation: 3)
        #expect(keys(a) == keys(b), "a re-render with no reload must not look like new content")
        #expect(a == b)
    }

    @Test func test_aNewGenerationInvalidatesEveryKey() throws {
        let before = Set(keys(DiffPrepared.make(sections, layout: .unified, generation: 1)))
        let after = Set(keys(DiffPrepared.make(sections, layout: .unified, generation: 2)))
        #expect(before.isDisjoint(with: after), "a reload must re-apply, even for an unchanged file id")
    }

    @Test func test_unifiedRowsMatchTheParsedRows() throws {
        let file = try #require(DiffPrepared.make(sections, layout: .unified, generation: 1).first)
        guard case .unified(let pane) = file.body else { Issue.record("expected unified"); return }
        #expect(pane.rows == DiffRows.make(file.section.lines).map(DiffTextRow.init))
        #expect(pane.showsBothNumbers)
        #expect(pane.rows.allSatisfy { !$0.filler })   // unified has no empty cells
    }

    /// A change run of 1 removal and 2 additions leaves the removal side one cell short. That cell is
    /// `filler`, not context — it must read as "nothing here", not as an unchanged line.
    @Test func test_splitMarksTheUnpairedSideAsFiller() throws {
        let file = try #require(DiffPrepared.make(sections, layout: .split, generation: 1).first)
        guard case .split(let remove, let add) = file.body else { Issue.record("expected split"); return }
        #expect(remove.rows.contains { $0.filler })
        #expect(add.rows.allSatisfy { !$0.filler })
        #expect(!remove.showsBothNumbers && !add.showsBothNumbers)
        #expect(remove.rows.count == add.rows.count, "the two columns must stay row-aligned")
    }

    @Test func test_gutterWidthDataTracksTheWidestNumber() throws {
        let files = DiffPrepared.make(sections, layout: .unified, generation: 1)
        let second = try #require(files.last)
        guard case .unified(let pane) = second.body else { Issue.record("expected unified"); return }
        #expect(pane.maxLineNumber >= 10)   // y.swift's hunk starts at line 10
    }
}
